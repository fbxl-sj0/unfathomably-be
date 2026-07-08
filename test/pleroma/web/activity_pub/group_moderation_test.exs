# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.GroupModerationTest do
  use Pleroma.DataCase, async: true

  import Ecto.Query
  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.GroupModeration

  require Pleroma.Constants

  describe "moderator collection federation" do
    test "publishes Lemmy-compatible Add and Announces it from the group" do
      owner = insert(:user)
      group = local_group()
      moderator = insert(:user)

      assert {:ok, activity} = GroupModeration.publish_moderator_add(owner, group, moderator)

      assert activity.data["type"] == "Add"
      assert activity.data["actor"] == owner.ap_id
      assert activity.data["object"] == moderator.ap_id
      assert activity.data["target"] == group.attributed_to_address
      assert activity.data["audience"] == group.ap_id
      assert activity.data["to"] == [Pleroma.Constants.as_public()]
      assert group.ap_id in activity.data["cc"]
      assert moderator.ap_id in activity.data["bcc"]

      assert_group_update(group)
      assert_group_announce(group, activity)
    end

    test "publishes Lemmy-compatible Remove and Announces it from the group" do
      owner = insert(:user)
      group = local_group()
      moderator = insert(:user)

      assert {:ok, activity} = GroupModeration.publish_moderator_remove(owner, group, moderator)

      assert activity.data["type"] == "Remove"
      assert activity.data["actor"] == owner.ap_id
      assert activity.data["object"] == moderator.ap_id
      assert activity.data["target"] == group.attributed_to_address
      assert activity.data["audience"] == group.ap_id
      assert activity.data["to"] == [Pleroma.Constants.as_public()]
      assert group.ap_id in activity.data["cc"]
      assert moderator.ap_id in activity.data["bcc"]

      assert_group_update(group)
      assert_group_announce(group, activity)
    end
  end

  describe "group ban federation" do
    test "publishes a community-scoped Block and Announces it from the group" do
      owner = insert(:user)
      group = local_group()
      account = insert(:user)

      assert {:ok, activity} =
               GroupModeration.publish_group_ban(owner, group, account,
                 reason: "spam",
                 remove_data: true
               )

      assert activity.data["type"] == "Block"
      assert activity.data["actor"] == owner.ap_id
      assert activity.data["object"] == account.ap_id
      assert activity.data["target"] == group.ap_id
      assert activity.data["audience"] == group.ap_id
      assert activity.data["summary"] == "spam"
      assert activity.data["removeData"] == true
      assert activity.data["to"] == [Pleroma.Constants.as_public()]
      assert group.ap_id in activity.data["cc"]
      assert account.ap_id in activity.data["bcc"]

      assert_group_update(group)
      assert_group_announce(group, activity)
    end

    test "publishes a community-scoped Undo Block and Announces it from the group" do
      owner = insert(:user)
      group = local_group()
      account = insert(:user)

      assert {:ok, activity} =
               GroupModeration.publish_group_unban(owner, group, account,
                 reason: "appeal accepted"
               )

      assert activity.data["type"] == "Undo"
      assert activity.data["actor"] == owner.ap_id
      assert activity.data["audience"] == group.ap_id
      assert activity.data["to"] == [Pleroma.Constants.as_public()]
      assert group.ap_id in activity.data["cc"]
      assert account.ap_id in activity.data["bcc"]

      assert activity.data["object"]["type"] == "Block"
      assert activity.data["object"]["actor"] == owner.ap_id
      assert activity.data["object"]["object"] == account.ap_id
      assert activity.data["object"]["target"] == group.ap_id
      assert activity.data["object"]["audience"] == group.ap_id
      assert activity.data["object"]["summary"] == "appeal accepted"

      assert_group_update(group)
      assert_group_announce(group, activity)
    end
  end

  test "does not publish local moderation activities for remote groups" do
    owner = insert(:user)
    remote_group = insert(:user, actor_type: "Group", local: false)
    account = insert(:user)

    assert {:error, :remote_group} =
             GroupModeration.publish_moderator_add(owner, remote_group, account)
  end

  defp local_group do
    group = insert(:user, actor_type: "Group", local: true)

    attributed_to_address = "#{group.ap_id}/collections/moderators"

    group
    |> Ecto.Changeset.change(attributed_to_address: attributed_to_address)
    |> Repo.update!()
  end

  defp assert_group_announce(group, activity) do
    assert %Activity{} = announce = announced_activity(activity)
    assert announce.data["type"] == "Announce"
    assert announce.data["actor"] == group.ap_id
    assert announce.data["object"]["id"] == activity.data["id"]
    assert announce.data["object"]["type"] == activity.data["type"]
    assert announce.data["audience"] == group.ap_id
    assert announce.data["to"] == [Pleroma.Constants.as_public()]
    assert group.follower_address in announce.data["cc"]
  end

  defp assert_group_update(group) do
    assert %Activity{} =
             update =
             Repo.one(
               from(a in Activity,
                 where:
                   fragment("?->>'type' = 'Update'", a.data) and
                     fragment("?->>'actor' = ?", a.data, ^group.ap_id) and
                     fragment("?->'object'->>'id' = ?", a.data, ^group.ap_id)
               )
             )

    assert update.data["object"]["attributedTo"] ==
             (group.attributed_to_address || "#{group.ap_id}/collections/moderators")

    assert group.follower_address in update.data["cc"]
  end

  defp announced_activity(activity) do
    Repo.one(
      from(a in Activity,
        where:
          fragment("?->>'type' = 'Announce'", a.data) and
            fragment("?->'object'->>'id' = ?", a.data, ^activity.data["id"])
      )
    )
  end
end

# end of group_moderation_test.exs
