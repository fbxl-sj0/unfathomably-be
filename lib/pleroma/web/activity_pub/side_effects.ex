# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.SideEffects do
  @moduledoc """
  This module looks at an inserted object and executes the side effects that it
  implies. For example, a `Like` activity will increase the like count on the
  liked object, a `Follow` activity will add the user to the follower
  collection, and so on.
  """
  import Ecto.Query, only: [from: 2]

  alias Pleroma.Activity
  alias Pleroma.Chat
  alias Pleroma.Chat.MessageReference
  alias Pleroma.FollowingRelationship
  alias Pleroma.GroupMembership
  alias Pleroma.Notification
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.Push
  alias Pleroma.Web.Streamer
  alias Pleroma.Workers.EventReminderWorker
  alias Pleroma.Workers.PollWorker
  alias Pleroma.Workers.RemoteRepliesFetcherWorker

  require Pleroma.Constants
  require Logger

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @logger Pleroma.Config.get([:side_effects, :logger], Logger)

  @behaviour Pleroma.Web.ActivityPub.SideEffects.Handling

  defp ap_streamer, do: Pleroma.Config.get([:side_effects, :ap_streamer], ActivityPub)

  @impl true
  def handle(object, meta \\ [])

  # Task this handles
  # - Follows
  # - Sends a notification
  @impl true
  def handle(
        %{data: %{"actor" => actor, "type" => "Accept", "object" => activity_id}} = object,
        meta
      ) do
    with %Activity{} = activity <-
           Activity.get_by_ap_id(activity_id) do
      handle_accepted(activity, actor)

      if activity.data["type"] === "Join" do
        Notification.create_notifications(object)
      end
    end

    {:ok, object, meta}
  end

  # Task this handles
  # - Rejects all existing follow activities for this person
  # - Updates the follow state
  # - Dismisses notification
  @impl true
  def handle(
        %{
          data: %{
            "actor" => actor,
            "type" => "Reject",
            "object" => activity_id
          }
        } = object,
        meta
      ) do
    with %Activity{} = activity <-
           Activity.get_by_ap_id(activity_id) do
      handle_rejected(activity, actor)
    end

    {:ok, object, meta}
  end

  # Tasks this handle
  # - Follows if possible
  # - Sends a notification
  # - Generates accept or reject if appropriate
  @impl true
  def handle(
        %{
          data: %{
            "id" => follow_id,
            "type" => "Follow",
            "object" => followed_user,
            "actor" => following_user
          }
        } = object,
        meta
      ) do
    with %User{} = follower <- User.get_cached_by_ap_id(following_user),
         %User{} = followed <- User.get_cached_by_ap_id(followed_user),
         {_, {:ok, _, _}, _, _} <-
           {:following, User.follow(follower, followed, :follow_pending), follower, followed} do
      if followed.local && !followed.is_locked do
        {:ok, accept_data, _} = Builder.accept(followed, object)
        {:ok, _activity, _} = Pipeline.common_pipeline(accept_data, local: true)
      end
    else
      {:following, {:error, _}, _follower, followed} ->
        {:ok, reject_data, _} = Builder.reject(followed, object)
        {:ok, _activity, _} = Pipeline.common_pipeline(reject_data, local: true)

      _ ->
        nil
    end

    {:ok, notifications} = Notification.create_notifications(object, do_send: false)

    meta =
      meta
      |> add_notifications(notifications)

    updated_object = Activity.get_by_ap_id(follow_id)

    {:ok, updated_object, meta}
  end

  # Tasks this handles:
  # - Unfollow and block
  @impl true
  def handle(
        %{data: %{"type" => "Block", "object" => blocked_user, "actor" => blocking_user}} =
          object,
        meta
      ) do
    unless scoped_block?(object) do
      with %User{} = blocker <- User.get_cached_by_ap_id(blocking_user),
           %User{} = blocked <- User.get_cached_by_ap_id(blocked_user) do
        User.block(blocker, blocked)
      end
    end

    {:ok, object, meta}
  end

  # Tasks this handles:
  # - Update the user
  # - Update a non-user object (Note, Question, etc.)
  #
  # For a local user, we also get a changeset with the full information, so we
  # can update non-federating, non-activitypub settings as well.
  @impl true
  def handle(%{data: %{"type" => "Update", "object" => updated_object}} = object, meta) do
    updated_object_id = updated_object["id"]

    with {_, true} <- {:has_id, is_binary(updated_object_id)},
         %{"type" => type} <- updated_object,
         {_, is_user} <- {:is_user, type in Pleroma.Constants.actor_types()} do
      if is_user do
        handle_update_user(object, meta)
      else
        handle_update_object(object, meta)
      end
    else
      _ ->
        {:ok, object, meta}
    end
  end

  # Tasks this handles:
  # - Add like to object
  # - Set up notification
  @impl true
  def handle(%{data: %{"type" => "Like"}} = object, meta) do
    if activity_already_undone?(object) do
      delete_object(object)
    else
      liked_object = object.data["object"] |> object_ap_id() |> Object.get_by_ap_id()

      if liked_object do
        Utils.add_like_to_object(object, liked_object)
        Notification.create_notifications(object)
      end
    end

    {:ok, object, meta}
  end

  # Tasks this handles
  # - Actually create object
  # - Rollback if we couldn't create it
  # - Increase the user note count
  # - Increase the reply count
  # - Increase replies count
  # - Set up ActivityExpiration
  # - Set up notifications
  # - Index incoming posts for search (if needed)
  @impl true
  def handle(%{data: %{"type" => "Create"}} = activity, meta) do
    with {:ok, object, meta} <- handle_object_creation(meta[:object_data], activity, meta),
         %User{} = user <- User.get_cached_by_ap_id(activity.data["actor"]) do
      {:ok, notifications} = Notification.create_notifications(activity, do_send: false)
      {:ok, _user} = ActivityPub.increase_note_count_if_public(user, object)
      {:ok, _user} = ActivityPub.update_last_status_at_if_public(user, object)

      if in_reply_to = object.data["type"] != "Answer" && object.data["inReplyTo"] do
        Object.increase_replies_count(in_reply_to)
      end

      if quote_url = object.data["quoteUrl"] do
        Object.increase_quotes_count(quote_url)
      end

      reply_depth = (meta[:depth] || 0) + 1

      # Remote reply prefetching follows the explicit replies collection when a
      # server provides it. The depth guard keeps hostile or huge trees bounded.
      if Pleroma.Web.Federator.allowed_thread_distance?(reply_depth) and
           object.data["replies"] != nil do
        for reply_id <- object.data["replies"] do
          Pleroma.Workers.RemoteFetcherWorker.enqueue("fetch_remote", %{
            "id" => reply_id,
            "depth" => reply_depth,
            "thread" => true
          })
        end
      end

      if not activity.local do
        current_depth = meta[:depth] || 1

        RemoteRepliesFetcherWorker.enqueue_for_object(object, reply_depth)
        RemoteRepliesFetcherWorker.enqueue_for_reply_ancestors(object, current_depth)
      end

      Pleroma.Web.RichMedia.Card.get_by_activity(activity)

      Pleroma.Search.add_to_index(Map.put(activity, :object, object))

      Utils.maybe_handle_group_posts(activity)

      meta =
        meta
        |> add_notifications(notifications)

      # ChatMessages are special, as they get streamed in handle_object_creation/3.
      # Other Create activities stream here so clients see Articles, Events,
      # Questions, and future object types without needing a release for each one.
      if object.data["type"] != "ChatMessage" do
        ap_streamer().stream_out(activity)
      end

      {:ok, activity, meta}
    else
      e -> Repo.rollback(e)
    end
  end

  # Tasks this handles:
  # - Add announce to object
  # - Set up notification
  # - Stream out the announce
  @impl true
  def handle(%{data: %{"type" => "Announce"}} = object, meta) do
    announced_object = object.data["object"] |> object_ap_id() |> Object.get_by_ap_id()
    user = User.get_cached_by_ap_id(object.data["actor"])

    cond do
      announced_object && group_actor?(user) ->
        ensure_announce_counters(announced_object)

      announced_object ->
        Utils.add_announce_to_object(object, announced_object)

      true ->
        nil
    end

    if announced_object && !User.is_internal_user?(user) && !group_actor?(user) do
      Notification.create_notifications(object)

      ap_streamer().stream_out(object)
    else
      if announced_object && group_actor?(user) do
        ap_streamer().stream_out(object)
      end
    end

    {:ok, object, meta}
  end

  @impl true
  def handle(%{data: %{"type" => "Undo", "object" => undone_object}} = object, meta) do
    with undone_object_id when is_binary(undone_object_id) <- object_ap_id(undone_object),
         %Activity{} = undone_object <- Activity.get_by_ap_id(undone_object_id),
         :ok <- handle_undoing(undone_object) do
      {:ok, object, meta}
    else
      _ -> {:ok, object, meta}
    end
  end

  # Tasks this handles:
  # - Add reaction to object
  # - Set up notification
  @impl true
  def handle(%{data: %{"type" => "EmojiReact"}} = object, meta) do
    reacted_object = object.data["object"] |> object_ap_id() |> Object.get_by_ap_id()

    if reacted_object do
      Utils.add_emoji_reaction_to_object(object, reacted_object)
      Notification.create_notifications(object)
    end

    {:ok, object, meta}
  end

  # Tasks this handles:
  # - Delete and unpins the create activity
  # - Replace object with Tombstone
  # - Reduce the user note count
  # - Reduce the reply count
  # - Stream out the activity
  # - Removes posts from search index (if needed)
  @impl true
  def handle(%{data: %{"type" => "Delete", "object" => %{"type" => "Tombstone"}}} = object, meta) do
    {:ok, object, meta}
  end

  @impl true
  def handle(%{data: %{"type" => "Delete", "object" => deleted_object}} = object, meta) do
    deleted_object =
      Object.normalize(deleted_object, fetch: false) ||
        User.get_cached_by_ap_id(deleted_object)

    result =
      case deleted_object do
        %Object{} ->
          with {:ok, deleted_object, _activity} <- Object.delete(deleted_object),
               {_, actor} when is_binary(actor) <- {:actor, deleted_object.data["actor"]},
               %User{} = user <- User.get_cached_by_ap_id(actor) do
            User.remove_pinned_object_id(user, deleted_object.data["id"])

            {:ok, user} = ActivityPub.decrease_note_count_if_public(user, deleted_object)

            if in_reply_to = deleted_object.data["inReplyTo"] do
              Object.decrease_replies_count(in_reply_to)
            end

            if quote_url = deleted_object.data["quoteUrl"] do
              Object.decrease_quotes_count(quote_url)
            end

            MessageReference.delete_for_object(deleted_object)

            ap_streamer().stream_out(object)
            ap_streamer().stream_out_participations(deleted_object, user)
            :ok
          else
            {:actor, _} ->
              @logger.error("The object doesn't have an actor: #{inspect(deleted_object)}")
              :no_object_actor
          end

        %User{} ->
          with {:ok, _} <- User.delete(deleted_object) do
            :ok
          end

        nil ->
          handle_missing_delete_target(meta)
      end

    if result == :ok do
      # Only remove from index when deleting actual objects, not users or anything else
      with %Pleroma.Object{} <- deleted_object do
        Pleroma.Search.remove_from_index(deleted_object)
      end

      {:ok, object, meta}
    else
      {:error, result}
    end
  end

  # Tasks this handles:
  # - adds pin to user
  # - removes expiration job for pinned activity, if was set for expiration
  @impl true
  def handle(%{data: %{"type" => "Add"} = data} = object, meta) do
    with {:ok, _user} <- add_collection_object(data) do
      # if pinned activity was scheduled for deletion, we remove job
      if expiration = Pleroma.Workers.PurgeExpiredActivity.get_expiration(meta[:activity_id]) do
        Oban.cancel_job(expiration.id)
      end

      {:ok, object, meta}
    else
      {:ignore, _reason} ->
        {:ok, object, meta}

      {:error, changeset} ->
        if changeset.errors[:pinned_objects] do
          {:error, :pinned_statuses_limit_reached}
        else
          changeset.errors
        end
    end
  end

  # Tasks this handles:
  # - removes pin from user
  # - removes corresponding Add activity
  # - if activity had expiration, recreates activity expiration job
  @impl true
  def handle(%{data: %{"type" => "Remove"} = data} = object, meta) do
    with {:ok, user} <- remove_collection_object(data) do
      data["object"]
      |> Activity.add_by_params_query(user.ap_id, user.featured_address)
      |> Repo.delete_all()

      # if pinned activity was scheduled for deletion, we reschedule it for deletion
      if meta[:expires_at] do
        # MRF.ActivityExpirationPolicy used UTC timestamps for expires_at in original implementation
        {:ok, expires_at} =
          Pleroma.EctoType.ActivityPub.ObjectValidators.DateTime.cast(meta[:expires_at])

        Pleroma.Workers.PurgeExpiredActivity.enqueue(%{
          activity_id: meta[:activity_id],
          expires_at: expires_at
        })
      end

      {:ok, object, meta}
    else
      {:ignore, _reason} -> {:ok, object, meta}
      error -> error
    end
  end

  @impl true
  def handle(%{data: %{"type" => "Lock"} = data} = object, meta) do
    case set_comments_enabled(data, false) do
      :ok -> {:ok, object, meta}
      {:ignore, _reason} -> {:ok, object, meta}
      error -> error
    end
  end

  # Tasks this handles:
  # - accepts join if event is local and public
  @impl true
  def handle(%{data: %{"type" => "Join"}} = object, meta) do
    case Object.get_by_ap_id(object.data["object"]) do
      %Object{} = joined_event ->
        if Object.local?(joined_event) and
             (joined_event.data["joinMode"] == "free" or
                object.data["actor"] == joined_event.data["actor"]) do
          {:ok, accept_data, _} = Builder.accept(joined_event, object)
          {:ok, _activity, _} = Pipeline.common_pipeline(accept_data, local: true)
        end

        if Object.local?(joined_event) and joined_event.data["joinMode"] != "free" and
             object.data["actor"] != joined_event.data["actor"] do
          Utils.update_participation_request_count_in_object(joined_event)
        end

      _ ->
        :ok
    end

    Notification.create_notifications(object)

    {:ok, object, meta}
  end

  @impl true
  def handle(%{actor: actor_id, data: %{"type" => "Leave", "object" => event_id}} = object, meta) do
    with undone_object <- Utils.get_existing_join(actor_id, event_id),
         :ok <- handle_undoing(undone_object) do
      case Object.get_by_ap_id(event_id) do
        %Object{} = event ->
          if Object.local?(event) and event.data["joinMode"] != "free" do
            Utils.update_participation_request_count_in_object(event)
          end

        _ ->
          :ok
      end

      {:ok, object, meta}
    end
  end

  # Nothing to do
  @impl true
  def handle(object, meta) do
    {:ok, object, meta}
  end

  defp ensure_announce_counters(%Object{data: data} = object) do
    announcements =
      case data["announcements"] do
        announcements when is_list(announcements) -> announcements
        _ -> []
      end

    count = length(announcements)

    if data["announcement_count"] == count do
      {:ok, object}
    else
      Utils.update_element_in_object("announcement", announcements, object, count)
    end
  end

  defp handle_missing_delete_target(meta) do
    case Keyword.get(meta, :delete_target) do
      %{state: :remote_tombstone} ->
        :ok

      %{state: :pruned_object_with_create, create_activity: %Activity{} = create_activity} ->
        with {:ok, _activity} <- Repo.delete(create_activity) do
          :ok
        end

      _ ->
        :missing_delete_target
    end
  end

  defp add_collection_object(data) do
    with %User{} = actor <- User.get_cached_by_ap_id(data["actor"]) do
      case collection_target(data["target"], actor) do
        {:featured, %User{} = group} ->
          if collection_actor_allowed?(actor, group) do
            User.add_pinned_object_id(group, collection_object_id(data["object"]))
          else
            {:ignore, :unauthorized_group_collection_actor}
          end

        {:moderators, %User{} = group} ->
          if collection_actor_allowed?(actor, group) do
            add_group_moderator(group, actor, data["object"])
          else
            {:ignore, :unauthorized_group_collection_actor}
          end

        :unsupported ->
          {:ignore, :unsupported_collection}
      end
    else
      nil -> {:error, :user_not_found}
    end
  end

  defp remove_collection_object(data) do
    with %User{} = actor <- User.get_cached_by_ap_id(data["actor"]) do
      case collection_target(data["target"], actor) do
        {:featured, %User{} = group} ->
          if collection_actor_allowed?(actor, group) do
            User.remove_pinned_object_id(group, collection_object_id(data["object"]))
          else
            {:ignore, :unauthorized_group_collection_actor}
          end

        {:moderators, %User{} = group} ->
          if collection_actor_allowed?(actor, group) do
            remove_group_moderator(group, actor, data["object"])
          else
            {:ignore, :unauthorized_group_collection_actor}
          end

        :unsupported ->
          {:ignore, :unsupported_collection}
      end
    else
      nil -> {:error, :user_not_found}
    end
  end

  defp collection_target(target, %User{} = actor) do
    cond do
      target == actor.featured_address ->
        {:featured, actor}

      group = featured_collection_owner(target) ->
        {:featured, group}

      group = moderator_collection_owner(target) ->
        {:moderators, group}

      true ->
        :unsupported
    end
  end

  defp featured_collection_owner(target) when is_binary(target) do
    Repo.one(from(user in User, where: user.featured_address == ^target, limit: 1))
  end

  defp featured_collection_owner(_), do: nil

  defp moderator_collection_owner(target) when is_binary(target) do
    Repo.one(from(user in User, where: user.attributed_to_address == ^target, limit: 1))
  end

  defp moderator_collection_owner(_), do: nil

  defp add_group_moderator(%User{local: false}, _actor, _object) do
    {:ignore, :remote_moderator_collection}
  end

  defp add_group_moderator(%User{} = group, %User{} = actor, object) do
    with %User{} = account <- collection_object_user(object),
         {:ok, _memberships} <- GroupMembership.promote(actor, group, [account], "moderator") do
      {:ok, group}
    else
      nil -> {:ignore, :missing_moderator_actor}
      {:error, reason} -> {:ignore, reason}
    end
  end

  defp remove_group_moderator(%User{local: false}, _actor, _object) do
    {:ignore, :remote_moderator_collection}
  end

  defp remove_group_moderator(%User{} = group, %User{} = actor, object) do
    with %User{} = account <- collection_object_user(object),
         {:ok, _memberships} <- GroupMembership.demote(actor, group, [account], "user") do
      {:ok, group}
    else
      nil -> {:ignore, :missing_moderator_actor}
      {:error, reason} -> {:ignore, reason}
    end
  end

  defp collection_object_user(object) do
    object
    |> collection_object_id()
    |> User.get_cached_by_ap_id()
  end

  defp collection_actor_allowed?(
         %User{} = actor,
         %User{
           actor_type: "Group",
           local: true
         } = collection_owner
       ) do
    actor.ap_id == collection_owner.ap_id || GroupMembership.manager?(actor, collection_owner)
  end

  defp collection_actor_allowed?(%User{} = actor, %User{} = collection_owner) do
    actor.ap_id == collection_owner.ap_id ||
      same_origin?(actor.ap_id, collection_owner.ap_id)
  end

  defp collection_actor_allowed?(_, _), do: false

  defp group_actor?(%User{actor_type: "Group"}), do: true
  defp group_actor?(_), do: false

  defp collection_object_id(%{"id" => id}) when is_binary(id), do: id
  defp collection_object_id(object_id), do: object_id

  defp set_comments_enabled(data, enabled) do
    with object_id when is_binary(object_id) <- collection_object_id(data["object"]),
         %Object{} = target <- Object.get_by_ap_id(object_id),
         %User{} = actor <- User.get_cached_by_ap_id(data["actor"]),
         true <- lock_actor_allowed?(actor, target),
         {:ok, _object} <- Object.update_data(target, %{"commentsEnabled" => enabled}) do
      :ok
    else
      nil -> {:ignore, :missing_lock_target}
      false -> {:ignore, :unauthorized_lock_actor}
      error -> error
    end
  end

  defp lock_actor_allowed?(%User{} = actor, %Object{} = target) do
    actor.ap_id == target.data["actor"] ||
      same_origin?(actor.ap_id, target.data["actor"]) ||
      Enum.any?(object_group_candidates(target), fn group_ap_id ->
        actor.ap_id == group_ap_id || same_origin?(actor.ap_id, group_ap_id)
      end)
  end

  defp object_group_candidates(%Object{data: data}) do
    ["audience", "to", "cc"]
    |> Enum.flat_map(&data_ap_ids(Map.get(data, &1)))
    |> Enum.uniq()
  end

  defp data_ap_ids(values) when is_list(values), do: Enum.flat_map(values, &data_ap_ids/1)
  defp data_ap_ids(value) when is_binary(value), do: [value]
  defp data_ap_ids(_), do: []

  defp same_origin?(left, right) when is_binary(left) and is_binary(right) do
    case {URI.parse(left), URI.parse(right)} do
      {%URI{host: left_host}, %URI{host: right_host}}
      when is_binary(left_host) and is_binary(right_host) ->
        String.downcase(left_host) == String.downcase(right_host)

      _ ->
        false
    end
  rescue
    URI.Error -> false
  end

  defp same_origin?(_, _), do: false

  defp handle_accepted(
         %Activity{actor: follower_id, data: %{"type" => "Follow"}} = follow_activity,
         actor
       ) do
    with %User{} = followed <- User.get_cached_by_ap_id(actor),
         %User{} = follower <- User.get_cached_by_ap_id(follower_id),
         {:ok, follow_activity} <- Utils.update_follow_state_for_all(follow_activity, "accept"),
         {:ok, _follower, followed} <-
           FollowingRelationship.update(follower, followed, :follow_accept) do
      Notification.update_notification_type(followed, follow_activity)
    end
  end

  defp handle_accepted(
         %Activity{data: %{"type" => "Join", "object" => event_id}} = join_activity,
         actor
       ) do
    with %Object{data: %{"actor" => ^actor}} = joined_event <- Object.get_by_ap_id(event_id),
         {:ok, join_activity} <- Utils.update_join_state(join_activity, "accept") do
      Utils.add_participation_to_object(join_activity, joined_event)
    end
  end

  defp handle_rejected(
         %Activity{actor: follower_id, data: %{"type" => "Follow"}} = follow_activity,
         actor
       ) do
    with %User{} = followed <- User.get_cached_by_ap_id(actor),
         %User{} = follower <- User.get_cached_by_ap_id(follower_id),
         {:ok, _follow_activity} <- Utils.update_follow_state_for_all(follow_activity, "reject") do
      FollowingRelationship.update(follower, followed, :follow_reject)
      Notification.dismiss(follow_activity)
    end
  end

  defp handle_rejected(
         %Activity{data: %{"type" => "Join", "object" => event_id}} = join_activity,
         actor
       ) do
    with %Object{data: %{"actor" => ^actor}} = joined_event <- Object.get_by_ap_id(event_id),
         {:ok, join_activity} <- Utils.update_join_state(join_activity, "reject") do
      Utils.remove_participation_from_object(join_activity, joined_event)
      Notification.dismiss(join_activity)
    end
  end

  defp handle_update_user(
         %{data: %{"type" => "Update", "object" => updated_object}} = object,
         meta
       ) do
    if changeset = Keyword.get(meta, :user_update_changeset) do
      changeset
      |> User.update_and_set_cache()
    else
      {:ok, new_user_data} = ActivityPub.user_data_from_user_object(updated_object)

      User.get_by_ap_id(updated_object["id"])
      |> User.remote_user_changeset(new_user_data)
      |> User.update_and_set_cache()
    end

    {:ok, object, meta}
  end

  defp handle_update_object(
         %{data: %{"type" => "Update", "object" => updated_object}} = object,
         meta
       ) do
    orig_object_ap_id = updated_object["id"]
    orig_object = Object.get_by_ap_id(orig_object_ap_id)
    orig_object_data = orig_object.data

    updated_object =
      if meta[:local] do
        # If this is a local Update, we don't process it by transmogrifier,
        # so we use the embedded object as-is.
        updated_object
      else
        meta[:object_data]
      end

    if orig_object_data["type"] in Pleroma.Constants.updatable_object_types() do
      {:ok, _, updated} =
        Object.Updater.do_update_and_invalidate_cache(orig_object, updated_object)

      if updated do
        object
        |> Activity.normalize()
        |> ActivityPub.notify_and_stream()
      end
    end

    {:ok, object, meta}
  end

  def handle_object_creation(%{"type" => "ChatMessage"} = object, _activity, meta) do
    with {:ok, object, meta} <- Pipeline.common_pipeline(object, meta) do
      streamables = chat_message_streamables(object, meta)

      meta =
        meta
        |> add_streamables(streamables)

      {:ok, object, meta}
    end
  end

  def handle_object_creation(%{"type" => "Question"} = object, activity, meta) do
    with {:ok, object, meta} <- Pipeline.common_pipeline(object, meta) do
      PollWorker.schedule_poll_end(activity)
      {:ok, object, meta}
    end
  end

  def handle_object_creation(%{"type" => "Answer"} = object_map, _activity, meta) do
    with {:ok, object, meta} <- Pipeline.common_pipeline(object_map, meta) do
      Object.increase_vote_count(
        object.data["inReplyTo"],
        object.data["name"],
        object.data["actor"]
      )

      {:ok, object, meta}
    end
  end

  def handle_object_creation(%{"type" => "Event"} = object, activity, meta) do
    with {:ok, object, meta} <- Pipeline.common_pipeline(object, meta) do
      EventReminderWorker.schedule_event_reminder(activity)
      {:ok, object, meta}
    end
  end

  def handle_object_creation(%{"type" => objtype} = object, _activity, meta)
      when objtype in ~w[Audio Video Image Article Note Page] do
    meta = Keyword.put(meta, :preserve_internal_replies_collection, true)

    with {:ok, object, meta} <- Pipeline.common_pipeline(object, meta) do
      {:ok, object, meta}
    end
  end

  # Nothing to do
  def handle_object_creation(object, _activity, meta) do
    {:ok, object, meta}
  end

  defp chat_message_streamables(object, meta) do
    with %User{} = actor <- User.get_cached_by_ap_id(object.data["actor"]),
         %User{} = recipient <-
           object.data["to"] |> chat_message_recipient_id() |> User.get_cached_by_ap_id() do
      [[actor, recipient], [recipient, actor]]
      |> Enum.uniq()
      |> Enum.map(fn [user, other_user] ->
        if user.local do
          {:ok, chat} = Chat.bump_or_create(user.id, other_user.ap_id)
          {:ok, cm_ref} = MessageReference.create(chat, object, user.ap_id != actor.ap_id)

          @cachex.put(
            :chat_message_id_idempotency_key_cache,
            cm_ref.id,
            meta[:idempotency_key]
          )

          {
            ["user", "user:pleroma_chat"],
            {user, %{cm_ref | chat: chat, object: object}}
          }
        end
      end)
      |> Enum.filter(& &1)
    else
      _ -> []
    end
  end

  defp chat_message_recipient_id([recipient | _]) when is_binary(recipient), do: recipient
  defp chat_message_recipient_id(_), do: nil

  defp undo_like(nil, object), do: delete_object(object)

  defp undo_like(%Object{} = liked_object, object) do
    with {:ok, _} <- Utils.remove_like_from_object(object, liked_object) do
      delete_object(object)
    end
  end

  def handle_undoing(%{data: %{"type" => "Like"}} = object) do
    object.data["object"]
    |> object_ap_id()
    |> Object.get_by_ap_id()
    |> undo_like(object)
  end

  def handle_undoing(%{data: %{"type" => "EmojiReact"}} = object) do
    with object_ap_id when is_binary(object_ap_id) <- object_ap_id(object.data["object"]),
         %Object{} = reacted_object <- Object.get_by_ap_id(object_ap_id),
         {:ok, _} <- Utils.remove_emoji_reaction_from_object(object, reacted_object),
         {:ok, _} <- Repo.delete(object) do
      :ok
    end
  end

  def handle_undoing(%{data: %{"type" => "Announce"}} = object) do
    with object_ap_id when is_binary(object_ap_id) <- object_ap_id(object.data["object"]),
         %Object{} = liked_object <- Object.get_by_ap_id(object_ap_id),
         {:ok, _} <- Utils.remove_announce_from_object(object, liked_object),
         {:ok, _} <- Repo.delete(object) do
      :ok
    end
  end

  def handle_undoing(%{data: %{"type" => "Lock"} = data} = object) do
    with :ok <- set_comments_enabled(data, true),
         {:ok, _} <- Repo.delete(object) do
      :ok
    end
  end

  def handle_undoing(
        %{data: %{"type" => "Block", "actor" => blocker, "object" => blocked}} = object
      ) do
    if scoped_block?(object) do
      delete_object(object)
    else
      undo_user_block(object, blocker, blocked)
    end
  end

  def handle_undoing(
        %{data: %{"type" => "Join", "actor" => _actor_id, "object" => event_id}} = object
      ) do
    with %Object{} = event_object <- Object.get_by_ap_id(event_id),
         {:ok, _} <- Utils.remove_participation_from_object(object, event_object),
         {:ok, _} <- Repo.delete(object) do
      :ok
    end
  end

  def handle_undoing(object), do: {:error, ["don't know how to handle", object]}

  defp scoped_block?(%{data: %{"target" => target}}) when is_binary(target), do: target != ""
  defp scoped_block?(_), do: false

  defp undo_user_block(object, blocker, blocked) do
    with %User{} = blocker <- User.get_cached_by_ap_id(blocker),
         %User{} = blocked <- User.get_cached_by_ap_id(blocked),
         {:ok, _} <- User.unblock(blocker, blocked),
         {:ok, _} <- Repo.delete(object) do
      :ok
    end
  end

  defp object_ap_id(ap_id) when is_binary(ap_id), do: ap_id
  defp object_ap_id(%{"id" => ap_id}) when is_binary(ap_id), do: ap_id
  defp object_ap_id(_), do: nil

  @spec delete_object(Object.t()) :: :ok | {:error, Ecto.Changeset.t()}
  defp delete_object(object) do
    with {:ok, _} <- Repo.delete(object), do: :ok
  end

  defp activity_already_undone?(%{data: %{"id" => activity_id}}) when is_binary(activity_id) do
    "Undo"
    |> Activity.Queries.by_type()
    |> Activity.Queries.by_object_id(activity_id)
    |> Repo.exists?()
  end

  defp activity_already_undone?(_), do: false

  defp send_notifications(meta) do
    Keyword.get(meta, :notifications, [])
    |> Enum.each(fn notification ->
      Streamer.stream(["user", "user:notification"], notification)
      Push.send(notification)
    end)

    meta
  end

  defp send_streamables(meta) do
    Keyword.get(meta, :streamables, [])
    |> Enum.each(fn {topics, items} ->
      Streamer.stream(topics, items)
    end)

    meta
  end

  defp add_streamables(meta, streamables) do
    existing = Keyword.get(meta, :streamables, [])

    meta
    |> Keyword.put(:streamables, streamables ++ existing)
  end

  defp add_notifications(meta, notifications) do
    existing = Keyword.get(meta, :notifications, [])

    meta
    |> Keyword.put(:notifications, notifications ++ existing)
  end

  @impl true
  def handle_after_transaction(meta) do
    meta
    |> send_notifications()
    |> send_streamables()
  end
end
