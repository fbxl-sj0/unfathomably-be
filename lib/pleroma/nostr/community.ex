# Unfathomably BE
# ----------------
#
# File: nostr/community.ex
#
# Purpose:
#   Map NIP-29 relay groups onto Unfathomably's existing group policy model.
#
# Responsibilities:
#   - publish local Group metadata under the local relay key
#   - join and leave remote NIP-29 groups through existing group endpoints
#   - authorize local relay posts and moderation events
#   - synchronize join, leave, member, and metadata events in both directions
#
# This file intentionally does NOT define a second group database, replace
# ActivityPub moderation, or host private LiveKit rooms.

defmodule Pleroma.Nostr.Community do
  import Ecto.Query

  alias Pleroma.FollowingRelationship
  alias Pleroma.GroupMembership
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Workers.NostrGroupMemberSyncWorker

  @metadata_kinds 39_000..39_005

  def reconcile_local_groups do
    if Nostr.bridge_enabled?() do
      User
      |> where([group], group.local == true)
      |> where([group], group.actor_type == "Group")
      |> where([group], group.is_active == true)
      |> Repo.all()
      |> Enum.each(fn group ->
        case Identity.get_by_user(group) do
          %Entity{kind: "mirror_group"} -> :ok
          _entity -> publish_metadata(group)
        end
      end)
    end

    :ok
  end

  def join(%User{} = user, %User{} = group) do
    with %Entity{kind: "mirror_group"} = entity <- Identity.get_by_user(group),
         {:ok, user, _group} <- User.follow(user, group, :follow_accept),
         :ok <- maybe_publish_join(user, entity) do
      if get_in(entity.metadata || %{}, ["community_standard"]) != "nip72" do
        NostrGroupMemberSyncWorker.enqueue(group)
      end

      {:ok, group}
    else
      _ -> {:error, :could_not_join}
    end
  end

  def leave(%User{} = user, %User{} = group) do
    with %Entity{kind: "mirror_group"} = entity <- Identity.get_by_user(group),
         {:ok, follower, _follow_activity} <- User.unfollow(user, group),
         :ok <- maybe_publish_leave(user, entity) do
      {:ok, follower}
    else
      _ -> {:error, :could_not_leave}
    end
  end

  defp maybe_publish_join(_user, %Entity{metadata: %{"community_standard" => "nip72"}}),
    do: :ok

  defp maybe_publish_join(user, %Entity{relay_url: relay_url, group_id: group_id}) do
    Bridge.publish_actor_event(user, 9_021, [["h", group_id]], "", [relay_url])
  end

  defp maybe_publish_leave(_user, %Entity{metadata: %{"community_standard" => "nip72"}}),
    do: :ok

  defp maybe_publish_leave(user, %Entity{relay_url: relay_url, group_id: group_id}) do
    Bridge.publish_actor_event(user, 9_022, [["h", group_id]], "", [relay_url])
  end

  def publish_metadata(%User{local: true, actor_type: "Group"} = group) do
    if Nostr.bridge_enabled?() do
      with {:ok, entity} <- Identity.local_group(group) do
        tags =
          [
            ["d", entity.group_id],
            ["name", group.name || entity.group_id],
            ["about", group.bio || ""],
            ["supported_kinds", "1", "9", "11", "1111", "30023"]
          ]
          |> maybe_add_tag("picture", image_url(group.avatar))
          |> maybe_add_tag("banner", image_url(group.banner))
          |> maybe_add_restricted(group)

        Bridge.publish_relay_event(39_000, tags, "")
        publish_admins(group, entity)
      end
    end

    :ok
  end

  def publish_metadata(_group), do: :ok

  def publish_delete(%User{local: true, actor_type: "Group"} = group, actor) do
    if Nostr.bridge_enabled?() do
      with {:ok, entity} <- Identity.local_group(group) do
        Bridge.publish_actor_event(
          actor,
          9_008,
          [["h", entity.group_id]],
          "Group deleted",
          [entity.relay_url]
        )
      end
    end

    :ok
  end

  def publish_delete(_group, _actor), do: :ok

  @profile_backfill_kinds [0, 1, 6, 9, 11, 1_111, 10_002, 10_011, 30_023]
  @thread_hydration_kinds [1, 9, 11, 1_111, 30_023]
  @local_response_kinds [
    1,
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
  @max_thread_hydration_targets 80

  def authorize(
        %{"kind" => kind, "pubkey" => event_pubkey},
        _relay_url,
        {:profile_backfill, expected_pubkey}
      )
      when kind in @profile_backfill_kinds and event_pubkey == expected_pubkey,
      do: :ok

  def authorize(_event, _relay_url, {:profile_backfill, _expected_pubkey}),
    do: {:error, "restricted", "event does not match the requested profile backfill"}

  def authorize(%{"kind" => 0} = event, _relay_url, {:nip50_search, filters})
      when is_list(filters) do
    if Enum.any?(filters, &Protocol.matches?(event, &1)) do
      :ok
    else
      {:error, "restricted", "profile does not match the NIP-50 search"}
    end
  end

  def authorize(_event, _relay_url, {:nip50_search, _filters}),
    do: {:error, "restricted", "event is not a NIP-50 profile result"}

  # A status-context request may need an ancestor or direct reply written by
  # an identity that the local user does not otherwise follow. The signed
  # event reference supplies an exact identifier, so this source permits only
  # the bounded identifiers selected by the thread worker. It does not admit
  # author history or unrelated relay traffic.
  def authorize(
        %{"id" => event_id, "kind" => kind} = event,
        relay_url,
        {:thread_hydration, target_ids}
      )
      when is_binary(event_id) and kind in @thread_hydration_kinds and is_list(target_ids) do
    cond do
      length(target_ids) > @max_thread_hydration_targets ->
        {:error, "restricted", "thread hydration target set is too large"}

      event_id not in target_ids ->
        {:error, "restricted", "event is outside the requested thread neighborhood"}

      is_binary(Protocol.tag_value(event, "h")) ->
        authorize_group_event(event, relay_url, :relay)

      true ->
        :ok
    end
  end

  def authorize(_event, _relay_url, {:thread_hydration, _target_ids}),
    do: {:error, "restricted", "event is outside the requested thread neighborhood"}

  def authorize(event, relay_url, source) do
    cond do
      event["kind"] in @metadata_kinds ->
        authorize_metadata(event, relay_url, source)

      is_binary(Protocol.tag_value(event, "h")) ->
        authorize_group_event(event, relay_url, source)

      source == :relay and addressed_to_local_actor?(event) ->
        :ok

      source == :relay and response_to_local_event?(event) ->
        :ok

      source == :relay and known_profile?(event["pubkey"], relay_url) ->
        :ok

      source == :client and local_actor_pubkey?(event["pubkey"]) ->
        :ok

      true ->
        {:error, "restricted", "writer is not known to this relay"}
    end
  end

  def handle_metadata(%{"kind" => 39_000} = event, relay_url) do
    Identity.update_group(event, relay_url)
    |> case do
      {:ok, _group} -> :ok
      _ -> :ok
    end
  end

  def handle_metadata(%{"kind" => kind} = event, relay_url)
      when kind in [39_001, 39_002, 39_003] do
    case Identity.update_group_directory(event, relay_url) do
      {:ok, group} ->
        if kind in [39_001, 39_002], do: NostrGroupMemberSyncWorker.enqueue(group)
        :ok

      _ ->
        :ok
    end
  end

  def handle_metadata(_event, _relay_url), do: :ok

  def handle_management(event, relay_url) do
    case event["kind"] do
      9_021 -> handle_join_request(event, relay_url)
      9_022 -> handle_leave_request(event, relay_url)
      9_000 -> handle_put_user(event, relay_url)
      9_001 -> handle_remove_user(event, relay_url)
      9_002 -> handle_edit_metadata(event, relay_url)
      9_005 -> handle_delete_event(event, relay_url)
      _ -> :ok
    end
  end

  def group_for_event(event, relay_url) do
    group_reference =
      Protocol.tag_value(event, "h") ||
        Enum.find(
          Protocol.tag_values(event, "A") ++ Protocol.tag_values(event, "a"),
          &String.starts_with?(&1, "34550:")
        )

    case group_reference do
      group_id when is_binary(group_id) ->
        case Identity.get_group(relay_url, group_id) do
          %Entity{user: %User{} = group} -> group
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp authorize_metadata(event, relay_url, :relay) do
    group_id = Protocol.tag_value(event, "d")
    event_pubkey = event["pubkey"]

    if is_binary(group_id) and group_id != "" do
      case Identity.get_group(relay_url, group_id) do
        %Entity{kind: "mirror_group", pubkey: ^event_pubkey} ->
          :ok

        _ ->
          {:error, "restricted", "group metadata is not signed by the expected relay key"}
      end
    else
      {:error, "error", "group metadata is missing its d tag"}
    end
  end

  defp authorize_metadata(event, relay_url, :client) do
    with true <- relay_url == Nostr.relay_url(),
         {:ok, relay_pubkey} <- Pleroma.Nostr.Keys.public_key("relay"),
         true <- event["pubkey"] == relay_pubkey do
      :ok
    else
      _ -> {:error, "restricted", "only the relay key may publish group metadata"}
    end
  end

  defp authorize_group_event(event, relay_url, :relay) do
    case group_for_event(event, relay_url) do
      %User{} -> :ok
      nil -> {:error, "restricted", "group is not mapped on this relay"}
    end
  end

  defp authorize_group_event(event, relay_url, :client) do
    with true <- relay_url == Nostr.relay_url(),
         %User{local: true} = group <- group_for_event(event, relay_url) do
      authorize_local_group_writer(event, group, relay_url)
    else
      _ -> {:error, "restricted", "group is not hosted by this relay"}
    end
  end

  defp authorize_local_group_writer(%{"kind" => 9_021}, _group, _relay_url), do: :ok

  defp authorize_local_group_writer(event, group, relay_url) do
    with {:ok, account} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}) do
      relationship = GroupMembership.relationship(account, group)

      cond do
        event["kind"] == 9_022 and relationship.member ->
          :ok

        event["kind"] in 9_000..9_020 and GroupMembership.manager?(account, group) ->
          :ok

        not relationship.member ->
          {:error, "restricted", "join the group before posting"}

        group.posting_restricted_to_mods and not GroupMembership.manager?(account, group) ->
          {:error, "restricted", "only group moderators may post"}

        true ->
          :ok
      end
    else
      _ -> {:error, "restricted", "could not map the event author"}
    end
  end

  defp handle_join_request(event, relay_url) do
    case Identity.get_group(relay_url, Protocol.tag_value(event, "h")) do
      %Entity{kind: "local_group", user: %User{} = group} = entity ->
        handle_local_join_request(event, relay_url, group, entity)

      %Entity{kind: "mirror_group"} ->
        :ok

      _ ->
        {:error, "restricted", "join request references an unknown group"}
    end
  end

  defp handle_local_join_request(event, relay_url, group, entity) do
    with {:ok, account} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         false <- GroupMembership.relationship(account, group).member,
         {:ok, _follower, _followed, _activity} <- GroupMembership.join(account, group),
         true <- GroupMembership.relationship(account, group).member do
      Bridge.publish_relay_event(
        9_000,
        [["h", entity.group_id], ["p", event["pubkey"]]],
        "Member joined"
      )

      :ok
    else
      true -> {:error, "duplicate", "already a group member"}
      false -> {:error, "restricted", "join request is pending approval"}
      _ -> {:error, "restricted", "join request could not be accepted"}
    end
  end

  defp handle_leave_request(event, relay_url) do
    case Identity.get_group(relay_url, Protocol.tag_value(event, "h")) do
      %Entity{kind: "local_group", user: %User{} = group} = entity ->
        handle_local_leave_request(event, relay_url, group, entity)

      %Entity{kind: "mirror_group"} ->
        :ok

      _ ->
        {:error, "error", "leave request references an unknown group"}
    end
  end

  defp handle_local_leave_request(event, relay_url, group, entity) do
    with {:ok, account} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         {:ok, _account} <- GroupMembership.leave(account, group) do
      Bridge.publish_relay_event(
        9_001,
        [["h", entity.group_id], ["p", event["pubkey"]]],
        "Member left"
      )

      :ok
    else
      _ -> {:error, "error", "leave request could not be applied"}
    end
  end

  defp handle_put_user(event, relay_url) do
    with %Entity{kind: "mirror_group", user: %User{} = group} <-
           Identity.get_group(relay_url, Protocol.tag_value(event, "h")),
         pubkey when is_binary(pubkey) <- Protocol.tag_value(event, "p"),
         %Entity{user: %User{} = account} <- Identity.get_profile(pubkey) do
      User.follow(account, group, :follow_accept)
    end

    :ok
  end

  defp handle_remove_user(event, relay_url) do
    with %Entity{kind: "mirror_group", user: %User{} = group} <-
           Identity.get_group(relay_url, Protocol.tag_value(event, "h")),
         pubkey when is_binary(pubkey) <- Protocol.tag_value(event, "p"),
         %Entity{user: %User{} = account} <- Identity.get_profile(pubkey) do
      User.unfollow(account, group)
    end

    :ok
  end

  defp handle_edit_metadata(event, relay_url) do
    with %User{local: true} = group <- group_for_event(event, relay_url),
         {:ok, actor} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         true <- GroupMembership.manager?(actor, group) do
      params = %{
        "display_name" => Protocol.tag_value(event, "name") || group.name,
        "note" => Protocol.tag_value(event, "about") || group.bio,
        "posting_restricted_to_mods" => group.posting_restricted_to_mods
      }

      FederatedTarget.update_local_group(group, actor, params)
    end

    :ok
  end

  defp handle_delete_event(event, relay_url) do
    with %User{local: true} = group <- group_for_event(event, relay_url),
         {:ok, actor} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         true <- GroupMembership.manager?(actor, group) do
      event
      |> Protocol.tag_values("e")
      |> Enum.each(fn event_id ->
        with %Pleroma.Nostr.Event{ap_activity_id: activity_id} <- Store.get(event_id),
             %Pleroma.Activity{} = activity <- Pleroma.Activity.get_by_id(activity_id) do
          CommonAPI.delete(activity.id, actor)
        end
      end)
    end

    :ok
  end

  defp publish_admins(group, entity) do
    tags =
      ["owner", "moderator"]
      |> Enum.flat_map(fn role ->
        group
        |> GroupMembership.members(role)
        |> Enum.flat_map(fn membership ->
          with {:ok, account_entity} <- Identity.local_actor(membership.account) do
            [["p", account_entity.pubkey, role]]
          else
            _ -> []
          end
        end)
      end)

    Bridge.publish_relay_event(39_001, [["d", entity.group_id] | tags], "")
  end

  defp known_profile?(pubkey, relay_url) do
    case Identity.get_profile(pubkey) do
      %Entity{kind: "mirror_profile"} = entity ->
        relay_url in Identity.relay_urls(entity, :read) or
          (relay_url in Nostr.profile_discovery_relays() and
             followed_by_local_account?(entity.user_id))

      %Entity{} = entity ->
        relay_url in Identity.relay_urls(entity, :write)

      _ ->
        false
    end
  end

  defp followed_by_local_account?(user_id) do
    FollowingRelationship
    |> join(:inner, [relationship], follower in User, on: follower.id == relationship.follower_id)
    |> join(:left, [_relationship, follower], follower_entity in Entity,
      on:
        follower_entity.user_id == follower.id and
          follower_entity.kind in ["mirror_profile", "mirror_group"]
    )
    |> where(
      [relationship, follower, follower_entity],
      relationship.following_id == ^user_id and
        relationship.state == ^:follow_accept and
        follower.local and
        is_nil(follower_entity.id)
    )
    |> Repo.exists?()
  end

  defp local_actor_pubkey?(pubkey) do
    case Identity.get_profile(pubkey) do
      %Entity{kind: kind} when kind in ["local_actor", "local_group"] -> true
      _ -> false
    end
  end

  # Response-relay filters subscribe to public events that tag a local actor.
  # Apply the same boundary during authorization so a first-contact reply is
  # accepted even when its author metadata has not reached this server yet.
  defp addressed_to_local_actor?(%{"kind" => kind} = event)
       when kind in @local_response_kinds do
    event
    |> Protocol.tag_values("p")
    |> Enum.any?(&local_actor_pubkey?/1)
  end

  defp addressed_to_local_actor?(_event), do: false

  # Public response subscriptions deliberately include authors that local users
  # do not follow. The signed event must still point at an event exported by
  # this server, which keeps the subscription from becoming a general relay
  # firehose while allowing replies and reactions from new participants.
  defp response_to_local_event?(%{"kind" => kind} = event)
       when kind in @local_response_kinds do
    event
    |> local_response_reference_ids()
    |> Enum.any?(fn event_id ->
      match?(%Pleroma.Nostr.Event{local: true}, Pleroma.Nostr.Store.get(event_id))
    end)
  end

  # Deletions are accepted only for a stored event signed by the same author.
  # This permits an unknown responder to retract their imported response without
  # allowing a remote key to delete one of this server's exported events.
  defp response_to_local_event?(%{"kind" => 5, "pubkey" => pubkey} = event) do
    event
    |> local_response_reference_ids()
    |> Enum.any?(fn event_id ->
      case Pleroma.Nostr.Store.get(event_id) do
        %Pleroma.Nostr.Event{local: false, pubkey: ^pubkey, ap_activity_id: activity_id}
        when is_binary(activity_id) ->
          true

        _ ->
          false
      end
    end)
  end

  defp response_to_local_event?(_event), do: false

  defp local_response_reference_ids(event) do
    (Protocol.tag_values(event, "e") ++ Protocol.tag_values(event, "q"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp maybe_add_tag(tags, _name, nil), do: tags
  defp maybe_add_tag(tags, _name, ""), do: tags
  defp maybe_add_tag(tags, name, value), do: tags ++ [[name, value]]

  defp maybe_add_restricted(tags, _group), do: tags ++ [["restricted"]]

  defp image_url(%{"url" => [%{"href" => href} | _rest]}) when is_binary(href), do: href
  defp image_url(%{"url" => href}) when is_binary(href), do: href
  defp image_url(_image), do: nil

  @doc "Returns true when a NIP-29 group marks native group content as members-only."
  def private_event?(event, relay_url) do
    with %User{} = group <- group_for_event(event, relay_url),
         %Entity{metadata: metadata} when is_map(metadata) <- Identity.get_by_user(group) do
      metadata["private"] == true
    else
      _ -> false
    end
  end
end

# end of nostr/community.ex
