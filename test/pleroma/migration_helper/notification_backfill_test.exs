# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.MigrationHelper.NotificationBackfillTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Activity
  alias Pleroma.MigrationHelper.NotificationBackfill
  alias Pleroma.Notification
  alias Pleroma.Repo
  alias Pleroma.Web.CommonAPI

  import Ecto.Query
  import Pleroma.Factory

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "fill_in_notification_types" do
    test "it fills in missing notification types" do
      user = insert(:user)
      other_user = insert(:user)

      {:ok, post} = CommonAPI.post(user, %{status: "yeah, @#{other_user.nickname}"})
      {:ok, chat} = CommonAPI.post_chat_message(user, other_user, "yo")
      {:ok, react} = CommonAPI.react_with_emoji(post.id, other_user, "☕")
      {:ok, like} = CommonAPI.favorite(other_user, post.id)
      {:ok, react_2} = CommonAPI.react_with_emoji(post.id, other_user, "☕")

      Pleroma.Tests.ObanHelpers.perform_all()

      data =
        react_2.data
        |> Map.put("type", "EmojiReaction")

      {:ok, react_2} =
        react_2
        |> Activity.change(%{data: data})
        |> Repo.update()

      assert {5, nil} = Repo.update_all(Notification, set: [type: nil])

      NotificationBackfill.fill_in_notification_types()

      assert %{type: "mention"} =
               Repo.get_by(Notification, user_id: other_user.id, activity_id: post.id)

      assert %{type: "favourite"} =
               Repo.get_by(Notification, user_id: user.id, activity_id: like.id)

      assert %{type: "pleroma:emoji_reaction"} =
               Repo.get_by(Notification, user_id: user.id, activity_id: react.id)

      assert %{type: "pleroma:emoji_reaction"} =
               Repo.get_by(Notification, user_id: user.id, activity_id: react_2.id)

      assert %{type: "pleroma:chat_mention"} =
               Repo.get_by(Notification, user_id: other_user.id, activity_id: chat.id)
    end
  end

  describe "fill_in_notification_group_keys" do
    test "it fills in missing group keys for groupable notification types" do
      user = insert(:user)
      first_actor = insert(:user)
      second_actor = insert(:user)

      {:ok, post} = CommonAPI.post(user, %{status: "group these"})

      {:ok, first_favourite} = CommonAPI.favorite(first_actor, post.id)
      {:ok, second_favourite} = CommonAPI.favorite(second_actor, post.id)
      {:ok, first_reblog} = CommonAPI.repeat(post.id, first_actor)
      {:ok, second_reblog} = CommonAPI.repeat(post.id, second_actor)
      {:ok, _, _, first_follow} = CommonAPI.follow(first_actor, user)
      {:ok, _, _, second_follow} = CommonAPI.follow(second_actor, user)

      {:ok, [_]} = Notification.create_notifications(first_favourite)
      {:ok, [_]} = Notification.create_notifications(second_favourite)
      {:ok, [_]} = Notification.create_notifications(first_reblog)
      {:ok, [_]} = Notification.create_notifications(second_reblog)

      {updated_count, nil} =
        Notification
        |> where(
          [n],
          n.activity_id in ^[
            first_favourite.id,
            second_favourite.id,
            first_reblog.id,
            second_reblog.id,
            first_follow.id,
            second_follow.id
          ]
        )
        |> Repo.update_all(set: [group_key: nil])

      assert updated_count >= 6

      NotificationBackfill.fill_in_notification_group_keys()

      notifications =
        Notification
        |> where(
          [n],
          n.activity_id in ^[
            first_favourite.id,
            second_favourite.id,
            first_reblog.id,
            second_reblog.id,
            first_follow.id,
            second_follow.id
          ]
        )
        |> order_by([n], asc: n.id)
        |> Repo.all()

      favourite_keys =
        notifications
        |> Enum.filter(&(&1.type == "favourite"))
        |> Enum.map(& &1.group_key)
        |> Enum.uniq()

      reblog_keys =
        notifications
        |> Enum.filter(&(&1.type == "reblog"))
        |> Enum.map(& &1.group_key)
        |> Enum.uniq()

      follow_keys =
        notifications
        |> Enum.filter(&(&1.type == "follow"))
        |> Enum.map(& &1.group_key)
        |> Enum.uniq()

      assert [favourite_key] = favourite_keys
      assert [reblog_key] = reblog_keys
      assert [follow_key] = follow_keys

      assert String.starts_with?(favourite_key, "favourite-#{post.id}-")
      assert String.starts_with?(reblog_key, "reblog-#{post.id}-")
      assert String.starts_with?(follow_key, "follow-#{user.id}-")
    end
  end
end
