# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.CommonAPI do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Conversation.Participation
  alias Pleroma.FederationStatus
  alias Pleroma.FollowingRelationship
  alias Pleroma.Formatter
  alias Pleroma.GroupMembership
  alias Pleroma.ModerationLog
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Rule
  alias Pleroma.ThreadMute
  alias Pleroma.User
  alias Pleroma.UserRelationship
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Addressing
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.CommonAPI.ActivityDraft
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.Utils.Params

  import Ecto.Query, only: [where: 3]
  import Pleroma.Web.Gettext
  import Pleroma.Web.CommonAPI.Utils

  require Logger
  require Pleroma.Constants

  def block(blocker, blocked) do
    with {:ok, block_data, _} <- Builder.block(blocker, blocked),
         {:ok, block, _} <- Pipeline.common_pipeline(block_data, local: true) do
      {:ok, block}
    end
  end

  def post_chat_message(%User{} = user, %User{} = recipient, content, opts \\ []) do
    with :ok <- ensure_federation_identifier_allowed(user),
         :ok <- ensure_federation_identifier_allowed(recipient),
         :ok <- Pleroma.Nostr.PrivateMessages.validate_outbound(user, recipient, content, opts),
         maybe_attachment <- opts[:media_id] && Object.get_by_id(opts[:media_id]),
         :ok <- validate_chat_attachment_attribution(maybe_attachment, user),
         :ok <- validate_chat_content_length(content, !!maybe_attachment),
         {_, {:ok, chat_message_data, _meta}} <-
           {:build_object,
            Builder.chat_message(
              user,
              recipient.ap_id,
              content |> format_chat_content,
              attachment: maybe_attachment
            )},
         {_, {:ok, create_activity_data, _meta}} <-
           {:build_create_activity, Builder.create(user, chat_message_data, [recipient.ap_id])},
         {_, {:ok, %Activity{} = activity, _meta}} <-
           {:common_pipeline,
            Pipeline.common_pipeline(maybe_mark_nostr_chat(create_activity_data, opts),
              local: Keyword.get(opts, :local, true),
              idempotency_key: opts[:idempotency_key]
            )} do
      case Pleroma.Nostr.Bridge.publish_chat_message(activity, user, recipient, content) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not publish native Nostr chat message", reason: inspect(reason))
      end

      {:ok, activity}
    else
      {:common_pipeline, e} -> e
      e -> e
    end
  end

  defp maybe_mark_nostr_chat(activity_data, opts) do
    if opts[:nostr_ingest] do
      activity_data
      |> Map.put("unfathomably:nostr_ingest", true)
      |> Map.put("unfathomably:nostr_event_id", opts[:nostr_event_id])
      |> maybe_put_chat_published(opts[:published])
    else
      activity_data
    end
  end

  defp maybe_put_chat_published(activity_data, %DateTime{} = published) do
    update_in(activity_data, ["object"], fn
      %{} = object -> Map.put(object, "published", DateTime.to_iso8601(published))
      object -> object
    end)
  end

  defp maybe_put_chat_published(activity_data, _published), do: activity_data

  defp format_chat_content(nil), do: nil

  defp format_chat_content(content) do
    {text, _, _} =
      content
      |> Formatter.html_escape("text/plain")
      |> Formatter.linkify()
      |> (fn {text, mentions, tags} ->
            {String.replace(text, ~r/\r?\n/, "<br>"), mentions, tags}
          end).()

    text
  end

  defp validate_chat_attachment_attribution(nil, _), do: :ok

  defp validate_chat_attachment_attribution(attachment, user) do
    with :ok <- Object.authorize_access(attachment, user) do
      :ok
    else
      e ->
        e
    end
  end

  defp validate_chat_content_length(_, true), do: :ok
  defp validate_chat_content_length(nil, false), do: {:error, :no_content}

  defp validate_chat_content_length(content, _) do
    if String.length(content) <= Pleroma.Config.get([:instance, :chat_limit]) do
      :ok
    else
      {:error, :content_too_long}
    end
  end

  def unblock(blocker, blocked) do
    with {_, %Activity{} = block} <- {:fetch_block, Utils.fetch_latest_block(blocker, blocked)},
         {:ok, unblock_data, _} <- Builder.undo(blocker, block),
         {:ok, unblock, _} <- Pipeline.common_pipeline(unblock_data, local: true) do
      {:ok, unblock}
    else
      {:fetch_block, nil} ->
        if User.blocks?(blocker, blocked) do
          User.unblock(blocker, blocked)
          {:ok, :no_activity}
        else
          {:error, :not_blocking}
        end

      e ->
        e
    end
  end

  def follow(follower, followed) do
    timeout = Pleroma.Config.get([:activitypub, :follow_handshake_timeout])

    with {:ok, follow_data, _} <- Builder.follow(follower, followed),
         {:ok, activity, _} <- Pipeline.common_pipeline(follow_data, local: true),
         {:ok, follower, followed} <- User.wait_and_refresh(timeout, follower, followed),
         {:ok, follower, followed} <- maybe_accept_subscription_source_follow(follower, followed) do
      if activity.data["state"] == "reject" do
        {:error, :rejected}
      else
        {:ok, follower, followed, activity}
      end
    end
  end

  defp maybe_accept_subscription_source_follow(
         %User{} = follower,
         %User{local: false, is_locked: false} = followed
       ) do
    with true <- subscription_source?(followed),
         {:ok, %User{} = source} <- FederatedTarget.resolve_source(followed.ap_id),
         true <- source.id == followed.id,
         {:ok, follower, source} <-
           FollowingRelationship.update(follower, source, :follow_accept) do
      {:ok, follower, source}
    else
      _ -> {:ok, follower, followed}
    end
  end

  defp maybe_accept_subscription_source_follow(%User{} = follower, %User{} = followed) do
    {:ok, follower, followed}
  end

  defp subscription_source?(%User{} = source) do
    family =
      source
      |> FederatedTarget.source_platform()
      |> Map.get(:platform_family)

    family in ["audio", "video", "longform", "photo", "books", "bookmarks", "events"]
  end

  def unfollow(follower, unfollowed) do
    with {:ok, follower, _follow_activity} <- User.unfollow(follower, unfollowed),
         {:ok, _activity} <- maybe_activitypub_unfollow(follower, unfollowed),
         {:ok, _subscription} <- User.unsubscribe(follower, unfollowed),
         {:ok, _endorsement} <- User.unendorse(follower, unfollowed) do
      {:ok, follower}
    end
  end

  defp maybe_activitypub_unfollow(follower, unfollowed) do
    case ActivityPub.unfollow(follower, unfollowed) do
      {:ok, activity} ->
        # ActivityPub.unfollow/2 writes its Undo outside the common pipeline.
        # Nostr mirrors therefore need the same explicit post-commit enqueue
        # that Pipeline.common_pipeline/2 provides to other local activities.
        Pleroma.Nostr.maybe_enqueue_unfollow(activity, follower, unfollowed)
        Pleroma.ATProto.maybe_enqueue_activity(activity, [])
        Pleroma.Diaspora.maybe_enqueue_unfollow(activity, follower, unfollowed)

        {:ok, activity}

      nil ->
        {:ok, nil}

      error ->
        error
    end
  end

  def accept_follow_request(follower, followed) do
    with %Activity{} = follow_activity <- Utils.fetch_latest_follow(follower, followed),
         {:ok, accept_data, _} <- Builder.accept(followed, follow_activity),
         {:ok, _activity, _} <- Pipeline.common_pipeline(accept_data, local: true) do
      {:ok, follower}
    end
  end

  def reject_follow_request(follower, followed) do
    with %Activity{} = follow_activity <- Utils.fetch_latest_follow(follower, followed),
         {:ok, reject_data, _} <- Builder.reject(followed, follow_activity),
         {:ok, _activity, _} <- Pipeline.common_pipeline(reject_data, local: true) do
      {:ok, follower}
    end
  end

  def delete(activity_id, user) do
    with {_, %Activity{data: %{"object" => _, "type" => "Create"}} = activity} <-
           {:find_activity, Activity.get_by_id(activity_id, filter: [])},
         {_, %Object{} = object, _} <-
           {:find_object, Object.normalize(activity, fetch: false), activity},
         true <- User.privileged?(user, :messages_delete) || user.ap_id == object.data["actor"],
         {_, {:ok, _}} <- {:cancel_jobs, maybe_cancel_jobs(activity)},
         {:ok, delete_data, _} <- Builder.delete(user, object.data["id"]),
         delete_opts = delete_pipeline_opts(activity),
         {:ok, delete, _} <- Pipeline.common_pipeline(delete_data, delete_opts) do
      if User.privileged?(user, :messages_delete) and user.ap_id != object.data["actor"] do
        action =
          if object.data["type"] == "ChatMessage" do
            "chat_message_delete"
          else
            "status_delete"
          end

        ModerationLog.insert_log(%{
          action: action,
          actor: user,
          subject_id: activity_id
        })
      end

      {:ok, delete}
    else
      {:find_activity, _} ->
        {:error, :not_found}

      {:find_object, nil, %Activity{data: %{"actor" => actor, "object" => object}}} ->
        # We have the create activity, but not the object, it was probably pruned.
        # Insert a tombstone and try again
        with {:ok, tombstone_data, _} <- Builder.tombstone(actor, object),
             {:ok, _tombstone} <- Object.create(tombstone_data) do
          delete(activity_id, user)
        else
          _ ->
            Logger.error(
              "Could not insert tombstone for missing object on deletion. Object is #{object}."
            )

            {:error, dgettext("errors", "Could not delete")}
        end

      _ ->
        {:error, dgettext("errors", "Could not delete")}
    end
  end

  # A Delete is useful only after a peer has accepted the object. Existing
  # rows are conservatively backfilled as federated, while new rows acquire
  # this state from the publisher after a successful remote response.
  defp delete_pipeline_opts(%Activity{local: true, federated: false}) do
    [local: true, do_not_federate: true]
  end

  defp delete_pipeline_opts(_activity), do: [local: true]

  def repeat(id, user, params \\ %{}) do
    with %Activity{data: %{"type" => "Create"}} = activity <- repeat_target_activity(id),
         object = %Object{} <- Object.normalize(activity, fetch: false),
         :ok <- ensure_interaction_federation_allowed(user, activity, object),
         {_, nil} <- {:existing_announce, Utils.get_existing_announce(user.ap_id, object)},
         visibility = announce_visibility(object, params),
         {:ok, announce, _} <- Builder.announce(user, object, visibility: visibility),
         {:ok, activity, _} <- Pipeline.common_pipeline(announce, local: true) do
      {:ok, activity}
    else
      {:existing_announce, %Activity{} = announce} ->
        {:ok, announce}

      {:error, message} when is_binary(message) ->
        {:error, message}

      _ ->
        {:error, :not_found}
    end
  end

  def unrepeat(id, user) do
    lock_key = "common-api-unrepeat:#{user.id}:#{id}"

    case Pleroma.Repo.transaction(fn ->
           Pleroma.Repo.query!(
             "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
             [lock_key]
           )

           case do_unrepeat(id, user) do
             {:ok, activity} -> activity
             {:error, reason} -> Pleroma.Repo.rollback(reason)
           end
         end) do
      {:ok, activity} -> {:ok, activity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_unrepeat(id, user) do
    with {_, %Activity{data: %{"type" => "Create"}} = activity} <-
           {:find_activity, repeat_target_activity(id)},
         %Object{} = note <- Object.normalize(activity, fetch: false) do
      case Utils.get_existing_announce(user.ap_id, note) do
        %Activity{} = announce ->
          with {_, {:ok, _}} <- {:cancel_jobs, maybe_cancel_jobs(announce)},
               {:ok, undo, _} <- Builder.undo(user, announce),
               {:ok, undo_activity, _} <- Pipeline.common_pipeline(undo, local: true) do
            {:ok, undo_activity}
          else
            _ -> {:error, dgettext("errors", "Could not unrepeat")}
          end

        nil ->
          # Mastodon treats unreblog as idempotent. Returning the original
          # Create also prevents a retry from generating another federated
          # Undo after the first request removed the Announce.
          {:ok, activity}
      end
    else
      {:find_activity, _} -> {:error, :not_found}
      _ -> {:error, dgettext("errors", "Could not unrepeat")}
    end
  end

  # Mastodon clients normally submit the original Create ID, but cards backed
  # by relay or cross-protocol projections can expose an Announce ID. Resolve
  # that displayed shape here so users can repeat and unrepeat the underlying
  # post without requiring every client to understand the projection.
  defp repeat_target_activity(id) do
    case Activity.get_by_id(id) do
      %Activity{data: %{"type" => "Create"}} = activity ->
        activity

      %Activity{data: %{"type" => "Announce", "object" => object_id}}
      when is_binary(object_id) ->
        Activity.get_create_by_object_ap_id(object_id)

      _ ->
        nil
    end
  end

  @spec favorite(User.t(), binary()) :: {:ok, Activity.t() | :already_liked} | {:error, any()}
  def favorite(%User{} = user, id) do
    case favorite_helper(user, id) do
      {:ok, _} = res ->
        res

      {:error, :not_found} = res ->
        res

      {:error, :event_full} ->
        {:error, dgettext("errors", "This event is full")}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, e} ->
        Logger.error("Could not favorite #{id}. Error: #{inspect(e, pretty: true)}")
        {:error, dgettext("errors", "Could not favorite")}
    end
  end

  def favorite_helper(user, id) do
    with {_, %Activity{object: object} = activity} <-
           {:find_object, Activity.get_by_id_with_object(id)},
         {_, true} <- {:visibility_error, activity_visible_to_actor(object, user)},
         :ok <- ensure_interaction_federation_allowed(user, activity, object),
         {_, {:ok, like_object, meta}} <- {:build_object, Builder.like(user, object)},
         {_, {:ok, %Activity{} = activity, _meta}} <-
           {:common_pipeline,
            Pipeline.common_pipeline(like_object, Keyword.put(meta, :local, true))} do
      {:ok, activity}
    else
      {:find_object, _} ->
        {:error, :not_found}

      {:visibility_error, _} ->
        {:error, :not_found}

      {:common_pipeline, {:error, {:validate, {:error, changeset}}}} = e ->
        if {:object, {"already liked by this actor", []}} in changeset.errors do
          {:ok, :already_liked}
        else
          {:error, e}
        end

      {:error, message} when is_binary(message) ->
        {:error, message}

      e ->
        {:error, e}
    end
  end

  def unfavorite(id, user) do
    with {_, %Activity{data: %{"type" => "Create"}} = activity} <-
           {:find_activity, Activity.get_by_id(id)},
         %Object{} = note <- Object.normalize(activity, fetch: false),
         {_, true} <- {:visibility_error, activity_visible_to_actor(note, user)},
         %Activity{} = like <- Utils.get_existing_like(user.ap_id, note),
         {_, {:ok, _}} <- {:cancel_jobs, maybe_cancel_jobs(like)},
         {:ok, undo, _} <- Builder.undo(user, like),
         {:ok, activity, _} <- Pipeline.common_pipeline(undo, local: true) do
      {:ok, activity}
    else
      {:find_activity, _} -> {:error, :not_found}
      {:visibility_error, _} -> {:error, :not_found}
      _ -> {:error, dgettext("errors", "Could not unfavorite")}
    end
  end

  def react_with_emoji(id, user, emoji) do
    with true <-
           Pleroma.Web.ActivityPub.ObjectValidators.EmojiReactValidator.valid_reaction_name?(
             emoji
           ),
         %Activity{} = activity <- Activity.get_by_id(id),
         {_, true} <- {:visibility_error, activity_visible_to_actor(activity, user)},
         object <- Object.normalize(activity, fetch: false),
         :ok <- ensure_interaction_federation_allowed(user, activity, object),
         {:ok, emoji_react, _} <- Builder.emoji_react(user, object, emoji),
         {:ok, activity, _} <- Pipeline.common_pipeline(emoji_react, local: true) do
      {:ok, activity}
    else
      {:visibility_error, _} ->
        {:error, :not_found}

      {:error, message} when is_binary(message) ->
        {:error, message}

      _ ->
        {:error, dgettext("errors", "Could not add reaction emoji")}
    end
  end

  def unreact_with_emoji(id, user, emoji) do
    with true <-
           Pleroma.Web.ActivityPub.ObjectValidators.EmojiReactValidator.valid_reaction_name?(
             emoji
           ),
         %Activity{} = reaction_activity <- Utils.get_latest_reaction(id, user, emoji),
         {_, {:ok, _}} <- {:cancel_jobs, maybe_cancel_jobs(reaction_activity)},
         {:ok, undo, _} <- Builder.undo(user, reaction_activity),
         {:ok, activity, _} <- Pipeline.common_pipeline(undo, local: true) do
      {:ok, activity}
    else
      _ ->
        {:error, dgettext("errors", "Could not remove reaction emoji")}
    end
  end

  def dislike(id, user) do
    with %Activity{} = activity <- Activity.get_by_id(id),
         {_, true} <- {:visibility_error, activity_visible_to_actor(activity, user)},
         object <- Object.normalize(activity, fetch: false),
         :ok <- ensure_interaction_federation_allowed(user, activity, object),
         nil <- Utils.get_existing_emoji_reaction(user.ap_id, object, "👎"),
         {:ok, dislike, meta} <- Builder.dislike(user, object),
         {:ok, activity, _} <-
           Pipeline.common_pipeline(dislike, Keyword.put(meta, :local, true)) do
      {:ok, activity}
    else
      %Activity{} -> {:ok, :already_disliked}
      {:visibility_error, _} -> {:error, :not_found}
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, dgettext("errors", "Could not dislike")}
    end
  end

  def undislike(id, user) do
    with %Activity{} = reaction_activity <- Utils.get_latest_reaction(id, user, "👎"),
         {_, {:ok, _}} <- {:cancel_jobs, maybe_cancel_jobs(reaction_activity)},
         {:ok, undo, _} <- Builder.undo(user, reaction_activity),
         {:ok, activity, _} <- Pipeline.common_pipeline(undo, local: true) do
      {:ok, activity}
    else
      _ -> {:error, dgettext("errors", "Could not remove dislike")}
    end
  end

  def vote(%Pleroma.Object{} = object, %Pleroma.User{} = user, choices) do
    vote(user, object, choices)
  end

  def vote(user, %{data: %{"type" => "Question"}} = object, choices) do
    with :ok <- validate_poll_open(object),
         :ok <- validate_not_author(object, user),
         :ok <- validate_existing_votes(user, object),
         {:ok, options, choices} <- normalize_and_validate_choices(choices, object) do
      answer_activities =
        Enum.map(choices, fn index ->
          {:ok, answer_object, _meta} =
            Builder.answer(user, object, Enum.at(options, index)["name"])

          {:ok, activity_data, _meta} = Builder.create(user, answer_object, [])

          {:ok, activity, _meta} =
            activity_data
            |> Map.put("cc", answer_object["cc"])
            |> Map.put("context", answer_object["context"])
            |> Pipeline.common_pipeline(local: true)

          # Pipeline returns the activity. Normalize it here so callers get the
          # same shape as fetched activities with their object available.
          Activity.normalize(activity.data)
        end)

      object = Object.get_cached_by_ap_id(object.data["id"])
      {:ok, answer_activities, object}
    end
  end

  defp validate_poll_open(%{data: %{"closed" => closed}}) when is_binary(closed) do
    with {:ok, normalized} <-
           Pleroma.EctoType.ActivityPub.ObjectValidators.DateTime.cast(closed),
         {:ok, closes_at, _offset} <- DateTime.from_iso8601(normalized) do
      if DateTime.compare(closes_at, DateTime.utc_now()) == :gt do
        :ok
      else
        {:error, dgettext("errors", "Poll has expired")}
      end
    else
      _invalid_remote_timestamp -> :ok
    end
  end

  defp validate_poll_open(_object), do: :ok

  def join(%User{} = user, event_id, params \\ %{}) do
    participation_message = Map.get(params, :participation_message)

    case join_helper(user, event_id, participation_message) do
      {:ok, _} = res ->
        res

      {:error, :not_found} = res ->
        res

      {:error, e} ->
        Logger.error("Could not join #{event_id}. Error: #{inspect(e, pretty: true)}")
        {:error, dgettext("errors", "Could not join")}
    end
  end

  defp join_helper(user, id, participation_message) do
    with {_, %Activity{object: %Object{data: %{"id" => event_ap_id}}}} <-
           {:find_object, Activity.get_by_id_with_object(id)} do
      with_event_capacity_lock(event_ap_id, fn ->
        join_event_under_lock(user, event_ap_id, participation_message)
      end)
    else
      {:find_object, _} ->
        {:error, :not_found}
    end
  end

  defp join_event_under_lock(user, event_ap_id, participation_message) do
    with %Object{} = object <- Object.get_by_ap_id(event_ap_id),
         :ok <- validate_event_join_capacity(user, object),
         {_, {:ok, join_object, meta}} <-
           {:build_object, Builder.join(user, object, participation_message)},
         {_, {:ok, %Activity{} = activity, _meta}} <-
           {:common_pipeline,
            Pipeline.common_pipeline(join_object, Keyword.put(meta, :local, true))} do
      {:ok, activity}
    else
      nil ->
        {:error, :not_found}

      {:common_pipeline, {:error, {:validate, {:error, changeset}}}} = e ->
        if {:object, {"already joined by this actor", []}} in changeset.errors do
          {:ok, :already_joined}
        else
          {:error, e}
        end

      e ->
        {:error, e}
    end
  end

  def leave(%User{ap_id: participant_ap_id} = user, event_id) do
    with %Activity{data: %{"object" => event_ap_id}} <- Activity.get_by_id(event_id),
         %Object{} = event <- Object.get_by_ap_id(event_ap_id),
         %Activity{} <- Utils.get_existing_join(participant_ap_id, event_ap_id),
         {:ok, leave, _} <- Builder.leave(user, event),
         {:ok, activity, _} <- Pipeline.common_pipeline(leave, local: true) do
      {:ok, activity}
    else
      nil ->
        {:error, dgettext("errors", "Not participating in the event")}

      _ ->
        {:error, dgettext("errors", "Could not remove join activity")}
    end
  end

  def accept_join_request(%User{} = user, %User{ap_id: participant_ap_id} = participant, event_id) do
    result =
      with_event_capacity_lock(event_id, fn ->
        with %Activity{} = join_activity <- Utils.get_existing_join(participant_ap_id, event_id),
             %Object{} = event <- Object.get_by_ap_id(event_id),
             {:ok, accept_data, _} <- Builder.accept(user, join_activity),
             :ok <- validate_event_approval_capacity(participant, event),
             {:ok, _activity, _} <- Pipeline.common_pipeline(accept_data, local: true) do
          if Object.local?(event) and event.data["joinMode"] != "free" and
               join_activity.data["actor"] == event.data["actor"] do
            Utils.update_participation_request_count_in_object(event)
          end

          {:ok, participant}
        end
      end)

    case result do
      {:error, :event_full} ->
        {:error, dgettext("errors", "This event is full")}

      result ->
        result
    end
  end

  defp with_event_capacity_lock(event_id, callback) when is_binary(event_id) do
    case Repo.transaction(fn ->
           with {:ok, _result} <-
                  Repo.query(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    [event_id]
                  ) do
             callback.()
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_event_capacity_lock(_event_id, _callback), do: {:error, :not_found}

  defp validate_event_join_capacity(%User{ap_id: participant_ap_id}, %Object{data: data}) do
    cond do
      Utils.get_existing_join(participant_ap_id, data["id"]) != nil ->
        :ok

      data["joinMode"] in ["restricted", "invite"] ->
        :ok

      event_at_capacity?(data) ->
        {:error, :event_full}

      true ->
        :ok
    end
  end

  defp validate_event_approval_capacity(%User{ap_id: participant_ap_id}, %Object{data: data}) do
    if participant_ap_id in List.wrap(data["participations"]) or not event_at_capacity?(data) do
      :ok
    else
      {:error, :event_full}
    end
  end

  defp event_at_capacity?(data) do
    remaining_capacity = event_integer(data["remainingAttendeeCapacity"])
    maximum_capacity = event_integer(data["maximumAttendeeCapacity"])

    participant_count =
      [
        event_integer(data["participantCount"]),
        event_integer(data["participation_count"]),
        length(List.wrap(data["participations"]))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)

    cond do
      is_integer(remaining_capacity) and remaining_capacity <= 0 ->
        true

      is_integer(maximum_capacity) and maximum_capacity >= 0 ->
        participant_count >= maximum_capacity

      true ->
        false
    end
  end

  defp event_integer(value) when is_integer(value), do: value

  defp event_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp event_integer(_value), do: nil

  def reject_join_request(%User{} = user, %User{ap_id: participant_ap_id} = participant, event_id) do
    with %Activity{} = join_activity <- Utils.get_existing_join(participant_ap_id, event_id),
         {:ok, reject_data, _} <- Builder.reject(user, join_activity),
         {:ok, _activity, _} <- Pipeline.common_pipeline(reject_data, local: true),
         event <- Object.get_by_ap_id(event_id),
         {:ok, _} <- Utils.update_participation_request_count_in_object(event) do
      {:ok, participant}
    end
  end

  defp validate_not_author(%{data: %{"actor" => ap_id}}, %{ap_id: ap_id}),
    do: {:error, dgettext("errors", "Poll's author can't vote")}

  defp validate_not_author(_, _), do: :ok

  defp validate_existing_votes(%{ap_id: ap_id}, object) do
    if Utils.get_existing_votes(ap_id, object) == [] do
      :ok
    else
      {:error, dgettext("errors", "Already voted")}
    end
  end

  defp get_options_and_max_count(%{data: %{"anyOf" => any_of}})
       when is_list(any_of) and any_of != [],
       do: {any_of, Enum.count(any_of)}

  defp get_options_and_max_count(%{data: %{"oneOf" => one_of}})
       when is_list(one_of) and one_of != [],
       do: {one_of, 1}

  defp normalize_and_validate_choices(choices, object) do
    choices = Enum.map(choices, fn i -> if is_binary(i), do: String.to_integer(i), else: i end)
    {options, max_count} = get_options_and_max_count(object)
    count = Enum.count(options)

    with {_, true} <- {:valid_choice, Enum.all?(choices, &(&1 < count))},
         {_, true} <- {:count_check, Enum.count(choices) <= max_count} do
      {:ok, options, choices}
    else
      {:valid_choice, _} -> {:error, dgettext("errors", "Invalid indices")}
      {:count_check, _} -> {:error, dgettext("errors", "Too many choices")}
    end
  end

  def announce_visibility(_, %{visibility: visibility})
      when visibility in ~w{public unlisted private direct local},
      do: visibility

  def announce_visibility(object, _), do: Visibility.get_visibility(object)

  def get_visibility(_, _, %Participation{}), do: {"direct", "direct"}

  def get_visibility(%{visibility: visibility}, in_reply_to, _)
      when visibility in ~w{public local unlisted private direct},
      do:
        {restrict_visibility(visibility, get_replied_to_visibility(in_reply_to)),
         get_replied_to_visibility(in_reply_to)}

  def get_visibility(%{visibility: "list:" <> list_id}, in_reply_to, _) do
    visibility = {:list, String.to_integer(list_id)}
    {visibility, get_replied_to_visibility(in_reply_to)}
  end

  def get_visibility(params, in_reply_to, _) when not is_nil(in_reply_to) do
    visibility = get_replied_to_visibility(in_reply_to)
    {default_group_visibility(visibility, params, in_reply_to), visibility}
  end

  def get_visibility(params, in_reply_to, _) do
    visibility = default_group_visibility("public", params, in_reply_to)
    {visibility, get_replied_to_visibility(in_reply_to)}
  end

  @doc """
  Prevents a local reply or quote from being published more broadly than the
  referenced post.

  Direct posts retain the existing validation path, which rejects an explicit
  non-direct reply instead of silently changing it. List visibility is also
  left alone because it represents an explicit recipient set rather than a
  position in the public/private visibility ordering.
  """
  def restrict_visibility(visibility, "private")
      when visibility in ~w{public local unlisted},
      do: "private"

  def restrict_visibility(visibility, "unlisted") when visibility in ~w{public local},
    do: "unlisted"

  def restrict_visibility(visibility, "local") when visibility in ~w{public unlisted},
    do: "local"

  def restrict_visibility(visibility, _referenced_visibility), do: visibility

  defp default_group_visibility(fallback, params, in_reply_to) do
    cond do
      not public_group_context?(params, in_reply_to) ->
        fallback

      Params.truthy_param?(
        Map.get(params, :group_timeline_visible, Map.get(params, "group_timeline_visible"))
      ) ->
        "public"

      fallback in [nil, "public", "unlisted", "local"] ->
        configured_group_post_visibility()

      true ->
        fallback
    end
  end

  defp configured_group_post_visibility do
    case Config.get([:instance, :group_post_default_visibility], "unlisted") do
      visibility when visibility in ["public", "unlisted"] -> visibility
      _ -> "unlisted"
    end
  end

  defp public_group_context?(params, in_reply_to) do
    has_group_targets?(params) || replied_to_group_context?(in_reply_to)
  end

  defp has_group_targets?(params) when is_map(params) do
    params
    |> group_target_values()
    |> Enum.any?(&present_group_target?/1)
  end

  defp has_group_targets?(_), do: false

  defp present_group_target?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_group_target?(value) when is_integer(value), do: true
  defp present_group_target?(_), do: false

  defp group_target_values(params) do
    []
    |> add_group_target_values(Map.get(params, :group_id, Map.get(params, "group_id")))
    |> add_group_target_values(Map.get(params, :group_ids, Map.get(params, "group_ids")))
    |> add_group_target_values(Map.get(params, "group_ids[]"))
  end

  defp add_group_target_values(values, value) when is_list(value), do: values ++ value
  defp add_group_target_values(values, nil), do: values
  defp add_group_target_values(values, value), do: values ++ [value]

  defp replied_to_group_context?(%Activity{} = activity) do
    with %Object{data: data} <- Object.normalize(activity, fetch: false) do
      Addressing.group_addressing_context?(data)
    else
      _ -> false
    end
  end

  defp replied_to_group_context?(_), do: false

  def get_replied_to_visibility(nil), do: nil

  def get_replied_to_visibility(activity) do
    with %Object{} = object <- Object.normalize(activity, fetch: false) do
      Visibility.get_visibility(object)
    end
  end

  def check_expiry_date({:ok, nil} = res), do: res

  def check_expiry_date({:ok, in_seconds}) do
    expiry = DateTime.add(DateTime.utc_now(), in_seconds)

    if Pleroma.Workers.PurgeExpiredActivity.expires_late_enough?(expiry) do
      {:ok, expiry}
    else
      {:error, "Expiry date is too soon"}
    end
  end

  def check_expiry_date(expiry_str) do
    Ecto.Type.cast(:integer, expiry_str)
    |> check_expiry_date()
  end

  def listen(user, data) do
    with {:ok, draft} <- ActivityDraft.listen(user, data) do
      ActivityPub.listen(draft.changes)
    end
  end

  @doc "Records a listen against the canonical track represented by a visible status."
  @spec listen_to_status(User.t(), binary()) :: {:ok, Activity.t()} | {:error, atom()}
  def listen_to_status(%User{} = user, id) do
    with {_, %Activity{object: %Object{} = object} = activity} <-
           {:find_activity, Activity.get_by_id_with_object(id)},
         {_, true} <- {:visibility, activity_visible_to_actor(object, user)},
         {_, track_ap_id} when is_binary(track_ap_id) <-
           {:track, listen_track_ap_id(activity, object)} do
      listen(user, %{
        title: object.data["name"] || object.data["title"] || "Federated track",
        track_ap_id: track_ap_id,
        visibility: listen_visibility(activity)
      })
    else
      {:track, _} -> {:error, :not_a_track}
      _ -> {:error, :not_found}
    end
  end

  defp listen_track_ap_id(%Activity{} = activity, %Object{} = object) do
    activity.data["_pleroma_listen_track_ap_id"] ||
      listen_reference_id(object.data["track"]) ||
      listen_object_ap_id(object.data)
  end

  defp listen_object_ap_id(%{"id" => id, "type" => type})
       when is_binary(id) and id != "" do
    if Pleroma.Web.ActivityPub.CustomObject.short_type(type) in ["Audio", "Track"],
      do: id
  end

  defp listen_object_ap_id(_object), do: nil

  defp listen_reference_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp listen_reference_id(id) when is_binary(id) and id != "", do: id
  defp listen_reference_id(_reference), do: nil

  defp listen_visibility(activity) do
    if Visibility.get_visibility(activity) in ["private", "direct"], do: "private", else: "public"
  end

  def post(user, %{status: _} = data) do
    with :ok <- ensure_post_federation_allowed(user, data),
         {:ok, draft} <- ActivityDraft.create(user, data) do
      case ActivityPub.create(draft.changes, draft.preview?) do
        {:ok, %Activity{} = activity} = result ->
          # Status creation uses ActivityPub.create/2 directly instead of the
          # common pipeline, so optional protocol exporters must be queued
          # explicitly after the activity has committed.
          Pleroma.Nostr.maybe_enqueue_activity(activity, [])
          result

        result ->
          result
      end
    end
  end

  def update(user, orig_activity, changes) do
    with orig_object <- Object.normalize(orig_activity),
         :ok <- validate_update_transitions(orig_object, changes),
         {:ok, new_object} <- make_update_data(user, orig_object, changes),
         {:ok, update_data, _} <- Builder.update(user, new_object),
         {:ok, update, _} <- Pipeline.common_pipeline(update_data, local: true) do
      {:ok, update}
    else
      {:error, _reason} = error -> error
    end
  end

  @quote_target_edit_keys [:quoted_status_id, "quoted_status_id", :quote_id, "quote_id"]

  defp validate_update_transitions(%Object{data: original}, changes) when is_map(changes) do
    original_has_poll = poll_object?(original)
    original_has_media = nonempty_list?(original["attachment"])
    target_has_poll = update_collection_state(changes, :poll, original_has_poll)
    target_has_media = update_collection_state(changes, :media_ids, original_has_media)

    cond do
      Enum.any?(@quote_target_edit_keys, &Map.has_key?(changes, &1)) ->
        update_transition_error(
          "A quoted status cannot be added, removed, or replaced while editing."
        )

      original_has_media and target_has_poll ->
        update_transition_error(
          "A media status cannot be replaced with a poll in the same edit. Remove the media first."
        )

      original_has_poll and target_has_media ->
        update_transition_error(
          "A poll cannot be replaced with media in the same edit. Remove the poll first."
        )

      target_has_poll and target_has_media ->
        update_transition_error("A status cannot contain both a poll and media attachments.")

      true ->
        :ok
    end
  end

  defp validate_update_transitions(_original, _changes),
    do: update_transition_error("The status could not be prepared for editing.")

  defp update_collection_state(changes, key, original_state) do
    case Map.fetch(changes, key) do
      {:ok, value} ->
        structured_edit_value?(key, value)

      :error ->
        case Map.fetch(changes, Atom.to_string(key)) do
          {:ok, value} -> structured_edit_value?(key, value)
          :error -> original_state
        end
    end
  end

  defp structured_edit_value?(:poll, value), do: is_map(value)
  defp structured_edit_value?(:media_ids, value), do: nonempty_list?(value)

  defp poll_object?(data) do
    data["type"] == "Question" or nonempty_list?(data["oneOf"]) or nonempty_list?(data["anyOf"])
  end

  defp nonempty_list?(value), do: is_list(value) and value != []

  defp update_transition_error(message),
    do: {:error, {:unprocessable_entity, message}}

  @doc "Sets the Threadiverse moderator-comment distinction on an owned group reply."
  def set_distinguished_comment(%User{} = user, %Activity{} = activity, value)
      when is_boolean(value) do
    Pleroma.Web.ActivityPub.DistinguishedComment.set(user, activity, value)
  end

  def set_distinguished_comment(%User{}, %Activity{}, _value),
    do: {:error, :invalid_distinguished_comment}

  defp make_update_data(user, orig_object, changes) do
    kept_params = %{
      visibility: Visibility.get_visibility(orig_object),
      in_reply_to_id:
        with replied_id when is_binary(replied_id) <- orig_object.data["inReplyTo"],
             %Activity{id: activity_id} <- Activity.get_create_by_object_ap_id(replied_id) do
          activity_id
        else
          _ -> nil
        end
    }

    params = Map.merge(changes, kept_params)

    with {:ok, draft} <- ActivityDraft.create(user, params) do
      draft_object = preserve_quote_policy(draft.object, orig_object.data, changes)

      change =
        Object.Updater.make_update_object_data(orig_object.data, draft_object, Utils.make_date())

      {:ok, change}
    else
      {:error, _reason} = error -> error
    end
  end

  # Clients predating quote controls omit this field when editing unrelated
  # content. In that case the edit must not silently broaden or replace the
  # ActivityPub interaction policy already attached to the post.
  defp preserve_quote_policy(draft_object, original_object, changes) do
    if Map.has_key?(changes, :quote_approval_policy) or
         Map.has_key?(changes, "quote_approval_policy") do
      draft_object
    else
      case Map.fetch(original_object, "interactionPolicy") do
        {:ok, policy} -> Map.put(draft_object, "interactionPolicy", policy)
        :error -> Map.delete(draft_object, "interactionPolicy")
      end
    end
  end

  @spec pin(String.t(), User.t()) :: {:ok, Activity.t()} | Pipeline.errors()
  def pin(id, %User{} = user) do
    with %Activity{} = activity <- create_activity_by_id(id),
         true <- activity_visible_to_actor(activity, user),
         true <- activity_belongs_to_actor(activity, user.ap_id),
         true <- object_type_is_allowed_for_pin(activity.object),
         true <- activity_is_public(activity),
         {:ok, pin_data, _} <- Builder.pin(user, activity.object),
         {:ok, _pin, _} <-
           Pipeline.common_pipeline(pin_data,
             local: true,
             activity_id: id
           ) do
      {:ok, activity}
    else
      {:error, {:side_effects, error}} -> error
      error -> error
    end
  end

  defp create_activity_by_id(id) do
    with nil <- Activity.create_by_id_with_object(id) do
      {:error, :not_found}
    end
  end

  defp activity_belongs_to_actor(%{actor: actor}, actor), do: true
  defp activity_belongs_to_actor(_, _), do: {:error, :ownership_error}

  defp activity_visible_to_actor(activity, %User{} = user) do
    if Visibility.visible_for_user?(activity, user) do
      true
    else
      {:error, :visibility_error}
    end
  end

  defp ensure_post_federation_allowed(%User{} = user, data) when is_map(data) do
    target_ids =
      [
        Map.get(data, :in_reply_to_id) || Map.get(data, "in_reply_to_id"),
        Map.get(data, :quote_id) || Map.get(data, "quote_id")
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with :ok <- ensure_federation_identifier_allowed(user),
         :ok <- ensure_group_posting_allowed(user, data) do
      Enum.reduce_while(target_ids, :ok, fn target_id, :ok ->
        case Activity.get_by_id(target_id) do
          %Activity{} = activity ->
            case ensure_interaction_federation_allowed(user, activity) do
              :ok -> {:cont, :ok}
              {:error, _} = error -> {:halt, error}
            end

          _ ->
            {:cont, :ok}
        end
      end)
    end
  end

  defp ensure_post_federation_allowed(_user, _data), do: :ok

  defp ensure_group_posting_allowed(%User{} = user, data) do
    data
    |> group_target_values()
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn identifier, :ok ->
      case FederatedTarget.resolve_group(identifier) do
        {:ok, %User{posting_restricted_to_mods: true} = group} ->
          if GroupMembership.manager?(user, group) do
            {:cont, :ok}
          else
            {:halt, {:error, "Only group moderators can post in this group"}}
          end

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp ensure_interaction_federation_allowed(%User{} = user, %Activity{} = activity) do
    ensure_interaction_federation_allowed(
      user,
      activity,
      Object.normalize(activity, fetch: false)
    )
  end

  defp ensure_interaction_federation_allowed(
         %User{} = user,
         %Activity{} = activity,
         object
       ) do
    identifiers =
      [activity.actor | interaction_object_identifiers(object)]
      |> Enum.flat_map(&federation_references/1)
      |> Enum.reject(&(&1 == Pleroma.Constants.as_public()))
      |> Enum.uniq()

    with :ok <- ensure_federation_identifier_allowed(user) do
      Enum.reduce_while(identifiers, :ok, fn identifier, :ok ->
        case ensure_federation_identifier_allowed(identifier) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp interaction_object_identifiers(%Object{data: data}) when is_map(data) do
    [data["actor"], data["attributedTo"], data["audience"]]
  end

  defp interaction_object_identifiers(_object), do: []

  defp federation_references(value) when is_binary(value), do: [value]
  defp federation_references(%{"id" => id}) when is_binary(id), do: [id]

  defp federation_references(values) when is_list(values) do
    Enum.flat_map(values, &federation_references/1)
  end

  defp federation_references(_value), do: []

  defp ensure_federation_identifier_allowed(%User{local: true}), do: :ok

  defp ensure_federation_identifier_allowed(%User{} = user) do
    ensure_federation_status_allowed(FederationStatus.for_user(user))
  end

  defp ensure_federation_identifier_allowed(identifier) when is_binary(identifier) do
    case User.get_cached_by_ap_id(identifier) do
      %User{local: true} -> :ok
      %User{} = user -> ensure_federation_identifier_allowed(user)
      nil -> ensure_federation_status_allowed(FederationStatus.for_identifier(identifier))
    end
  end

  defp ensure_federation_identifier_allowed(_identifier), do: :ok

  defp ensure_federation_status_allowed(%{defederated: true} = status) do
    {:error, FederationStatus.message(status)}
  end

  defp ensure_federation_status_allowed(_status), do: :ok

  defp object_type_is_allowed_for_pin(%{data: %{"type" => type}}) do
    with false <- type in ["Note", "Article", "Question"] do
      {:error, :not_allowed}
    end
  end

  defp maybe_cancel_jobs(%Activity{data: %{"id" => ap_id}}) when is_binary(ap_id) do
    Oban.Job
    |> where([j], j.worker == "Pleroma.Workers.PublisherWorker")
    |> where([j], j.args["op"] == "publish_one")
    |> where([j], j.args["params"]["id"] == ^ap_id)
    |> Oban.cancel_all_jobs()
  end

  defp maybe_cancel_jobs(_), do: {:ok, 0}

  defp activity_is_public(activity) do
    with false <- Visibility.is_public?(activity) do
      {:error, :non_public_error}
    end
  end

  @spec unpin(String.t(), User.t()) :: {:ok, Activity.t()} | Pipeline.errors()
  def unpin(id, user) do
    with %Activity{} = activity <- create_activity_by_id(id),
         true <- activity_visible_to_actor(activity, user),
         true <- activity_belongs_to_actor(activity, user.ap_id),
         {:ok, unpin_data, _} <- Builder.unpin(user, activity.object),
         {:ok, _unpin, _} <-
           Pipeline.common_pipeline(unpin_data,
             local: true,
             activity_id: activity.id,
             expires_at: activity.data["expires_at"],
             featured_address: user.featured_address
           ) do
      {:ok, activity}
    end
  end

  def add_mute(user, activity, params \\ %{}) do
    expires_in = Map.get(params, :expires_in, 0)

    with true <- activity_visible_to_actor(activity, user),
         {:ok, _} <- ThreadMute.add_mute(user.id, activity.data["context"]),
         _ <- Pleroma.Notification.mark_context_as_read(user, activity.data["context"]) do
      if expires_in > 0 do
        Pleroma.Workers.MuteExpireWorker.enqueue(
          "unmute_conversation",
          %{"user_id" => user.id, "activity_id" => activity.id},
          schedule_in: expires_in
        )
      end

      {:ok, activity}
    else
      {:error, :visibility_error} -> {:error, :visibility_error}
      {:error, _} -> {:error, dgettext("errors", "conversation is already muted")}
    end
  end

  def remove_mute(%User{} = user, %Activity{} = activity) do
    case activity_visible_to_actor(activity, user) do
      true ->
        ThreadMute.remove_mute(user.id, activity.data["context"])
        {:ok, activity}

      error ->
        error
    end
  end

  def remove_mute(user_id, activity_id) do
    with {:user, %User{} = user} <- {:user, User.get_by_id(user_id)},
         {:activity, %Activity{} = activity} <- {:activity, Activity.get_by_id(activity_id)} do
      remove_mute(user, activity)
    else
      {what, result} = error ->
        Logger.warning(
          "CommonAPI.remove_mute/2 failed. #{what}: #{result}, user_id: #{user_id}, activity_id: #{activity_id}"
        )

        {:error, error}
    end
  end

  def thread_muted?(%User{id: user_id}, %{data: %{"context" => context}})
      when is_binary(context) do
    ThreadMute.exists?(user_id, context)
  end

  def thread_muted?(_, _), do: false

  def report(user, data) do
    with {:ok, account} <- get_reported_account(data.account_id),
         {:ok, {content_html, _, _}} <- make_report_content_html(data[:comment]),
         {:ok, statuses} <- get_report_statuses(account, data),
         true <- check_statuses_visibility(user, statuses),
         rules <- get_report_rules(Map.get(data, :rule_ids, nil)) do
      ActivityPub.flag(%{
        context: Utils.generate_context_id(),
        actor: user,
        account: account,
        statuses: statuses,
        content: content_html,
        forward: Map.get(data, :forward, false),
        rules: rules
      })
    else
      false ->
        {:error, :visibility_error}

      error ->
        error
    end
  end

  defp check_statuses_visibility(user, statuses) when is_list(statuses) do
    statuses
    |> Enum.map(&Visibility.visible_for_user?(&1, user))
    |> Enum.all?()
  end

  defp check_statuses_visibility(_user, nil), do: true

  defp get_reported_account(account_id) do
    case User.get_cached_by_id(account_id) do
      %User{} = account -> {:ok, account}
      _ -> {:error, dgettext("errors", "Account not found")}
    end
  end

  defp get_report_rules(nil) do
    nil
  end

  defp get_report_rules(rule_ids) do
    rule_ids
    |> Enum.filter(&Rule.exists?/1)
  end

  def update_report_state(activity_ids, state) when is_list(activity_ids) do
    case Utils.update_report_state(activity_ids, state) do
      :ok -> {:ok, activity_ids}
      _ -> {:error, dgettext("errors", "Could not update state")}
    end
  end

  def update_report_state(activity_id, state) do
    with %Activity{} = activity <- Activity.get_by_id(activity_id, filter: []) do
      Utils.update_report_state(activity, state)
    else
      nil -> {:error, :not_found}
    end
  end

  def assign_report_to_account(activity_ids, user) when is_list(activity_ids) do
    case Utils.assign_report_to_account(activity_ids, user) do
      :ok -> {:ok, activity_ids}
      _ -> {:error, dgettext("errors", "Could not assign account")}
    end
  end

  def assign_report_to_account(activity_id, user) do
    with %Activity{} = activity <- Activity.get_by_id(activity_id) do
      Utils.assign_report_to_account(activity, user)
    else
      nil -> {:error, :not_found}
      _ -> {:error, dgettext("errors", "Could not assign account")}
    end
  end

  def update_activity_scope(activity_id, opts \\ %{}) do
    with %Activity{} = activity <- Activity.get_by_id_with_object(activity_id),
         {:ok, activity} <- toggle_sensitive(activity, opts) do
      set_visibility(activity, opts)
    else
      nil -> {:error, :not_found}
    end
  end

  defp toggle_sensitive(activity, %{sensitive: sensitive}) when sensitive in ~w(true false) do
    toggle_sensitive(activity, %{sensitive: String.to_existing_atom(sensitive)})
  end

  defp toggle_sensitive(%Activity{object: object} = activity, %{sensitive: sensitive})
       when is_boolean(sensitive) do
    new_data = Map.put(object.data, "sensitive", sensitive)

    {:ok, object} =
      object
      |> Object.change(%{data: new_data})
      |> Object.update_and_set_cache()

    {:ok, Map.put(activity, :object, object)}
  end

  defp toggle_sensitive(activity, _), do: {:ok, activity}

  defp set_visibility(activity, %{visibility: visibility}) do
    Utils.update_activity_visibility(activity, visibility)
  end

  defp set_visibility(activity, _), do: {:ok, activity}

  def hide_reblogs(%User{} = user, %User{} = target) do
    UserRelationship.create_reblog_mute(user, target)
  end

  def show_reblogs(%User{} = user, %User{} = target) do
    UserRelationship.delete_reblog_mute(user, target)
  end

  def get_user(ap_id, fake_record_fallback \\ true) do
    cond do
      user = User.get_cached_by_ap_id(ap_id) ->
        user

      user = User.get_by_guessed_nickname(ap_id) ->
        user

      fake_record_fallback ->
        User.error_user(ap_id)

      true ->
        nil
    end
  end

  def event(user, data, location \\ nil) do
    with {:ok, draft} <- ActivityDraft.event(user, data, location) do
      ActivityPub.create(draft.changes)
    end
  end

  def update_event(user, orig_activity, changes, location \\ nil) do
    with orig_object <- Object.normalize(orig_activity),
         {:ok, new_object} <- make_update_event_data(user, orig_object, changes, location),
         {:ok, update_data, _} <- Builder.update(user, new_object),
         {:ok, update, _} <- Pipeline.common_pipeline(update_data, local: true) do
      {:ok, update}
    else
      _ -> {:error, nil}
    end
  end

  defp make_update_event_data(user, orig_object, changes, location) do
    kept_params = %{
      visibility: Visibility.get_visibility(orig_object),
      in_reply_to_id:
        with replied_id when is_binary(replied_id) <- orig_object.data["inReplyTo"],
             %Activity{id: activity_id} <- Activity.get_create_by_object_ap_id(replied_id) do
          activity_id
        else
          _ -> nil
        end
    }

    params = Map.merge(changes, kept_params)

    with {:ok, draft} <- ActivityDraft.event(user, params, location) do
      change =
        Object.Updater.make_update_object_data(orig_object.data, draft.object, Utils.make_date())

      {:ok, change}
    else
      _ -> {:error, nil}
    end
  end
end
