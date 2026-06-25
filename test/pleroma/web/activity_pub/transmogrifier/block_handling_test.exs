# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.BlockHandlingTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Activity
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Transmogrifier

  import Pleroma.Factory

  test "it works for incoming blocks" do
    user = insert(:user)

    data =
      File.read!("test/fixtures/mastodon-block-activity.json")
      |> Jason.decode!()
      |> Map.put("object", user.ap_id)

    blocker = insert(:user, ap_id: data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Block"
    assert data["object"] == user.ap_id
    assert data["actor"] == "http://mastodon.example.org/users/admin"

    assert User.blocks?(blocker, user)
  end

  test "incoming blocks successfully tear down any follow relationship" do
    blocker = insert(:user)
    blocked = insert(:user)

    data =
      File.read!("test/fixtures/mastodon-block-activity.json")
      |> Jason.decode!()
      |> Map.put("object", blocked.ap_id)
      |> Map.put("actor", blocker.ap_id)

    {:ok, blocker, blocked} = User.follow(blocker, blocked)
    {:ok, blocked, blocker} = User.follow(blocked, blocker)

    assert User.following?(blocker, blocked)
    assert User.following?(blocked, blocker)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Block"
    assert data["object"] == blocked.ap_id
    assert data["actor"] == blocker.ap_id

    blocker = User.get_cached_by_ap_id(data["actor"])
    blocked = User.get_cached_by_ap_id(data["object"])

    assert User.blocks?(blocker, blocked)

    refute User.following?(blocker, blocked)
    refute User.following?(blocked, blocker)
  end

  test "incoming scoped blocks do not create personal user blocks" do
    moderator = insert(:user, local: false)
    banned = insert(:user, local: false)
    group = insert(:user, actor_type: "Group", local: false)

    data =
      File.read!("test/fixtures/mastodon-block-activity.json")
      |> Jason.decode!()
      |> Map.put("id", "#{group.ap_id}/activities/ban-user")
      |> Map.put("actor", moderator.ap_id)
      |> Map.put("object", banned.ap_id)
      |> Map.put("target", group.ap_id)
      |> Map.put("audience", [group.ap_id])
      |> Map.put("summary", "Banned from this magazine")
      |> Map.put("expires", "2026-07-24T12:00:00Z")

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Block"
    assert data["actor"] == moderator.ap_id
    assert data["object"] == banned.ap_id
    assert data["target"] == group.ap_id
    assert data["audience"] == [group.ap_id]
    assert data["summary"] == "Banned from this magazine"
    assert data["expires"] == "2026-07-24T12:00:00Z"

    refute User.blocks?(moderator, banned)
  end

  test "incoming scoped block undos do not undo personal user blocks" do
    moderator = insert(:user, local: false)
    banned = insert(:user, local: false)
    group = insert(:user, actor_type: "Group", local: false)

    {:ok, _user_relationship} = User.block(moderator, banned)

    data =
      File.read!("test/fixtures/mastodon-block-activity.json")
      |> Jason.decode!()
      |> Map.put("id", "#{group.ap_id}/activities/ban-user")
      |> Map.put("actor", moderator.ap_id)
      |> Map.put("object", banned.ap_id)
      |> Map.put("target", group.ap_id)
      |> Map.put("audience", [group.ap_id])
      |> Map.put("summary", "Banned from this magazine")

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    undo_data = %{
      "id" => "#{data["id"]}/undo",
      "type" => "Undo",
      "actor" => moderator.ap_id,
      "object" => data
    }

    {:ok, %Activity{data: undo_data, local: false}} = Transmogrifier.handle_incoming(undo_data)

    assert undo_data["type"] == "Undo"
    assert undo_data["object"] == data["id"]
    refute Activity.get_by_ap_id(data["id"])
    assert User.blocks?(moderator, banned)
  end
end
