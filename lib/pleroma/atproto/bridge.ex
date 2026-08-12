# Unfathomably BE
# ----------------
#
# File: atproto/bridge.ex
#
# Purpose:
#   Project the locally relevant part of AT Protocol into ActivityPub records.
#
# Responsibilities:
#   - resolve explicitly opened Bluesky post URLs through the public AppView
#   - ingest posts from locally followed identities and their direct threads
#   - preserve AT URI/CID strong references for replies, quotes, and publishing
#   - create ordinary statuses while marking their native protocol provenance
#
# This file intentionally does NOT consume the firehose, mirror repositories,
# crawl global feeds, or retain unrelated AppView responses.

defmodule Pleroma.ATProto.Bridge do
  require Logger

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.ATProto.Client
  alias Pleroma.ATProto.Identities
  alias Pleroma.ATProto.Identity
  alias Pleroma.ATProto.Media
  alias Pleroma.ATProto.Record
  alias Pleroma.ATProto.RichText
  alias Pleroma.ATProto.Store
  alias Pleroma.FollowingRelationship
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.CommonAPI.ActivityDraft

  @post_collection "app.bsky.feed.post"
  @maximum_thread_posts 200

  def resolve_url(url) when is_binary(url) do
    with {:ok, actor, rkey} <- parse_post_url(url),
         {:ok, did} <- resolve_did(actor),
         uri = "at://#{did}/#{@post_collection}/#{rkey}" do
      resolve_uri(uri)
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_url(_url), do: {:error, :not_found}

  def resolve_uri(uri) when is_binary(uri) do
    with {:ok, _did, @post_collection, _rkey} <- Store.split_uri(uri),
         {:ok, response} <- Client.get_post_thread(uri),
         {:ok, activity} <- ingest_thread_response(response, uri, "explicit") do
      hydrate_quotes(uri)
      hydrate_interactors(uri)
      {:ok, activity}
    else
      {:error, reason} = error ->
        if terminal_lookup_error?(reason), do: {:error, :not_found}, else: error

      _reason ->
        {:error, :not_found}
    end
  end

  def resolve_uri(_uri), do: {:error, :not_found}

  def ingest_author_feed(%Identity{did: did} = identity) do
    with {:ok, %{"feed" => feed}} when is_list(feed) <-
           Client.get_author_feed(did, nil, 100) do
      summary =
        feed
        |> Enum.take(100)
        |> Enum.reduce(%{ingested: 0, skipped: 0, failed: 0}, fn item, summary ->
          case item do
            %{"post" => %{} = post} ->
              case ingest_post(post, "follow") do
                {:ok, _activity} -> %{summary | ingested: summary.ingested + 1}
                {:error, _reason} -> %{summary | failed: summary.failed + 1}
              end

            _ ->
              %{summary | skipped: summary.skipped + 1}
          end
        end)

      if summary.failed > 0 do
        Logger.warning(
          "ATProto author feed completed with rejected records",
          atproto_did: did,
          ingested: summary.ingested,
          skipped: summary.skipped,
          failed: summary.failed
        )
      end

      case Identities.mark_synced(identity) do
        {:ok, _identity} -> :ok
        error -> error
      end
    else
      error -> error
    end
  end

  def ingest_author_feed(_identity), do: {:error, :invalid_identity}

  def delete_projection(uri) when is_binary(uri) do
    with %Record{ap_activity_id: activity_id} = record <- Store.get(uri),
         %Activity{} = activity <- Activity.get_by_id(activity_id),
         %User{} = actor <- User.get_cached_by_ap_id(activity.data["actor"]),
         {:ok, _delete} <- CommonAPI.delete(activity.id, actor),
         {:ok, _record} <- Store.delete(record) do
      :ok
    else
      nil -> :ok
      {:ok, nil} -> :ok
      error -> error
    end
  end

  def delete_projection(_uri), do: {:error, :invalid_at_uri}

  def followed_identities(limit \\ 500) do
    accepted = FollowingRelationship.accept_state_code()

    Identity
    |> join(:inner, [identity], relation in FollowingRelationship,
      on: relation.following_id == identity.user_id
    )
    |> join(:inner, [_identity, relation], follower in User,
      on: follower.id == relation.follower_id
    )
    |> where(
      [_identity, relation, follower],
      relation.state == ^accepted and follower.local == true
    )
    |> distinct(true)
    |> order_by([identity], asc_nulls_first: identity.last_synced_at)
    |> limit(^max(1, min(limit, 2_000)))
    |> Repo.all()
  end

  @doc "Repairs rich-text mentions on existing AT Protocol projections without replaying them."
  def backfill_mentions(limit \\ 2_000)

  def backfill_mentions(limit) when is_integer(limit) and limit > 0 do
    Record
    |> where([record], not is_nil(record.ap_activity_id))
    |> order_by([record], asc: record.uri)
    |> limit(^min(limit, 20_000))
    |> Repo.all()
    |> Enum.map(&repair_projection_mentions/1)
    |> Enum.frequencies()
  end

  def backfill_mentions(_limit), do: %{skipped: 0}

  def ingest_post(%{"uri" => uri, "cid" => cid, "author" => %{} = profile} = post, source)
      when is_binary(uri) and is_binary(cid) and source in ~w[follow explicit interaction] do
    existing = Store.get(uri)

    with true <- collection(uri) == @post_collection,
         {:ok, actor} <- Identities.upsert_profile(profile),
         {:ok, stored} <- Store.put(post, source),
         {:ok, activity} <- project_post(actor, post, stored, existing) do
      {:ok, activity}
    else
      false -> {:error, :unsupported_collection}
      error -> error
    end
  end

  def ingest_post(_post, _source), do: {:error, :invalid_record}

  @doc "Returns displayable text for an AppView post projection."
  def display_text(%{"record" => %{} = record} = post) do
    case bounded_text(record["text"], 300_000) do
      text when is_binary(text) ->
        if String.trim(text) == "", do: canonical_post_text(post), else: text

      _ ->
        canonical_post_text(post)
    end
  end

  def display_text(post) when is_map(post), do: canonical_post_text(post)
  def display_text(_post), do: ""

  defp ingest_thread_response(%{"thread" => thread}, requested_uri, source) when is_map(thread) do
    posts = thread_posts(thread, @maximum_thread_posts)

    Enum.reduce_while(posts, {:error, :not_found}, fn post, result ->
      post_source = if post["uri"] == requested_uri, do: source, else: "interaction"

      case ingest_post(post, post_source) do
        {:ok, activity} ->
          if post["uri"] == requested_uri do
            {:cont, {:ok, activity}}
          else
            {:cont, result}
          end

        {:error, _reason} ->
          {:cont, result}
      end
    end)
  end

  defp ingest_thread_response(_response, _requested_uri, _source), do: {:error, :not_found}

  # Parents are visited before children so ActivityDraft can attach native
  # replies to an already projected parent whenever the AppView supplied it.
  defp thread_posts(thread, limit) do
    thread
    |> collect_thread_posts([], limit)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1["uri"])
  end

  defp collect_thread_posts(_thread, posts, remaining) when remaining <= 0, do: posts

  defp collect_thread_posts(%{} = thread, posts, remaining) do
    {posts, remaining} =
      case thread["parent"] do
        %{} = parent ->
          parent_posts = collect_thread_posts(parent, posts, remaining)
          {parent_posts, remaining - max(length(parent_posts) - length(posts), 0)}

        _ ->
          {posts, remaining}
      end

    {posts, remaining} =
      case thread["post"] do
        %{"uri" => _uri} = post when remaining > 0 -> {[post | posts], remaining - 1}
        _ -> {posts, remaining}
      end

    thread
    |> Map.get("replies", [])
    |> List.wrap()
    |> Enum.reduce_while({posts, remaining}, fn reply, {current, left} ->
      if left <= 0 do
        {:halt, {current, left}}
      else
        next = collect_thread_posts(reply, current, left)
        {:cont, {next, left - max(length(next) - length(current), 0)}}
      end
    end)
    |> elem(0)
  end

  defp collect_thread_posts(_thread, posts, _remaining), do: posts

  defp project_post(actor, post, %Record{ap_activity_id: id}, existing) when not is_nil(id) do
    case Activity.get_by_id(id) do
      %Activity{} = activity ->
        unchanged? =
          case existing do
            %Record{cid: cid} -> cid == post["cid"]
            _record -> false
          end

        if unchanged? do
          repair_existing_reply(activity, post)
        else
          refresh_existing_projection(actor, activity, post)
        end

      nil ->
        {:error, :stale_projection}
    end
  end

  defp project_post(actor, post, stored, _existing) do
    with {:ok, draft} <- ActivityDraft.create(actor, inbound_params(post)),
         {:ok, activity} <-
           draft.changes
           |> inbound_changes(post)
           |> ActivityPub.create() do
      object = Object.normalize(activity, fetch: false)

      case Store.claim_activity(stored.uri, activity.id, object && object.data["id"]) do
        {:ok, :claimed} ->
          {:ok, activity}

        {:ok, existing_id} ->
          remove_unclaimed_projection(activity, existing_id)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp refresh_existing_projection(actor, activity, post) do
    with %Object{} = object <- Object.normalize(activity, fetch: false),
         {:ok, draft} <- ActivityDraft.create(actor, inbound_params(post)),
         changes = inbound_changes(draft.changes, post),
         %{} = replacement <- changes.object do
      stable =
        Map.take(object.data, [
          "id",
          "actor",
          "attributedTo",
          "context",
          "conversation",
          "to",
          "cc"
        ])

      updated_data =
        replacement
        |> Map.merge(stable)
        |> Map.put("updated", DateTime.to_iso8601(DateTime.utc_now()))

      with {:ok, _object} <-
             object
             |> Ecto.Changeset.change(data: updated_data)
             |> Object.update_and_set_cache(),
           {:ok, _activity} <- repair_existing_reply(activity, post) do
        {:ok, activity}
      end
    else
      nil -> {:error, :stale_projection}
      error -> error
    end
  end

  defp inbound_params(post) do
    record = post["record"] || %{}

    %{
      # ActivityDraft validates text before the AppView embed is converted to
      # attachments. A canonical URL keeps media-only records displayable and
      # prevents one empty caption from stopping the followed-author feed.
      status: inbound_text(post, record),
      content_type: "text/plain",
      visibility: "public"
    }
    |> maybe_put(
      :in_reply_to_status_id,
      mapped_activity_id(get_in(record, ["reply", "parent", "uri"]))
    )
    |> maybe_put(:quote_id, mapped_activity_id(quoted_uri(post)))
  end

  defp inbound_changes(changes, post) do
    published = post_published_at(post)

    object =
      changes.object
      |> RichText.put_inbound_mentions(post["record"] || %{})
      |> restore_native_source(display_text(post))
      |> Map.put("published", DateTime.to_iso8601(published))
      |> Map.put("unfathomably:atproto", %{
        "uri" => post["uri"],
        "cid" => post["cid"],
        "url" => post["uri"] |> post_url(post["author"])
      })
      |> Map.put("like_count", bounded_count(post["likeCount"]))
      |> Map.put("announcement_count", bounded_count(post["repostCount"]))
      |> Map.put("quotesCount", bounded_count(post["quoteCount"]))
      |> Media.put_attachments(post)

    additional = Map.put(changes.additional, "unfathomably:atproto_ingest", true)

    changes
    |> Map.put(:object, object)
    |> Map.put(:additional, additional)
    |> Map.put(:local, false)
    |> Map.put(:published, DateTime.to_iso8601(published))
  end

  defp hydrate_quotes(uri) do
    case Client.get_quotes(uri, nil, 50) do
      {:ok, %{"posts" => posts}} when is_list(posts) ->
        Enum.each(posts, &ingest_post(&1, "interaction"))
        :ok

      _ ->
        :ok
    end
  end

  defp inbound_text(post, %{"text" => text} = record) when is_binary(text) do
    if String.trim(text) == "", do: display_text(post), else: RichText.inbound(record)
  end

  defp inbound_text(post, _record), do: display_text(post)

  defp restore_native_source(object, source_text) when is_binary(source_text) do
    source = Map.put(object["source"] || %{}, "content", source_text)
    Map.put(object, "source", source)
  end

  defp repair_projection_mentions(%Record{ap_activity_id: activity_id, data: post})
       when is_binary(activity_id) and is_map(post) do
    with %Activity{} = activity <- Activity.get_by_id(activity_id),
         %Object{} = object <- Object.normalize(activity, fetch: false),
         generated <-
           object.data
           |> RichText.put_inbound_mentions(post["record"] || %{})
           |> restore_native_source(display_text(post)),
         {:ok, _object} <-
           Object.update_data(
             object,
             Map.take(generated, ["content", "source", "tag", "to", "cc"])
           ) do
      :updated
    else
      _ -> :skipped
    end
  end

  defp repair_projection_mentions(_record), do: :skipped

  defp hydrate_interactors(uri) do
    with %Record{cid: cid} <- Store.get(uri) do
      case Client.get_likes(uri, cid, nil, 50) do
        {:ok, %{"likes" => likes}} when is_list(likes) ->
          Enum.each(likes, fn
            %{"actor" => %{} = profile} -> Identities.upsert_profile(profile)
            _ -> :ok
          end)

        _ ->
          :ok
      end

      case Client.get_reposted_by(uri, nil, 50) do
        {:ok, %{"repostedBy" => profiles}} when is_list(profiles) ->
          Enum.each(profiles, &Identities.upsert_profile/1)

        _ ->
          :ok
      end
    end

    :ok
  end

  defp remove_unclaimed_projection(activity, existing_id) when activity.id != existing_id do
    with %User{} = actor <- User.get_cached_by_ap_id(activity.data["actor"]),
         {:ok, _activity} <- CommonAPI.delete(activity.id, actor),
         %Activity{} = existing <- Activity.get_by_id(existing_id) do
      {:ok, existing}
    else
      _ -> {:error, :projection_race}
    end
  end

  defp remove_unclaimed_projection(activity, _existing_id), do: {:ok, activity}

  defp resolve_did("did:" <> _rest = did) do
    if Pleroma.ATProto.Validation.valid_did?(did), do: {:ok, did}, else: {:error, :not_found}
  end

  defp resolve_did(handle) do
    case Client.resolve_handle(handle) do
      {:ok, %{"did" => did}} when is_binary(did) -> {:ok, did}
      _ -> {:error, :not_found}
    end
  end

  defp parse_post_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "bsky.app", query: nil, fragment: nil, path: path} ->
        case String.split(path || "", "/", trim: true) do
          ["profile", actor, "post", rkey]
          when byte_size(actor) in 1..2_048 and byte_size(rkey) in 1..512 ->
            {:ok, URI.decode(actor), URI.decode(rkey)}

          _ ->
            {:error, :invalid_url}
        end

      _ ->
        {:error, :invalid_url}
    end
  rescue
    _ -> {:error, :invalid_url}
  end

  defp collection(uri) do
    case Store.split_uri(uri) do
      {:ok, _did, collection, _rkey} -> collection
      _ -> nil
    end
  end

  defp repair_existing_reply(%Activity{} = activity, post) when is_map(post) do
    parent_uri = get_in(post, ["record", "reply", "parent", "uri"])

    with parent_activity_id when is_binary(parent_activity_id) <- mapped_activity_id(parent_uri),
         %Activity{} = parent_activity <- Activity.get_by_id(parent_activity_id) do
      Pleroma.Federation.ThreadLink.repair(activity, parent_activity)
    else
      _ -> {:ok, activity}
    end
  end

  defp mapped_activity_id(uri) when is_binary(uri) do
    case Store.get(uri) do
      %Record{ap_activity_id: id} when not is_nil(id) -> id
      _ -> nil
    end
  end

  defp mapped_activity_id(_uri), do: nil

  defp quoted_uri(%{"embed" => %{} = embed}) do
    get_in(embed, ["record", "uri"]) || get_in(embed, ["record", "record", "uri"])
  end

  defp quoted_uri(_post), do: nil

  defp post_url(uri, author) do
    with {:ok, _did, @post_collection, rkey} <- Store.split_uri(uri) do
      actor = author["handle"] || author["did"]
      if is_binary(actor), do: "https://bsky.app/profile/#{actor}/post/#{rkey}"
    else
      _ -> nil
    end
  end

  defp canonical_post_text(post) do
    post_url(post["uri"], post["author"] || %{}) || post["uri"] || ""
  end

  defp post_published_at(post) do
    value = get_in(post, ["record", "createdAt"]) || post["indexedAt"]

    case value && DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        tolerance =
          case Pleroma.Config.get([Pleroma.ATProto, :future_tolerance_seconds], 900) do
            value when is_integer(value) and value >= 0 -> value
            _value -> 900
          end

        maximum = DateTime.add(DateTime.utc_now(), tolerance, :second)
        if DateTime.compare(datetime, maximum) == :gt, do: DateTime.utc_now(), else: datetime

      _ ->
        DateTime.utc_now()
    end
  end

  defp terminal_lookup_error?({:http, status, _body}) when status in [403, 404, 410], do: true

  defp terminal_lookup_error?({:http, 400, %{"error" => error}})
       when error in ["BlockedActor", "InvalidRequest", "NotFound"],
       do: true

  defp terminal_lookup_error?(:invalid_at_uri), do: true
  defp terminal_lookup_error?(_reason), do: false

  defp bounded_text(value, limit) when is_binary(value) and byte_size(value) <= limit do
    if String.valid?(value), do: value
  end

  defp bounded_text(_value, _limit), do: nil
  defp bounded_count(value) when is_integer(value) and value >= 0, do: min(value, 2_147_483_647)
  defp bounded_count(_value), do: 0
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of atproto/bridge.ex
