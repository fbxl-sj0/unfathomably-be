# Unfathomably BE
# ----------------
#
# File: atproto/publisher.ex
#
# Purpose:
#   Publish eligible local ActivityPub interactions to a linked AT repository.
#
# Responsibilities:
#   - translate posts, replies, quotes, likes, reposts, follows, and removals
#   - use URI/CID strong references retained by the selective ingest store
#   - upload compatible local attachments and build native media embeds
#   - make retries idempotent through ActivityPub-to-AT record mappings
#
# This file intentionally does NOT expose session tokens, truncate user text
# silently, consume a firehose, or publish as an unlinked local account.

defmodule Pleroma.ATProto.Publisher do
  alias Pleroma.Activity
  alias Pleroma.ATProto.Client
  alias Pleroma.ATProto.Blobs
  alias Pleroma.ATProto.Identities
  alias Pleroma.ATProto.Links
  alias Pleroma.ATProto.Record
  alias Pleroma.ATProto.RichText
  alias Pleroma.ATProto.Store
  alias Pleroma.HTML
  alias Pleroma.Object
  alias Pleroma.User

  @post_collection "app.bsky.feed.post"

  def publish(%Activity{} = activity) do
    with %User{} = actor <- User.get_cached_by_ap_id(activity.data["actor"]),
         true <- actor.local,
         false <- Identities.mirror?(actor),
         false <- Pleroma.Nostr.Identity.mirror?(actor),
         false <- Pleroma.Diaspora.Identities.mirror?(actor),
         false <- activity.data["unfathomably:atproto_ingest"] == true,
         false <- activity.data["unfathomably:nostr_ingest"] == true,
         false <- activity.data["unfathomably:diaspora_ingest"] == true,
         true <- Links.linked?(actor) do
      case activity.data["type"] do
        "Create" -> publish_create(activity, actor)
        "Update" -> publish_update(activity, actor)
        "Like" -> publish_subject_record(activity, actor, "app.bsky.feed.like")
        "Announce" -> publish_subject_record(activity, actor, "app.bsky.feed.repost")
        "Follow" -> publish_follow(activity, actor)
        "Delete" -> publish_delete(activity, actor)
        "Undo" -> publish_undo(activity, actor)
        _ -> :ok
      end
    else
      _ -> :ok
    end
  end

  def publish(_activity), do: :ok

  defp publish_create(activity, actor) do
    case Store.get_by_ap_activity_id(activity.id) do
      %Record{} ->
        :ok

      nil ->
        with %Object{} = object <- Object.normalize(activity, fetch: false),
             false <- object.data["type"] == "ChatMessage",
             {:ok, response, session, record} <-
               create_post_record(actor, object, activity) do
          retain_local_record(
            response,
            session,
            @post_collection,
            record,
            activity,
            object.data["id"]
          )
        else
          false -> :ok
          nil -> :ok
          error -> error
        end
    end
  end

  defp publish_update(activity, actor) do
    target = object_id(activity.data["object"])

    with %Record{local: true} = existing <- Store.get_by_ap_object_id(target),
         %Object{} = object <- Object.normalize(activity, fetch: false),
         {:ok, response, session, record} <- update_post_record(actor, existing, object) do
      retain_local_record(
        response,
        session,
        @post_collection,
        record,
        activity,
        object.data["id"]
      )
    else
      nil -> :ok
      error -> error
    end
  end

  defp publish_subject_record(activity, actor, collection) do
    case Store.get_by_ap_activity_id(activity.id) do
      %Record{} ->
        :ok

      nil ->
        with %Record{} = target <- target_record(activity.data["object"]),
             record = %{
               "$type" => collection,
               "subject" => strong_reference(target),
               "createdAt" => published_at(activity)
             },
             {:ok, response, session} <- create_record(actor, collection, record, activity) do
          retain_local_record(response, session, collection, record, activity, nil)
        else
          nil -> :ok
          error -> error
        end
    end
  end

  defp publish_follow(activity, actor) do
    case Store.get_by_ap_activity_id(activity.id) do
      %Record{} ->
        :ok

      nil ->
        with target when is_binary(target) <- object_id(activity.data["object"]),
             %User{} = followed <- User.get_cached_by_ap_id(target),
             identity when not is_nil(identity) <- Identities.get_by_user(followed),
             record = %{
               "$type" => "app.bsky.graph.follow",
               "subject" => identity.did,
               "createdAt" => published_at(activity)
             },
             {:ok, response, session} <-
               create_record(actor, "app.bsky.graph.follow", record, activity) do
          retain_local_record(
            response,
            session,
            "app.bsky.graph.follow",
            record,
            activity,
            nil
          )
        else
          nil -> :ok
          error -> error
        end
    end
  end

  defp publish_delete(activity, actor) do
    target = object_id(activity.data["object"])

    case Store.get_by_ap_object_id(target) || Store.get_by_ap_activity_uri(target) do
      %Record{local: true} = record -> delete_record(actor, record)
      _ -> :ok
    end
  end

  defp publish_undo(activity, actor) do
    target = object_id(activity.data["object"])

    record =
      Store.get_by_ap_activity_uri(target) ||
        case Activity.get_by_ap_id(target) do
          %Activity{id: id} -> Store.get_by_ap_activity_id(id)
          _ -> nil
        end

    case record do
      %Record{local: true} -> delete_record(actor, record)
      _ -> :ok
    end
  end

  defp post_record(object, session) do
    content =
      object.data["content"]
      |> to_string()
      |> HTML.strip_tags()
      |> String.trim()

    attachments = object.data |> Map.get("attachment", []) |> List.wrap()

    with {:ok, media_embed, fallback_urls} <- Blobs.prepare(attachments, session),
         text <- Enum.join([content | fallback_urls] |> Enum.reject(&(&1 == "")), "\n\n"),
         {text, facets} <- RichText.outbound(text, List.wrap(object.data["tag"])),
         true <- String.valid?(text),
         true <- String.length(text) <= 300 and byte_size(text) <= 3_000 do
      record = %{
        "$type" => @post_collection,
        "text" => text,
        "createdAt" => object.data["published"] || DateTime.to_iso8601(DateTime.utc_now())
      }

      record = if facets == [], do: record, else: Map.put(record, "facets", facets)

      with {:ok, record} <- maybe_put_reply(record, object.data["inReplyTo"]) do
        {:ok, record |> maybe_put_embed(object) |> merge_media_embed(media_embed)}
      end
    else
      _ -> {:error, :atproto_text_too_long}
    end
  end

  defp maybe_put_reply(record, parent_id) when is_binary(parent_id) do
    case Store.get_by_ap_object_id(parent_id) do
      %Record{} = parent ->
        root = reply_root(parent) || strong_reference(parent)

        {:ok,
         Map.put(record, "reply", %{
           "root" => root,
           "parent" => strong_reference(parent)
         })}

      nil ->
        {:error, :atproto_reply_target_not_mapped}
    end
  end

  defp maybe_put_reply(record, _parent_id), do: {:ok, record}

  defp maybe_put_embed(record, %Object{data: %{"quoteUrl" => quote_url}})
       when is_binary(quote_url) do
    case Store.get_by_ap_object_id(quote_url) do
      %Record{} = quoted ->
        Map.put(record, "embed", %{
          "$type" => "app.bsky.embed.record",
          "record" => strong_reference(quoted)
        })

      nil ->
        external_embed(record, quote_url, "Quoted federated post")
    end
  end

  # AT Protocol external cards are the lossless common denominator for local
  # Worlds objects whose richer ActivityPub type has no Bluesky Lexicon.
  defp maybe_put_embed(record, %Object{data: data}) do
    url = data["url"] || data["id"]

    if data["type"] not in ["Article", "Note", "Page"] and is_binary(url) do
      external_embed(record, url, data["name"] || data["type"] || "Federated object")
    else
      record
    end
  end

  defp external_embed(record, "https://" <> _rest = uri, title) do
    Map.put(record, "embed", %{
      "$type" => "app.bsky.embed.external",
      "external" => %{
        "uri" => String.slice(uri, 0, 2_048),
        "title" => title |> to_string() |> String.slice(0, 300),
        "description" => "Shared from #{URI.parse(uri).host || "the fediverse"}"
      }
    })
  end

  defp external_embed(record, _uri, _title), do: record

  defp merge_media_embed(record, nil), do: record

  defp merge_media_embed(
         %{"embed" => %{"$type" => "app.bsky.embed.record"} = quoted} = record,
         media
       ) do
    Map.put(record, "embed", %{
      "$type" => "app.bsky.embed.recordWithMedia",
      "record" => quoted,
      "media" => media
    })
  end

  defp merge_media_embed(record, media), do: Map.put(record, "embed", media)

  defp create_post_record(actor, object, activity) do
    rkey = deterministic_rkey(activity)

    Links.with_session(actor, fn session ->
      with {:ok, record} <- post_record(object, session),
           {:ok, response} <-
             Client.put_record(
               session.pds_url,
               session.authorization,
               session.did,
               @post_collection,
               rkey,
               record
             ) do
        {:ok, response, session, record}
      end
    end)
  end

  defp update_post_record(actor, %Record{} = existing, object) do
    Links.with_session(actor, fn session ->
      with {:ok, record} <- post_record(object, session),
           {:ok, response} <-
             Client.put_record(
               session.pds_url,
               session.authorization,
               session.did,
               existing.collection,
               existing.rkey,
               record
             ) do
        {:ok, response, session, record}
      end
    end)
  end

  defp create_record(actor, collection, record, activity) do
    rkey = deterministic_rkey(activity)

    Links.with_session(actor, fn session ->
      case Client.put_record(
             session.pds_url,
             session.authorization,
             session.did,
             collection,
             rkey,
             record
           ) do
        {:ok, response} -> {:ok, response, session}
        error -> error
      end
    end)
  end

  defp retain_local_record(
         %{"uri" => uri, "cid" => cid},
         session,
         _collection,
         native_record,
         activity,
         object_id
       ) do
    view = %{
      "uri" => uri,
      "cid" => cid,
      "author" => %{"did" => session.did, "handle" => session.handle},
      "record" => native_record,
      "indexedAt" => DateTime.to_iso8601(DateTime.utc_now())
    }

    with {:ok, _record} <-
           Store.put(view, "local",
             local: true,
             ap_activity_id: activity.id,
             ap_activity_uri: activity.data["id"],
             ap_object_id: object_id
           ) do
      :ok
    end
  end

  defp retain_local_record(_response, _session, _collection, _record, _activity, _object_id),
    do: {:error, :invalid_create_record_response}

  defp delete_record(actor, record) do
    result =
      Links.with_session(actor, fn session ->
        Client.delete_record(
          session.pds_url,
          session.authorization,
          session.did,
          record.collection,
          record.rkey
        )
      end)

    case result do
      {:ok, _response} ->
        Store.delete(record)
        :ok

      {:error, {:http, 400, %{"error" => "RecordNotFound"}}} ->
        Store.delete(record)
        :ok

      error ->
        error
    end
  end

  defp target_record(value) do
    value
    |> object_id()
    |> Store.get_by_ap_object_id()
  end

  defp object_id(%{"id" => id}) when is_binary(id), do: id
  defp object_id(id) when is_binary(id), do: id
  defp object_id(_value), do: nil

  defp strong_reference(record), do: %{"uri" => record.uri, "cid" => record.cid}

  defp reply_root(%Record{data: %{"record" => %{"reply" => %{"root" => root}}}})
       when is_map(root),
       do: Map.take(root, ["uri", "cid"])

  defp reply_root(_record), do: nil

  defp published_at(%Activity{data: %{"published" => published}}) when is_binary(published) do
    case DateTime.from_iso8601(published) do
      {:ok, datetime, _offset} ->
        tolerance =
          case Pleroma.Config.get([Pleroma.ATProto, :future_tolerance_seconds], 900) do
            value when is_integer(value) and value >= 0 -> value
            _value -> 900
          end

        maximum = DateTime.add(DateTime.utc_now(), tolerance, :second)
        if DateTime.compare(datetime, maximum) == :gt, do: DateTime.utc_now(), else: datetime

      _error ->
        DateTime.utc_now()
    end
    |> DateTime.to_iso8601()
  end

  defp published_at(_activity), do: DateTime.to_iso8601(DateTime.utc_now())

  defp deterministic_rkey(%Activity{} = activity) do
    seed = activity.data["id"] || to_string(activity.id)
    "uf_" <> Base.url_encode64(:crypto.hash(:sha256, seed), padding: false)
  end
end

# end of atproto/publisher.ex
