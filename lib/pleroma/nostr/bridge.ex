# Unfathomably BE
# ----------------
#
# File: nostr/bridge.ex
#
# Purpose:
#   Translate between verified Nostr events and canonical ActivityPub records.
#
# Responsibilities:
#   - authorize relay events before persistence
#   - import profiles, posts, replies, reactions, reposts, deletes, and contacts
#   - export Nostr-targeted ActivityPub interactions with NIP-48 provenance
#   - publish signed events to the local store and selected external relays
#   - construct narrow subscriptions for mapped identities and communities
#
# This file intentionally does NOT own NIP-29 membership policy, WebSocket
# lifecycle, or private key storage.

defmodule Pleroma.Nostr.Bridge do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.FollowingRelationship
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Community
  alias Pleroma.Nostr.CommunityDiscovery
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Keys
  alias Pleroma.Nostr.Media
  alias Pleroma.Nostr.NIP05
  alias Pleroma.Nostr.PrivateMessages
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayHub
  alias Pleroma.Nostr.RelayManager
  alias Pleroma.Nostr.Semantics
  alias Pleroma.Nostr.Store
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.CommonAPI.ActivityDraft
  alias Pleroma.Workers.NostrProfileBackfillWorker

  @content_kinds [1, 9, 11, 20, 21, 22, 1_068, 1_111, 1_311, 30_023, 30_311, 31_922, 31_923]
  @profile_metadata_kinds [
    0,
    3,
    10_002,
    10_008,
    10_009,
    10_011,
    10_050,
    30_008,
    30_009,
    30_315
  ]
  @profile_activity_kinds [
    1,
    5,
    6,
    7,
    9,
    11,
    20,
    21,
    22,
    1_018,
    1_068,
    1_111,
    1_311,
    30_023,
    30_311,
    31_922,
    31_923,
    31_925
  ]
  @group_metadata_kinds [39_000, 39_001, 39_002, 39_003, 39_005]
  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @subscription_cache :nostr_subscriptions_cache
  @followed_profiles_cache_key :followed_profiles
  @metadata_publication_interval 86_400
  @metadata_publication_relay_limit 32
  @local_response_subscription_overlap_seconds 604_800

  def ingest_event(raw_event, relay_url, source) do
    relay_url = Protocol.normalize_relay_url(relay_url)

    with true <- Nostr.enabled?(),
         true <- Nostr.allowed_relay?(relay_url),
         {:ok, event} <- Protocol.validate_event(raw_event),
         :ok <- Semantics.bridgeable?(event),
         :ok <- Community.authorize(event, relay_url, source),
         {:ok, stored, inserted?} <- Store.put(event, relay_url: relay_url, local: false),
         :ok <- Identity.promote_native_relay(event, relay_url),
         :ok <- maybe_translate(event, stored, relay_url, inserted?) do
      RelayHub.broadcast(event)
      {:ok, event}
    else
      false -> {:error, "restricted", "relay is not approved"}
      {:error, prefix, reason} -> {:error, prefix, reason}
      {:error, reason} -> {:error, error_prefix(reason), error_message(reason)}
      _ -> {:error, "error", "event was rejected"}
    end
  end

  def ingest_approved_community_event(raw_event, approval, definition, relay_url) do
    relay_url = Protocol.normalize_relay_url(relay_url)

    with true <- Nostr.enabled?(),
         true <- Nostr.allowed_relay?(relay_url),
         {:ok, event} <- Protocol.validate_event(raw_event),
         :ok <- CommunityDiscovery.authorize_approved_submission(event, approval, definition),
         {:ok, stored, inserted?} <- Store.put(event, relay_url: relay_url, local: false),
         :ok <- Identity.promote_native_relay(event, relay_url),
         projection_event = approved_projection_event(event, definition),
         :ok <- maybe_translate_approved(projection_event, stored, relay_url, inserted?) do
      RelayHub.broadcast(event)
      {:ok, event}
    else
      false -> {:error, "restricted", "relay is not approved"}
      {:error, prefix, reason} -> {:error, prefix, reason}
      {:error, reason} -> {:error, error_prefix(reason), error_message(reason)}
      _ -> {:error, "error", "approved community event was rejected"}
    end
  end

  # NIP-72 approvals carry the authoritative community coordinate. Some
  # clients omit the optional `a` tag from the embedded submission, so attach
  # that verified coordinate only to the local projection. The signed event
  # stored and relayed above remains byte-for-byte faithful to its author.
  defp approved_projection_event(event, %{"kind" => 34_550, "pubkey" => pubkey} = definition)
       when is_binary(pubkey) do
    with identifier when is_binary(identifier) <- Protocol.tag_value(definition, "d") do
      coordinate = "34550:#{pubkey}:#{identifier}"
      tags = List.wrap(event["tags"])

      if Enum.any?(tags, fn
           [marker, ^coordinate | _rest] when marker in ["a", "A"] -> true
           _tag -> false
         end) do
        event
      else
        Map.put(event, "tags", [["a", coordinate] | tags])
      end
    else
      _ -> event
    end
  end

  defp approved_projection_event(event, _definition), do: event

  def follow(%User{} = follower, %User{} = followed) do
    with %Entity{kind: "mirror_profile"} <- Identity.get_by_user(followed),
         {:ok, follower, _followed} <- User.follow(follower, followed, :follow_accept),
         :ok <- publish_contacts(follower) do
      NostrProfileBackfillWorker.enqueue(followed)
      User.set_cache(follower)
    else
      nil -> {:error, "Not a Nostr profile"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Could not follow Nostr profile"}
    end
  end

  def backfill_media(%Pleroma.Nostr.Event{ap_activity_id: activity_id, data: event})
      when not is_nil(activity_id) do
    with %Activity{} = activity <- Activity.get_by_id(activity_id),
         object_ap_id when is_binary(object_ap_id) <- activity.data["object"],
         %Object{} = object <- Object.get_by_ap_id(object_ap_id),
         [] <- List.wrap(object.data["attachment"]),
         [_attachment | _rest] = attachments <- Media.attachments(event),
         {:ok, _object} <- Object.update_data(object, %{"attachment" => attachments}) do
      :updated
    else
      _ -> :unchanged
    end
  end

  def backfill_media(_event), do: :unchanged

  def unfollow(%User{} = follower, %User{} = followed) do
    with %Entity{kind: "mirror_profile"} <- Identity.get_by_user(followed),
         {:ok, follower, _follow_activity} <- User.unfollow(follower, followed),
         :ok <- publish_contacts(follower) do
      User.set_cache(follower)
    else
      nil -> {:error, "Not a Nostr profile"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Could not unfollow Nostr profile"}
    end
  end

  def publish_activity(%Activity{} = activity) do
    with true <- Nostr.bridge_enabled?(),
         %User{} = actor <- User.get_cached_by_ap_id(activity.data["actor"]),
         false <- Identity.mirror?(actor),
         false <- Pleroma.ATProto.Identities.mirror?(actor),
         false <- Pleroma.Diaspora.Identities.mirror?(actor),
         false <- internal_actor?(actor),
         false <- activity.data["unfathomably:nostr_ingest"] == true do
      case activity.data["type"] do
        "Create" ->
          publish_create_unless_chat(activity, actor)

        "Listen" ->
          Pleroma.Nostr.ProfileExtensions.publish_listen(
            activity,
            actor,
            &publish_actor_event/6
          )

        "Follow" ->
          publish_follow(activity, actor)

        "Like" ->
          publish_reaction(activity, actor, "+")

        "EmojiReact" ->
          publish_reaction(activity, actor, activity.data["content"] || "+")

        "Announce" ->
          publish_repost(activity, actor)

        "Delete" ->
          publish_delete(activity, actor)

        "Flag" ->
          publish_report(activity, actor)

        "Join" ->
          publish_event_join(activity, actor)

        "Undo" ->
          publish_undo(activity, actor)

        _type ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  def publish_activity(_activity), do: :ok

  def publish_chat_message(activity, sender, recipient, content) do
    PrivateMessages.publish_chat_message(
      activity,
      sender,
      recipient,
      content,
      &publish_signed/3
    )
  end

  def publish_unfollow(%Activity{} = activity, %User{} = actor, %User{} = target) do
    publish_unfollow_target(activity, actor, target)
  end

  def publish_unfollow(_activity, _actor, _target), do: :ok

  def publish_actor_event(actor, kind, tags, content, relays, mapping \\ []) do
    with {:ok, entity} <- Identity.local_actor(actor),
         {:ok, private_key} <- Keys.private_key("actor:#{actor.id}"),
         metadata_relays = actor_metadata_relays(),
         :ok <- ensure_profile_event(actor, entity, private_key, metadata_relays),
         :ok <- ensure_relay_list_event(entity, private_key, metadata_relays),
         {:ok, event} <- Protocol.sign_event(kind, tags, content, private_key) do
      publish_signed(event, relays, mapping)
    end
  end

  def publish_profile(%User{local: true, is_active: true} = actor) do
    relays = actor_metadata_relays()

    with true <- Nostr.bridge_enabled?(),
         false <- Identity.mirror?(actor),
         false <- internal_actor?(actor),
         {:ok, entity} <- Identity.local_actor(actor),
         {:ok, private_key} <- Keys.private_key("actor:#{actor.id}"),
         :ok <- publish_profile_event(actor, entity, private_key, relays, true),
         :ok <- ensure_relay_list_event(entity, private_key, relays),
         :ok <-
           PrivateMessages.publish_relay_list(
             actor,
             entity,
             private_key,
             relays,
             &publish_signed/3
           ),
         :ok <-
           Pleroma.Nostr.ProfileExtensions.publish_local_badges(
             actor,
             entity,
             private_key,
             relays,
             &publish_signed/3
           ) do
      :ok
    else
      false -> :ok
      error -> error
    end
  end

  def publish_profile(_actor), do: :ok

  def publish_relay_event(kind, tags, content, mapping \\ []) do
    with {:ok, private_key} <- Keys.private_key("relay"),
         {:ok, event} <- Protocol.sign_event(kind, tags, content, private_key) do
      publish_signed(event, [Nostr.relay_url()], mapping)
    end
  end

  @doc "Repairs signed profile mentions on existing Nostr projections without replaying them."
  def backfill_mentions(limit \\ 20_000)

  def backfill_mentions(limit) when is_integer(limit) and limit > 0 do
    Pleroma.Nostr.Event
    |> where(
      [event],
      event.kind in ^@content_kinds and not is_nil(event.ap_activity_id)
    )
    |> order_by([event], asc: event.id)
    |> limit(^min(limit, 50_000))
    |> Repo.all()
    |> Enum.map(&repair_projection_mentions/1)
    |> Enum.frequencies()
  end

  def backfill_mentions(_limit), do: %{skipped: 0}

  def filters_for_relay(relay_url) do
    profile_discovery_relays = Nostr.profile_discovery_relays()
    live_subscription_since = live_subscription_since()

    entities =
      Entity
      |> where(relay_url: ^relay_url)
      |> Repo.all()

    followed_profiles = followed_profile_entities()

    metadata_profiles =
      followed_profiles
      |> Enum.filter(fn entity ->
        relay_url in Identity.relay_urls(entity, :write) or
          relay_url in profile_discovery_relays
      end)
      |> Enum.map(& &1.pubkey)

    activity_profiles =
      followed_profiles
      |> Enum.filter(&(relay_url in Identity.relay_urls(&1, :write)))
      |> Enum.map(& &1.pubkey)

    groups =
      entities
      |> Enum.filter(fn entity ->
        entity.kind == "mirror_group" and
          get_in(entity.metadata || %{}, ["community_standard"]) != "nip72"
      end)

    local_actor_pubkeys =
      Entity
      |> where(kind: "local_actor")
      |> select([entity], entity.pubkey)
      |> Repo.all()

    filters =
      Enum.flat_map(@profile_metadata_kinds, fn kind ->
        chunk_filter(metadata_profiles, fn pubkeys ->
          %{"authors" => pubkeys, "kinds" => [kind], "limit" => length(pubkeys)}
        end)
      end) ++
        chunk_filter(activity_profiles, fn pubkeys ->
          %{
            "authors" => pubkeys,
            "kinds" => @profile_activity_kinds,
            "limit" => 500,
            "since" => live_subscription_since
          }
        end) ++
        chunk_filter(activity_profiles, fn pubkeys ->
          %{
            "#p" => pubkeys,
            "kinds" => [8],
            "limit" => 500,
            "since" => live_subscription_since
          }
        end) ++
        chunk_filter(local_actor_pubkeys, fn pubkeys ->
          %{
            "#p" => pubkeys,
            "kinds" => @profile_activity_kinds,
            "limit" => 500,
            "since" => local_response_subscription_since()
          }
        end) ++
        chunk_filter(local_actor_pubkeys, fn pubkeys ->
          %{
            "#p" => pubkeys,
            "kinds" => [1_059],
            "limit" => 500,
            "since" => PrivateMessages.subscription_since()
          }
        end) ++
        Enum.flat_map(@group_metadata_kinds, fn kind ->
          chunk_filter(groups, fn group_chunk ->
            %{
              "#d" => Enum.map(group_chunk, & &1.group_id),
              "authors" => Enum.map(group_chunk, & &1.pubkey) |> Enum.uniq(),
              "kinds" => [kind],
              "limit" => 500
            }
          end)
        end) ++
        chunk_filter(groups, fn group_chunk ->
          %{
            "#h" => Enum.map(group_chunk, & &1.group_id),
            "limit" => 500
          }
        end)

    # Group catalog discovery uses bounded request subscriptions. A permanent
    # unscoped metadata subscription would replay unrelated relay history into
    # Oban on every reconnect and bypass the user's discovery workflow.
    filters
  end

  # Relay processes reconnect independently, but they all need the same small
  # set of profiles followed by genuine local accounts. Cachex's courier runs
  # this fallback once for concurrent misses, preventing a relay outage from
  # turning one reconnect wave into repeated local-versus-mirrored user scans.
  defp followed_profile_entities do
    case @cachex.fetch(@subscription_cache, @followed_profiles_cache_key, fn ->
           {:commit, followed_profile_entities_query()}
         end) do
      {status, profiles} when status in [:ok, :commit] and is_list(profiles) ->
        profiles

      _ ->
        followed_profile_entities_query()
    end
  end

  defp followed_profile_entities_query do
    Entity
    |> join(:inner, [entity], relationship in FollowingRelationship,
      on: relationship.following_id == entity.user_id
    )
    |> join(:inner, [_entity, relationship], follower in User,
      on: follower.id == relationship.follower_id
    )
    |> join(:left, [_entity, _relationship, follower], follower_entity in Entity,
      on:
        follower_entity.user_id == follower.id and
          follower_entity.kind in ["mirror_profile", "mirror_group"]
    )
    |> where(
      [entity, relationship, follower, follower_entity],
      entity.kind == "mirror_profile" and
        relationship.state == ^:follow_accept and
        follower.local and
        is_nil(follower_entity.id)
    )
    |> select([entity], entity)
    |> distinct(true)
    |> Repo.all()
  end

  # The raw event is stored before projection so relay echoes can be
  # deduplicated safely. If the first projection failed after that insert, a
  # later relay replay must still repair the missing ActivityPub mapping.
  defp maybe_translate_approved(
         %{"kind" => kind} = event,
         %{ap_activity_id: activity_id} = stored,
         relay_url,
         false
       )
       when kind in @content_kinds and is_binary(activity_id) do
    case Community.group_for_event(event, relay_url) do
      %User{} = group -> repair_projection_group(stored, group)
      _ -> maybe_translate(event, stored, relay_url, false)
    end
  end

  defp maybe_translate_approved(event, stored, relay_url, inserted?) do
    maybe_translate(event, stored, relay_url, inserted?)
  end

  defp repair_projection_group(%{ap_activity_id: activity_id}, %User{} = group) do
    with %Activity{} = activity <- Activity.get_by_id(activity_id),
         %Object{} = object <- Object.normalize(activity, fetch: false) do
      recipients = Enum.uniq([group.ap_id | List.wrap(activity.recipients)])
      activity_data = maybe_address_group(activity.data, group)
      object_data = maybe_address_group(object.data, group)

      if recipients == activity.recipients and object_data == object.data do
        :ok
      else
        Ecto.Multi.new()
        |> Ecto.Multi.update(
          :activity,
          Ecto.Changeset.change(activity, data: activity_data, recipients: recipients)
        )
        |> Ecto.Multi.update(:object, Object.change(object, %{data: object_data}))
        |> Repo.transaction()
        |> case do
          {:ok, %{activity: updated_activity, object: updated_object}} ->
            Object.set_cache(updated_object)
            ActivityPub.stream_out(%{updated_activity | object: updated_object})
            :ok

          {:error, _operation, reason, _changes} ->
            {:error, "error", inspect(reason)}
        end
      end
    else
      _ -> :ok
    end
  end

  defp maybe_translate(
         %{"kind" => kind} = event,
         %{ap_activity_id: nil} = stored,
         relay_url,
         false
       )
       when kind in @content_kinds do
    maybe_translate(event, stored, relay_url, true)
  end

  defp maybe_translate(_event, _stored, _relay_url, false), do: :ok

  defp maybe_translate(event, stored, relay_url, true) do
    cond do
      Protocol.proxy_activitypub?(event) ->
        :ok

      empty_unprojectable_text_event?(event) ->
        :ok

      event["kind"] == 0 ->
        Identity.update_profile(event, relay_url) |> normalize_translation_result()

      event["kind"] == 3 ->
        import_contacts(event, relay_url)

      event["kind"] == 10_002 ->
        Identity.update_relay_list(event, relay_url) |> normalize_translation_result()

      event["kind"] == 10_011 ->
        Identity.update_external_identities(event, relay_url) |> normalize_translation_result()

      event["kind"] in [8, 10_008, 30_008, 30_009, 30_315] ->
        Pleroma.Nostr.ProfileExtensions.import(event, relay_url, &ingest_event/3)
        |> normalize_translation_result()

      event["kind"] == 10_050 ->
        PrivateMessages.import_relay_list(event, relay_url)

      event["kind"] == 1_059 ->
        PrivateMessages.import(event, stored, relay_url)

      event["kind"] == 1_018 ->
        Pleroma.Nostr.Poll.import_response(event, stored, relay_url)

      event["kind"] == 1_984 ->
        Pleroma.Nostr.Moderation.import_report(event, stored, relay_url)

      event["kind"] == 31_925 ->
        Pleroma.Nostr.Events.import_rsvp(event, stored, relay_url)

      event["kind"] in @content_kinds ->
        import_content(event, stored, relay_url)

      event["kind"] == 5 ->
        import_delete(event)

      event["kind"] == 6 ->
        import_repost(event, stored, relay_url)

      event["kind"] == 7 ->
        import_reaction(event, stored, relay_url)

      event["kind"] in @group_metadata_kinds ->
        Community.handle_metadata(event, relay_url)

      event["kind"] in 9_000..9_022 ->
        Community.handle_management(event, relay_url)

      true ->
        :ok
    end
  end

  # A signed Nostr text event may legally contain no text. Relay clients use
  # these occasionally as empty replies or abandoned drafts. Keep the signed
  # event in the native store and relay it faithfully, but do not repeatedly
  # ask ActivityDraft to create an ActivityPub status with no body or media.
  # Media-only notes remain eligible for projection.
  defp empty_unprojectable_text_event?(%{"kind" => kind, "content" => content} = event)
       when kind in [1, 9, 11, 1_111, 30_023] and is_binary(content) do
    String.trim(content) == "" and Media.attachments(event) == []
  end

  defp empty_unprojectable_text_event?(_event), do: false

  defp import_content(event, stored, relay_url) do
    case verified_activitypub_proxy(event) do
      {:ok, activity} ->
        map_event_to_activity(stored.id, activity)

      :none ->
        import_content_projection(event, stored, relay_url)
    end
  end

  defp publish_create_unless_chat(activity, actor) do
    case Object.normalize(activity, fetch: false) do
      %Object{data: %{"type" => "ChatMessage"}} -> :ok
      _object -> publish_create(activity, actor)
    end
  end

  def reconcile_activitypub_proxy(event_id) when is_binary(event_id) do
    with %Pleroma.Nostr.Event{} = stored <- Store.get(event_id),
         {:ok, activity} <- verified_activitypub_proxy(stored.data) do
      replace_projection_mapping(stored, activity)
    else
      _ -> :ok
    end
  end

  def reconcile_activitypub_proxy(_event_id), do: :ok

  defp import_content_projection(event, stored, relay_url) do
    if Community.private_event?(event, relay_url) do
      :ok
    else
      do_import_content_projection(event, stored, relay_url)
    end
  end

  defp do_import_content_projection(event, stored, relay_url) do
    with {:ok, actor} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         :ok <- ensure_tagged_profiles(event, relay_url),
         {:ok, draft} <- ActivityDraft.create(actor, inbound_post_params(event)),
         {:ok, activity} <-
           draft.changes
           |> inbound_changes(event, relay_url)
           |> ActivityPub.create() do
      object = Object.normalize(activity, fetch: false)

      case Store.claim_activity(stored.id, activity.id, object && object.data["id"]) do
        {:ok, :claimed} ->
          :ok

        {:ok, existing_activity_id} ->
          remove_unclaimed_projection(activity, existing_activity_id)
          :ok

        {:error, reason} ->
          {:error, "error", inspect(reason)}
      end
    else
      {:error, reason} -> {:error, "error", inspect(reason)}
      _ -> {:error, "error", "could not import Nostr post"}
    end
  end

  defp verified_activitypub_proxy(event) do
    with activity_uri when is_binary(activity_uri) <- activitypub_proxy_uri(event),
         %Activity{} = activity <- Activity.get_by_ap_id(activity_uri),
         true <- activity.data["type"] == "Create",
         actor_id when is_binary(actor_id) <- activity.data["actor"],
         %User{} = actor <- User.get_cached_by_ap_id(actor_id),
         true <- same_https_origin?(activity_uri, actor.ap_id),
         {:ok, _identity} <- NIP05.verify(User.full_nickname(actor), event["pubkey"]) do
      {:ok, activity}
    else
      _ -> :none
    end
  end

  defp activitypub_proxy_uri(%{"tags" => tags}) when is_list(tags) do
    Enum.find_value(tags, fn
      ["proxy", uri, "activitypub" | _rest] when is_binary(uri) and byte_size(uri) <= 2_048 ->
        case URI.new(uri) do
          {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) -> uri
          _ -> nil
        end

      _tag ->
        nil
    end)
  end

  defp activitypub_proxy_uri(_event), do: nil

  defp same_https_origin?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, %URI{scheme: "https", host: left_host, port: left_port}} <- URI.new(left),
         {:ok, %URI{scheme: "https", host: right_host, port: right_port}} <- URI.new(right) do
      String.downcase(left_host) == String.downcase(right_host) and left_port == right_port
    else
      _ -> false
    end
  end

  defp same_https_origin?(_left, _right), do: false

  defp replace_projection_mapping(stored, activity) do
    if stored.ap_activity_id && stored.ap_activity_id != activity.id do
      delete_projection(stored)
    end

    map_event_to_activity(stored.id, activity)
  end

  defp map_event_to_activity(event_id, activity) do
    object = Object.normalize(activity, fetch: false)
    Store.map_activity(event_id, activity.id, object && object.data["id"])
  end

  defp remove_unclaimed_projection(activity, existing_activity_id)
       when activity.id != existing_activity_id do
    with %User{} = actor <- User.get_cached_by_ap_id(activity.data["actor"]) do
      CommonAPI.delete(activity.id, actor)
    end
  end

  defp remove_unclaimed_projection(_activity, _existing_activity_id), do: :ok

  defp inbound_post_params(event) do
    params =
      %{
        status: Pleroma.Nostr.References.inbound(event["content"], event),
        content_type: "text/plain",
        visibility: "public"
      }
      |> Semantics.put_inbound_params(event)
      |> Pleroma.Nostr.Poll.put_inbound_params(event)
      |> Pleroma.Nostr.Events.put_inbound_params(event)

    case reply_target(event) do
      %Pleroma.Nostr.Event{ap_activity_id: activity_id} when not is_nil(activity_id) ->
        Map.put(params, :in_reply_to_status_id, activity_id)

      _ ->
        params
    end
  end

  defp inbound_changes(changes, event, relay_url) do
    group = Community.group_for_event(event, relay_url)
    published = DateTime.from_unix!(event["created_at"])

    object =
      changes.object
      |> Pleroma.Nostr.References.put_inbound_mentions(event)
      |> restore_native_source(event["content"])
      |> Map.put("published", DateTime.to_iso8601(published))
      |> Map.put("unfathomably:nostr", %{
        "event_id" => event["id"],
        "pubkey" => event["pubkey"],
        "relay" => relay_url
      })
      |> Media.put_attachments(event)
      |> Semantics.put_object_metadata(event)
      |> Pleroma.Nostr.Poll.put_object_metadata(event)
      |> Pleroma.Nostr.Events.put_object_metadata(event)
      |> maybe_set_article(event)
      |> maybe_address_group(group)

    additional =
      changes.additional
      |> Map.put("unfathomably:nostr_ingest", true)
      |> maybe_add_group_recipient(group)

    changes
    |> Map.put(:object, object)
    |> Map.put(:additional, additional)
    |> Map.put(:local, false)
    |> Map.put(:published, DateTime.to_iso8601(published))
    |> maybe_add_group_to(group)
  end

  defp ensure_tagged_profiles(event, relay_url) do
    event
    |> Protocol.tag_values("p")
    |> Enum.filter(&(is_binary(&1) and &1 != event["pubkey"]))
    |> Enum.uniq()
    |> Enum.take(32)
    |> Enum.each(fn pubkey ->
      Identity.resolve(%{type: :profile, pubkey: pubkey, relays: [relay_url]})
    end)

    :ok
  end

  defp restore_native_source(object, content) when is_binary(content) do
    source = Map.put(object["source"] || %{}, "content", content)
    Map.put(object, "source", source)
  end

  defp restore_native_source(object, _content), do: object

  defp repair_projection_mentions(%Pleroma.Nostr.Event{
         ap_activity_id: activity_id,
         data: event,
         relay_url: relay_url
       })
       when is_binary(activity_id) and is_map(event) do
    relay_url =
      if is_binary(relay_url) and relay_url != "", do: relay_url, else: Nostr.relay_url()

    with :ok <- ensure_tagged_profiles(event, relay_url),
         [_mention | _rest] <- Pleroma.Nostr.References.tagged_mentions(event),
         %Activity{} = activity <- Activity.get_by_id(activity_id),
         %Object{} = object <- Object.normalize(activity, fetch: false),
         generated <-
           object.data
           |> Pleroma.Nostr.References.put_inbound_mentions(event)
           |> restore_native_source(event["content"]),
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

  defp repair_projection_mentions(_event), do: :skipped

  defp maybe_set_article(object, %{"kind" => 30_023} = event) do
    object
    |> Map.put("type", "Article")
    |> Map.put("name", Protocol.tag_value(event, "title") || "Nostr article")
    |> Map.put("summary", Protocol.tag_value(event, "summary"))
  end

  defp maybe_set_article(object, _event), do: object

  defp maybe_address_group(object, %User{} = group) do
    object
    |> Map.update("cc", [group.ap_id], &Enum.uniq([group.ap_id | List.wrap(&1)]))
    |> Map.put("audience", group.ap_id)
  end

  defp maybe_address_group(object, _group), do: object

  defp maybe_add_group_recipient(additional, %User{} = group) do
    Map.update(additional, "cc", [group.ap_id], &Enum.uniq([group.ap_id | List.wrap(&1)]))
  end

  defp maybe_add_group_recipient(additional, _group), do: additional

  defp maybe_add_group_to(changes, %User{} = group) do
    Map.update(changes, :to, [group.ap_id], &Enum.uniq([group.ap_id | List.wrap(&1)]))
  end

  defp maybe_add_group_to(changes, _group), do: changes

  defp import_reaction(event, stored, relay_url) do
    with %Pleroma.Nostr.Event{ap_activity_id: activity_id} <- referenced_event(event),
         %Activity{} = mapped_target <- Activity.get_by_id(activity_id),
         %Activity{} = target <- canonical_create(mapped_target),
         {:ok, actor} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}) do
      content = event["content"]

      result =
        if content in ["", "+"] do
          CommonAPI.favorite(actor, target.id)
        else
          CommonAPI.react_with_emoji(target.id, actor, content)
        end

      map_translation_activity(result, stored)
    else
      _ -> :ok
    end
  end

  defp import_repost(event, stored, relay_url) do
    with %Pleroma.Nostr.Event{ap_activity_id: activity_id} <- referenced_event(event),
         %Activity{} = mapped_target <- Activity.get_by_id(activity_id),
         %Activity{} = target <- canonical_create(mapped_target),
         {:ok, actor} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}) do
      target.id
      |> CommonAPI.repeat(actor)
      |> map_translation_activity(stored)
    else
      _ -> :ok
    end
  end

  defp import_delete(event) do
    event
    |> Protocol.tag_values("e")
    |> Enum.each(fn event_id ->
      with %Pleroma.Nostr.Event{pubkey: pubkey} = target <- Store.get(event_id),
           true <- pubkey == event["pubkey"] do
        delete_projection(target)
        Store.delete_event(target.id, pubkey)
      end
    end)

    :ok
  end

  defp delete_projection(%Pleroma.Nostr.Event{kind: kind, ap_activity_id: activity_id})
       when kind in @content_kinds do
    with %Activity{} = activity <- Activity.get_by_id(activity_id),
         %User{} = actor <- User.get_cached_by_ap_id(activity.data["actor"]) do
      CommonAPI.delete(activity.id, actor)
    end
  end

  defp delete_projection(%Pleroma.Nostr.Event{kind: 6} = event) do
    with %Pleroma.Nostr.Event{ap_activity_id: activity_id} <- referenced_event(event.data),
         %Activity{} = mapped_target <- Activity.get_by_id(activity_id),
         %Activity{} = target <- canonical_create(mapped_target),
         %Entity{user: %User{} = actor} <- Identity.get_profile(event.pubkey) do
      CommonAPI.unrepeat(target.id, actor)
    end
  end

  defp delete_projection(%Pleroma.Nostr.Event{kind: 7} = event) do
    with %Pleroma.Nostr.Event{ap_activity_id: activity_id} <- referenced_event(event.data),
         %Activity{} = mapped_target <- Activity.get_by_id(activity_id),
         %Activity{} = target <- canonical_create(mapped_target),
         %Entity{user: %User{} = actor} <- Identity.get_profile(event.pubkey) do
      if event.data["content"] in ["", "+"] do
        CommonAPI.unfavorite(target.id, actor)
      else
        CommonAPI.unreact_with_emoji(target.id, actor, event.data["content"])
      end
    end
  end

  defp delete_projection(_event), do: :ok

  defp import_contacts(event, relay_url) do
    with {:ok, actor} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         %Entity{} = entity <- Identity.get_by_user(actor) do
      contacts = event |> Protocol.tag_values("p") |> Enum.uniq() |> Enum.take(500)
      previous = Map.get(entity.metadata || %{}, "contacts", [])

      Enum.each(contacts -- previous, fn pubkey ->
        with {:ok, followed} <-
               Identity.resolve(%{type: :profile, pubkey: pubkey, relays: [relay_url]}),
             false <- followed.id == actor.id do
          User.follow(actor, followed, :follow_accept)
        end
      end)

      Enum.each(previous -- contacts, fn pubkey ->
        with %Entity{user: %User{} = followed} <- Identity.get_profile(pubkey) do
          User.unfollow(actor, followed)
        end
      end)

      entity
      |> Entity.changeset(%{
        metadata: Map.put(entity.metadata || %{}, "contacts", contacts),
        latest_metadata_event_id: event["id"]
      })
      |> Repo.update()

      :ok
    else
      _ -> :ok
    end
  end

  defp publish_create(activity, actor) do
    with %Object{} = object <- Object.normalize(activity, fetch: false),
         target <- outbound_target(object),
         false <- is_nil(target) do
      {kind, tags, relays} =
        Pleroma.Nostr.Poll.outbound_destination(
          object.data,
          content_destination(object, target)
        )
        |> Pleroma.Nostr.Events.outbound_destination(object.data)

      content = outbound_content(object.data)

      content = append_external_reply_reference(content, target)

      {content, reference_tags} = Pleroma.Nostr.References.outbound(content, object.data)
      {content, media_tags} = Media.outbound(content, object.data)

      publish_actor_event(
        actor,
        kind,
        tags ++
          reference_tags ++
          Semantics.outbound_tags(object.data) ++
          media_tags ++
          proxy_tags(object.data["id"]),
        content,
        relays,
        ap_activity_id: activity.id,
        ap_object_id: object.data["id"]
      )
    else
      _ -> :ok
    end
  end

  # ActivityPub stores both the user's authored source and rendered HTML. Nostr
  # is a plain-text protocol, so rebuilding local text from HTML can remove the
  # whitespace around mentions and links. Preserve supported text sources and
  # use rendered content only for objects without a usable source representation.
  defp outbound_content(%{
         "source" => %{"content" => content, "mediaType" => media_type}
       })
       when is_binary(content) and
              media_type in ["text/plain", "text/markdown", "text/x.misskeymarkdown"] do
    content
  end

  defp outbound_content(data) do
    data
    |> Map.get("content", "")
    |> to_string()
    |> Pleroma.HTML.strip_tags()
    |> HtmlEntities.decode()
  end

  defp publish_follow(activity, actor) do
    with target_ap_id when is_binary(target_ap_id) <- activity.data["object"],
         %User{} = target <- User.get_cached_by_ap_id(target_ap_id) do
      publish_follow_target(activity, actor, Identity.get_by_user(target))
    else
      _ -> :ok
    end
  end

  defp publish_follow_target(
         _activity,
         _actor,
         %Entity{kind: "mirror_group", metadata: %{"community_standard" => "nip72"}}
       ),
       do: :ok

  defp publish_follow_target(
         activity,
         actor,
         %Entity{kind: "mirror_group", relay_url: relay_url, group_id: group_id}
       )
       when is_binary(relay_url) and is_binary(group_id) do
    case publish_actor_event(
           actor,
           9_021,
           [["h", group_id]],
           "",
           [relay_url],
           ap_activity_id: activity.id
         ) do
      :ok ->
        _ = publish_simple_groups(actor)
        :ok

      error ->
        error
    end
  end

  defp publish_follow_target(activity, actor, %Entity{kind: "mirror_profile"}) do
    publish_contacts(actor, ap_activity_id: activity.id)
  end

  defp publish_follow_target(_activity, _actor, _target), do: :ok

  defp publish_report(activity, actor) do
    case Pleroma.Nostr.Moderation.outbound(activity) do
      {:ok, tags, relays, content} ->
        publish_actor_event(
          actor,
          1_984,
          tags ++ proxy_tags(activity.data["id"]),
          content,
          [Nostr.relay_url() | relays],
          ap_activity_id: activity.id
        )

      _report ->
        :ok
    end
  end

  defp publish_event_join(activity, actor) do
    case Pleroma.Nostr.Events.outbound_rsvp(activity) do
      {:ok, tags, relays, content} ->
        publish_actor_event(
          actor,
          31_925,
          tags ++ proxy_tags(activity.data["id"]),
          content || "",
          [Nostr.relay_url() | relays],
          ap_activity_id: activity.id
        )

      _join ->
        :ok
    end
  end

  defp publish_reaction(activity, actor, reaction) do
    with %Pleroma.Nostr.Event{} = target <- event_for_ap_reference(activity.data["object"]) do
      tags =
        [
          ["e", target.id, target.relay_url || Nostr.relay_url(), target.pubkey],
          ["p", target.pubkey],
          ["k", to_string(target.kind)]
        ]
        |> prepend_group_tag(target)

      publish_actor_event(
        actor,
        7,
        tags ++ proxy_tags(activity.data["id"]),
        reaction,
        destination_relays(target),
        ap_activity_id: activity.id
      )
    else
      _ -> :ok
    end
  end

  defp publish_repost(activity, %User{actor_type: "Group"}) do
    case event_for_ap_reference(activity.data["object"]) do
      nil ->
        with %Object{} = object <- Object.normalize(activity, fetch: false),
             %Activity{} = create <- Activity.get_create_by_object_ap_id(object.data["id"]),
             %User{} = author <- User.get_cached_by_ap_id(object.data["actor"]) do
          publish_create(create, author)
        else
          _ -> :ok
        end

      %Pleroma.Nostr.Event{} ->
        :ok
    end
  end

  defp publish_repost(activity, actor) do
    with %Pleroma.Nostr.Event{} = target <- event_for_ap_reference(activity.data["object"]) do
      tags =
        [
          ["e", target.id, target.relay_url || Nostr.relay_url(), target.pubkey],
          ["p", target.pubkey]
        ]
        |> prepend_group_tag(target)

      publish_actor_event(
        actor,
        6,
        tags ++ proxy_tags(activity.data["id"]),
        Jason.encode!(target.data),
        destination_relays(target),
        ap_activity_id: activity.id
      )
    else
      _ -> :ok
    end
  end

  defp publish_delete(activity, actor) do
    with %Pleroma.Nostr.Event{} = target <- event_for_ap_reference(activity.data["object"]) do
      publish_actor_event(
        actor,
        5,
        prepend_group_tag([["e", target.id]], target) ++ proxy_tags(activity.data["id"]),
        "",
        destination_relays(target),
        ap_activity_id: activity.id
      )
    else
      _ -> :ok
    end
  end

  defp publish_undo(activity, actor) do
    reference = activity.data["object"]

    case undone_activity(reference) do
      %Activity{data: %{"type" => "Follow"}} = undone ->
        publish_unfollow_activity(activity, actor, undone)

      %Activity{} = undone ->
        publish_undo_target(activity, actor, undone)

      _ ->
        publish_undo_reference(activity, actor, activity_reference_uri(reference))
    end
  end

  defp publish_unfollow_activity(activity, actor, undone) do
    with target_ap_id when is_binary(target_ap_id) <- undone.data["object"],
         %User{} = target <- User.get_cached_by_ap_id(target_ap_id) do
      publish_unfollow_target(activity, actor, target)
    else
      _ -> :ok
    end
  end

  defp publish_unfollow_target(activity, actor, target) do
    case Identity.get_by_user(target) do
      %Entity{kind: "mirror_group", metadata: %{"community_standard" => "nip72"}} ->
        :ok

      %Entity{kind: "mirror_group", relay_url: relay_url, group_id: group_id}
      when is_binary(relay_url) and is_binary(group_id) ->
        case publish_actor_event(
               actor,
               9_022,
               [["h", group_id]],
               "",
               [relay_url],
               ap_activity_id: activity.id
             ) do
          :ok ->
            _ = publish_simple_groups(actor)
            :ok

          error ->
            error
        end

      %Entity{kind: "mirror_profile"} ->
        publish_contacts(actor, ap_activity_id: activity.id)

      _ ->
        :ok
    end
  end

  defp publish_undo_target(activity, actor, undone) do
    with %Pleroma.Nostr.Event{} = target <- Store.get_by_ap_activity_id(undone.id) do
      publish_actor_event(
        actor,
        5,
        prepend_group_tag([["e", target.id]], target) ++ proxy_tags(activity.data["id"]),
        "",
        destination_relays(target),
        ap_activity_id: activity.id
      )
    else
      _ -> :ok
    end
  end

  defp publish_undo_reference(activity, actor, activity_uri) do
    case Store.get_by_ap_activity_uri(activity_uri) do
      %Pleroma.Nostr.Event{kind: 9_021} = target ->
        publish_actor_event(
          actor,
          9_022,
          group_tags(target),
          "",
          destination_relays(target),
          ap_activity_id: activity.id
        )

      %Pleroma.Nostr.Event{} = target ->
        publish_actor_event(
          actor,
          5,
          prepend_group_tag([["e", target.id]], target) ++ proxy_tags(activity.data["id"]),
          "",
          destination_relays(target),
          ap_activity_id: activity.id
        )

      _ ->
        :ok
    end
  end

  defp activity_reference_uri(reference) when is_binary(reference), do: reference
  defp activity_reference_uri(%{"id" => uri}) when is_binary(uri), do: uri
  defp activity_reference_uri(_reference), do: nil

  defp undone_activity(ap_id) when is_binary(ap_id), do: Activity.get_by_ap_id(ap_id)

  defp undone_activity(%{"id" => ap_id}) when is_binary(ap_id),
    do: Activity.get_by_ap_id(ap_id)

  defp undone_activity(_object), do: nil

  defp outbound_target(%Object{data: data} = object) do
    case Store.get_by_ap_object_id(data["inReplyTo"]) do
      %Pleroma.Nostr.Event{} = event -> {:reply, event}
      nil -> outbound_group(object) || external_reply_target(object) || public_target(object)
    end
  end

  defp external_reply_target(%Object{data: %{"inReplyTo" => parent_id}})
       when is_binary(parent_id) do
    if valid_external_thread_id?(parent_id) do
      {:external_reply, external_thread_root(parent_id, 32, MapSet.new()), parent_id}
    end
  end

  defp external_reply_target(_object), do: nil

  defp external_thread_root(current_id, 0, _seen), do: current_id

  defp external_thread_root(current_id, remaining, seen) do
    if MapSet.member?(seen, current_id) do
      current_id
    else
      seen = MapSet.put(seen, current_id)

      case Object.get_cached_by_ap_id(current_id) do
        %Object{data: %{"inReplyTo" => parent_id}} when is_binary(parent_id) ->
          if valid_external_thread_id?(parent_id) do
            external_thread_root(parent_id, remaining - 1, seen)
          else
            current_id
          end

        _object ->
          current_id
      end
    end
  end

  defp valid_external_thread_id?(id) when is_binary(id) and byte_size(id) <= 2_048 do
    case URI.new(id) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _invalid ->
        false
    end
  end

  defp valid_external_thread_id?(_id), do: false

  defp public_target(%Object{data: data}) do
    public_uri = "https://www.w3.org/ns/activitystreams#Public"
    recipients = List.wrap(data["to"]) ++ List.wrap(data["cc"])

    if Pleroma.Config.get([Pleroma.Nostr, :publish_public_posts], true) == true and
         data["unfathomably:nostr_export"] != false and data["localOnly"] != true and
         public_uri in recipients do
      :public
    end
  end

  defp outbound_group(%Object{data: data}) do
    ["audience", "to", "cc"]
    |> Enum.flat_map(&List.wrap(data[&1]))
    |> Enum.uniq()
    |> Enum.find_value(fn ap_id ->
      with %User{actor_type: "Group"} = group <- User.get_cached_by_ap_id(ap_id),
           {:ok, entity} <- outbound_group_entity(group) do
        {:group, entity}
      else
        _ -> nil
      end
    end)
  end

  defp outbound_group_entity(group) do
    case Identity.get_by_user(group) do
      %Entity{kind: kind} = entity when kind in ["local_group", "mirror_group"] ->
        {:ok, entity}

      _ ->
        Identity.local_group(group)
    end
  end

  defp content_destination(_object, :public) do
    {1, [], Pleroma.Nostr.profile_discovery_relays()}
  end

  defp content_destination(_object, {:reply, target}) do
    case Protocol.tag_value(target.data, "h") do
      nil ->
        reply_destination(target)

      group_id ->
        # NIP-29 deployments broadly use kind 9 for both roots and replies.
        # Keep NIP-22 kind 1111 for ordinary Nostr threads. Group relays often
        # enforce a small indexable-tag budget, so use the compact h/e/p form
        # rather than duplicating the same context through NIP-22 tags.
        compact_tags = [
          ["h", group_id],
          ["e", target.id, target.relay_url || Nostr.relay_url(), target.pubkey],
          ["p", target.pubkey]
        ]

        {9, compact_tags, destination_relays(target)}
    end
  end

  defp content_destination(_object, {:external_reply, root_id, parent_id}) do
    tags = [
      ["I", root_id, root_id],
      ["K", "web"],
      ["i", parent_id, parent_id],
      ["k", "web"],
      ["r", parent_id]
    ]

    {1_111, tags, Pleroma.Nostr.profile_discovery_relays()}
  end

  defp content_destination(_object, {:group, entity}) do
    {11, [["h", entity.group_id]], [entity.relay_url]}
  end

  defp reply_destination(%Pleroma.Nostr.Event{kind: 1} = target) do
    root = reply_root(target)
    root_relay = root.relay_url || Nostr.relay_url()
    target_relay = target.relay_url || Nostr.relay_url()

    event_tags =
      if root.id == target.id do
        [["e", root.id, root_relay, "root", root.pubkey]]
      else
        [
          ["e", root.id, root_relay, "root", root.pubkey],
          ["e", target.id, target_relay, "reply", target.pubkey]
        ]
      end

    participant_tags =
      ([root.pubkey, target.pubkey] ++ Protocol.tag_values(target.data, "p"))
      |> Enum.filter(&valid_nostr_pubkey?/1)
      |> Enum.uniq()
      |> Enum.map(&["p", &1])

    {1, event_tags ++ participant_tags, destination_relays(target)}
  end

  defp reply_destination(target) do
    {1_111, nip22_reply_tags(target), destination_relays(target)}
  end

  defp nip22_reply_tags(target) do
    root_tags =
      target.data
      |> Map.get("tags", [])
      |> Enum.filter(fn
        [name, _value | _rest] when name in ["A", "E", "I", "K", "P"] -> true
        _tag -> false
      end)

    root_tags =
      if Enum.any?(root_tags, fn [name | _rest] -> name in ["A", "E", "I"] end) do
        root_tags
      else
        relay = target.relay_url || Nostr.relay_url()

        [
          ["E", target.id, relay, target.pubkey],
          ["K", to_string(target.kind)],
          ["P", target.pubkey]
        ]
      end

    root_tags ++
      [
        ["e", target.id, target.relay_url || Nostr.relay_url(), target.pubkey],
        ["k", to_string(target.kind)],
        ["p", target.pubkey]
      ]
  end

  defp reply_root(target) do
    event_id =
      target.data
      |> Map.get("tags", [])
      |> Enum.find_value(fn
        ["e", id, _relay, "root" | _rest] when is_binary(id) -> id
        ["E", id | _rest] when is_binary(id) -> id
        _tag -> nil
      end)

    if is_binary(event_id), do: Store.get(event_id) || target, else: target
  end

  defp valid_nostr_pubkey?(pubkey) when is_binary(pubkey),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, pubkey)

  defp valid_nostr_pubkey?(_pubkey), do: false

  defp append_external_reply_reference(content, {:external_reply, _root_id, parent_id}) do
    cond do
      String.contains?(content, parent_id) -> content
      content == "" -> parent_id
      String.ends_with?(content, "\n") -> content <> parent_id
      true -> content <> "\n\n" <> parent_id
    end
  end

  defp append_external_reply_reference(content, _target), do: content

  defp publish_contacts(actor, mapping \\ []) do
    tags =
      actor
      |> User.get_friends()
      |> Enum.flat_map(fn followed ->
        case Identity.get_by_user(followed) do
          %Entity{kind: "mirror_profile", pubkey: pubkey, relay_url: relay_url} ->
            relay_hint = List.first(Identity.relays_for_user(followed, :write)) || relay_url || ""
            [["p", pubkey, relay_hint]]

          _ ->
            []
        end
      end)

    relays =
      tags
      |> Enum.map(&Enum.at(&1, 2))
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    publish_actor_event(actor, 3, tags, "", [Nostr.relay_url() | relays], mapping)
    _ = @cachex.del(@subscription_cache, @followed_profiles_cache_key)
    Pleroma.Nostr.RelayManager.sync_now()
    :ok
  end

  defp publish_simple_groups(actor) do
    {tags, relays} = Pleroma.Nostr.Lists.simple_groups(actor)
    publish_actor_event(actor, 10_009, tags, "", [Nostr.relay_url() | relays])
  end

  defp ensure_profile_event(actor, entity, private_key, relays) do
    publish_profile_event(actor, entity, private_key, relays, false)
  end

  defp publish_profile_event(actor, entity, private_key, relays, force?) do
    now = System.system_time(:second)

    destinations =
      publication_destinations(entity, "profile_published_relays", relays, force?, now)

    if destinations != [] do
      content =
        %{
          name: actor.nickname |> to_string() |> String.split("@", parts: 2) |> List.first(),
          display_name: actor.name,
          about: profile_about(actor),
          picture: image_url(actor.avatar),
          banner: image_url(actor.banner),
          website: profile_website(actor),
          nip05: Identity.local_nip05(actor),
          lud16: profile_lud16(actor),
          bot: actor.actor_type == "Service",
          birthday: profile_birthday(actor)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
        |> Jason.encode!()

      tags = profile_emoji_tags(actor)

      with {:ok, event} <- Protocol.sign_event(0, tags, content, private_key),
           :ok <- publish_signed(event, destinations, []) do
        update_publication_state(
          entity,
          "profile_published_at",
          "profile_published_relays",
          destinations,
          now
        )
      end
    else
      :ok
    end
  end

  defp profile_about(%User{raw_bio: raw_bio}) when is_binary(raw_bio), do: raw_bio
  defp profile_about(%User{bio: bio}) when is_binary(bio), do: bio
  defp profile_about(_actor), do: ""

  defp profile_website(actor) do
    profile_field_value(actor, ["website", "web", "homepage", "url"], &valid_profile_url?/1) ||
      actor.ap_id
  end

  defp profile_lud16(actor) do
    profile_field_value(actor, ["lightning", "lud16"], fn value ->
      byte_size(value) <= 320 and String.contains?(value, "@") and
        not String.contains?(value, ["\0", "\r", "\n"])
    end)
  end

  defp profile_field_value(actor, names, validator) do
    actor
    |> Map.get(:raw_fields, [])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"name" => name, "value" => value} when is_binary(name) and is_binary(value) ->
        if String.downcase(String.trim(name)) in names and validator.(value), do: value

      _field ->
        nil
    end)
  end

  defp profile_birthday(%User{show_birthday: true, birthday: %Date{} = birthday}) do
    %{"year" => birthday.year, "month" => birthday.month, "day" => birthday.day}
  end

  defp profile_birthday(_actor), do: nil

  defp profile_emoji_tags(actor) do
    actor
    |> Map.get(:emoji, %{})
    |> Enum.flat_map(fn
      {shortcode, url} when is_binary(shortcode) and is_binary(url) ->
        if byte_size(shortcode) in 1..64 and Regex.match?(~r/^[A-Za-z0-9_]+$/, shortcode) and
             valid_profile_url?(url) do
          [["emoji", shortcode, url]]
        else
          []
        end

      _emoji ->
        []
    end)
    |> Enum.take(64)
  end

  defp valid_profile_url?(url) when is_binary(url) and byte_size(url) <= 2_048 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _uri ->
        false
    end
  end

  defp valid_profile_url?(_url), do: false

  defp ensure_relay_list_event(entity, private_key, relays) do
    now = System.system_time(:second)

    relays =
      [Nostr.relay_url() | List.wrap(relays)]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.take(@metadata_publication_relay_limit)

    fingerprint_input = relays |> Enum.sort() |> Enum.join("\n")
    fingerprint = :crypto.hash(:sha256, fingerprint_input) |> Base.encode16(case: :lower)
    force? = get_in(entity.metadata || %{}, ["relay_list_fingerprint"]) != fingerprint

    destinations =
      publication_destinations(entity, "relay_list_published_relays", relays, force?, now)

    if destinations != [] do
      tags = Enum.map(relays, &["r", &1])

      with {:ok, event} <- Protocol.sign_event(10_002, tags, "", private_key),
           :ok <- publish_signed(event, destinations, []) do
        with :ok <-
               update_publication_state(
                 entity,
                 "relay_list_published_at",
                 "relay_list_published_relays",
                 destinations,
                 now
               ) do
          update_relay_list_fingerprint(entity, fingerprint)
        end
      end
    else
      :ok
    end
  end

  defp update_relay_list_fingerprint(entity, fingerprint) do
    entity = Repo.get(Entity, entity.id) || entity
    metadata = Map.put(entity.metadata || %{}, "relay_list_fingerprint", fingerprint)

    entity
    |> Entity.changeset(%{metadata: metadata})
    |> Repo.update()
    |> case do
      {:ok, _entity} -> :ok
      error -> error
    end
  end

  defp publication_destinations(entity, relay_key, relays, force?, now) do
    published_relays =
      case get_in(entity.metadata || %{}, [relay_key]) do
        relays when is_map(relays) -> relays
        _invalid -> %{}
      end

    [Nostr.relay_url() | List.wrap(relays)]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(@metadata_publication_relay_limit)
    |> Enum.filter(fn relay ->
      force? or
        now - publication_timestamp(published_relays[relay]) >= @metadata_publication_interval
    end)
  end

  defp update_publication_state(entity, timestamp_key, relay_key, destinations, now) do
    entity = Repo.get(Entity, entity.id) || entity
    metadata = entity.metadata || %{}

    published_relays =
      case metadata[relay_key] do
        relays when is_map(relays) -> relays
        _invalid -> %{}
      end

    published_relays =
      destinations
      |> Enum.reduce(published_relays, &Map.put(&2, &1, now))
      |> Enum.take(@metadata_publication_relay_limit)
      |> Map.new()

    entity
    |> Entity.changeset(%{
      metadata:
        metadata
        |> Map.put(timestamp_key, now)
        |> Map.put(relay_key, published_relays)
    })
    |> Repo.update()
    |> case do
      {:ok, _entity} -> :ok
      error -> error
    end
  end

  defp publication_timestamp(timestamp) when is_integer(timestamp) and timestamp > 0,
    do: timestamp

  defp publication_timestamp(_timestamp), do: 0

  defp actor_metadata_relays do
    [Nostr.relay_url() | Nostr.profile_discovery_relays()]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp publish_signed(event, relays, mapping) do
    ap_activity_id = Keyword.get(mapping, :ap_activity_id)

    ap_activity_uri =
      case ap_activity_id do
        id when is_binary(id) ->
          case Activity.get_by_id(id) do
            %Activity{data: %{"id" => uri}} when is_binary(uri) -> uri
            _ -> Keyword.get(mapping, :ap_activity_uri)
          end

        _ ->
          Keyword.get(mapping, :ap_activity_uri)
      end

    with {:ok, _stored, _inserted?} <-
           Store.put(event,
             relay_url: List.first(relays) || Nostr.relay_url(),
             local: true,
             ap_activity_id: ap_activity_id,
             ap_activity_uri: ap_activity_uri,
             ap_object_id: Keyword.get(mapping, :ap_object_id)
           ) do
      RelayHub.broadcast(event)
      RelayManager.publish(event, relays)
      :ok
    end
  end

  defp reply_target(event) do
    event
    |> Pleroma.Nostr.Thread.reply_id()
    |> case do
      nil -> nil
      event_id -> Store.get(event_id)
    end
  end

  defp referenced_event(event) do
    event
    |> Protocol.tag_values("e")
    |> List.first()
    |> case do
      nil -> nil
      event_id -> Store.get(event_id)
    end
  end

  defp event_for_ap_reference(reference) when is_binary(reference) do
    Store.get_by_ap_object_id(reference) ||
      event_from_projected_object(reference) ||
      case Activity.get_by_ap_id(reference) do
        %Activity{id: id} -> Store.get_by_ap_activity_id(id)
        _ -> nil
      end
  end

  defp event_for_ap_reference(_reference), do: nil

  # Early native projections already carry signed Nostr provenance on the
  # object, but some pre-mapping rows do not have ap_object_id populated in the
  # Nostr event store. The event ID is cryptographic, so it is a safe fallback
  # for publishing interactions against those otherwise valid projections.
  defp event_from_projected_object(reference) do
    with %Object{data: %{"unfathomably:nostr" => provenance}} <-
           Object.get_cached_by_ap_id(reference),
         event_id when is_binary(event_id) <- provenance["event_id"] do
      Store.get(event_id)
    else
      _ -> nil
    end
  end

  defp canonical_create(%Activity{data: %{"type" => "Create"}} = activity), do: activity

  defp canonical_create(%Activity{data: %{"object" => object_id}} = activity) do
    Activity.get_create_by_object_ap_id(object_id) || activity
  end

  defp canonical_create(activity), do: activity

  defp internal_actor?(%User{ap_id: ap_id}) when is_binary(ap_id) do
    ap_id in [
      Pleroma.Web.Endpoint.url() <> "/relay",
      Pleroma.Web.Endpoint.url() <> "/internal/fetch"
    ]
  end

  defp internal_actor?(_actor), do: false

  defp destination_relays(%Pleroma.Nostr.Event{data: data, relay_url: relay_url})
       when is_map(data) do
    if is_binary(Protocol.tag_value(data, "h")) do
      [relay_url]
      |> Enum.map(&Protocol.normalize_relay_url/1)
      |> Enum.filter(&Nostr.allowed_relay?/1)
      |> Enum.uniq()
    else
      profile_destination_relays(data["pubkey"], relay_url)
    end
  end

  defp destination_relays(%Pleroma.Nostr.Event{pubkey: pubkey, relay_url: relay_url}) do
    profile_destination_relays(pubkey, relay_url)
  end

  defp destination_relays(_event), do: [Nostr.relay_url()]

  defp profile_destination_relays(pubkey, relay_url) do
    profile_relays =
      case Identity.get_profile(pubkey) do
        %Entity{user: %User{} = user} -> Identity.relays_for_user(user, :read)
        _ -> []
      end

    Nostr.public_relay_destinations([relay_url] ++ profile_relays)
  end

  defp prepend_group_tag(tags, %Pleroma.Nostr.Event{data: data}) do
    case Protocol.tag_value(data, "h") do
      group_id when is_binary(group_id) and group_id != "" -> [["h", group_id] | tags]
      _ -> tags
    end
  end

  defp group_tags(%Pleroma.Nostr.Event{data: data}) do
    case Protocol.tag_value(data, "h") do
      group_id when is_binary(group_id) and group_id != "" -> [["h", group_id]]
      _ -> []
    end
  end

  defp proxy_tags(identifier) when is_binary(identifier) do
    [["proxy", identifier, "activitypub"], ["client", "Unfathomably"]]
  end

  defp proxy_tags(_identifier), do: [["client", "Unfathomably"]]

  defp image_url(%{"url" => [%{"href" => href} | _rest]}) when is_binary(href), do: href
  defp image_url(%{"url" => href}) when is_binary(href), do: href
  defp image_url(_image), do: nil

  defp chunk_filter(values, builder) do
    values
    |> Enum.chunk_every(100)
    |> Enum.map(builder)
  end

  defp live_subscription_since do
    overlap =
      case Pleroma.Config.get([Nostr, :live_subscription_overlap_seconds], 300) do
        value when is_integer(value) and value >= 30 and value <= 86_400 -> value
        _ -> 300
      end

    max(System.system_time(:second) - overlap, 0)
  end

  defp local_response_subscription_since do
    overlap =
      case Pleroma.Config.get(
             [Nostr, :local_response_subscription_overlap_seconds],
             @local_response_subscription_overlap_seconds
           ) do
        value when is_integer(value) and value >= 300 and value <= 2_592_000 -> value
        _ -> @local_response_subscription_overlap_seconds
      end

    max(System.system_time(:second) - overlap, 0)
  end

  defp normalize_translation_result(:ok), do: :ok
  defp normalize_translation_result({:ok, _value}), do: :ok
  defp normalize_translation_result({:ok, _one, _two}), do: :ok
  defp normalize_translation_result({:ok, _one, _two, _three}), do: :ok
  defp normalize_translation_result({:error, reason}), do: {:error, "error", inspect(reason)}
  defp normalize_translation_result(_result), do: :ok

  defp map_translation_activity({:ok, %Activity{} = activity}, stored) do
    Store.map_activity(stored.id, activity.id, nil)
  end

  defp map_translation_activity({:ok, :already_liked}, _stored), do: :ok
  defp map_translation_activity(result, _stored), do: normalize_translation_result(result)

  defp error_prefix(reason) when reason in [:duplicate, :already_exists], do: "duplicate"
  defp error_prefix(reason) when reason in [:forbidden, :unauthorized], do: "restricted"
  defp error_prefix(_reason), do: "error"

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)
end

# end of nostr/bridge.ex
