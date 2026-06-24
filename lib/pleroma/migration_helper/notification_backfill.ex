# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.MigrationHelper.NotificationBackfill do
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  import Ecto.Query

  def fill_in_notification_types do
    query =
      from(n in Pleroma.Notification,
        where: is_nil(n.type),
        preload: :activity
      )

    query
    |> Repo.chunk_stream(100)
    |> Enum.each(fn notification ->
      if notification.activity do
        type = type_from_activity(notification.activity)

        notification
        |> Ecto.Changeset.change(%{type: type})
        |> Repo.update()
      end
    end)
  end

  def fill_in_notification_group_keys do
    query =
      from(n in Pleroma.Notification,
        where: is_nil(n.group_key) and n.type in ["favourite", "follow", "reblog"],
        preload: :activity
      )

    query
    |> Repo.chunk_stream(100)
    |> Enum.each(fn notification ->
      if notification.activity do
        group_key = grouped_notification_key(notification.type, notification.activity)

        if is_binary(group_key) do
          notification
          |> Ecto.Changeset.change(%{group_key: group_key})
          |> Repo.update()
        end
      end
    end)
  end

  defp get_by_ap_id(ap_id) do
    Repo.get_by(User, ap_id: ap_id)
  end

  # This is copied over from Notifications to keep this stable.
  defp type_from_activity(%{data: %{"type" => type}} = activity) do
    case type do
      "Follow" ->
        accepted_function = fn activity ->
          with %User{} = follower <- get_by_ap_id(activity.data["actor"]),
               %User{} = followed <- get_by_ap_id(activity.data["object"]) do
            Pleroma.FollowingRelationship.following?(follower, followed)
          end
        end

        if accepted_function.(activity) do
          "follow"
        else
          "follow_request"
        end

      "Announce" ->
        "reblog"

      "Like" ->
        "favourite"

      "Move" ->
        "move"

      "EmojiReact" ->
        "pleroma:emoji_reaction"

      # Compatibility with old reactions
      "EmojiReaction" ->
        "pleroma:emoji_reaction"

      "Create" ->
        type_from_activity_object(activity)

      t ->
        raise "No notification type for activity type #{t}"
    end
  end

  defp type_from_activity_object(%{data: %{"type" => "Create", "object" => %{}}}), do: "mention"

  defp type_from_activity_object(%{data: %{"type" => "Create"}} = activity) do
    object = Object.get_by_ap_id(activity.data["object"])

    case object && object.data["type"] do
      "ChatMessage" -> "pleroma:chat_mention"
      _ -> "mention"
    end
  end

  @groupable_notification_types ~w{favourite follow reblog}
  @group_bucket_seconds 12 * 60 * 60

  defp grouped_notification_key(type, activity) when type in @groupable_notification_types do
    with target_id when is_binary(target_id) <- group_target_id(type, activity) do
      "#{type}-#{target_id}-#{group_time_bucket(activity)}"
    end
  end

  defp grouped_notification_key(_type, _activity), do: nil

  defp group_time_bucket(%{inserted_at: inserted_at}) when not is_nil(inserted_at) do
    inserted_at
    |> NaiveDateTime.to_erl()
    |> :calendar.datetime_to_gregorian_seconds()
    |> div(@group_bucket_seconds)
  end

  defp group_time_bucket(_),
    do: group_time_bucket(%{inserted_at: NaiveDateTime.utc_now()})

  defp group_target_id(type, activity) when type in ["favourite", "reblog"] do
    with object_id when is_binary(object_id) <- object_id_for(activity),
         %Pleroma.Activity{id: id} <- Pleroma.Activity.get_create_by_object_ap_id(object_id) do
      to_string(id)
    else
      _ -> nil
    end
  end

  defp group_target_id("follow", %{data: %{"object" => ap_id}}) when is_binary(ap_id) do
    case get_by_ap_id(ap_id) do
      %User{id: id} -> to_string(id)
      _ -> nil
    end
  end

  defp group_target_id("follow", %{data: %{"object" => %{"id" => ap_id}}})
       when is_binary(ap_id) do
    case get_by_ap_id(ap_id) do
      %User{id: id} -> to_string(id)
      _ -> nil
    end
  end

  defp group_target_id(_, _), do: nil

  defp object_id_for(%{data: %{"object" => %{"id" => id}}}) when is_binary(id), do: id
  defp object_id_for(%{data: %{"object" => id}}) when is_binary(id), do: id
  defp object_id_for(_), do: nil
end
