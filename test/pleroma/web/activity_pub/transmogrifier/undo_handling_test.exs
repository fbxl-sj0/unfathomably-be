# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.UndoHandlingTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Activity
  alias Pleroma.GroupMembership
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI

  require Pleroma.Constants

  import Pleroma.Factory

  test "it works for incoming emoji reaction undos" do
    user = insert(:user)

    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})
    {:ok, reaction_activity} = CommonAPI.react_with_emoji(activity.id, user, "👌")

    data =
      File.read!("test/fixtures/mastodon-undo-like.json")
      |> Jason.decode!()
      |> Map.put("object", reaction_activity.data["id"])
      |> Map.put("actor", user.ap_id)

    {:ok, activity} = Transmogrifier.handle_incoming(data)

    assert activity.actor == user.ap_id
    assert activity.data["id"] == data["id"]
    assert activity.data["type"] == "Undo"
  end

  test "it ignores incoming unlikes without a like activity" do
    user = insert(:user)
    {:ok, activity} = CommonAPI.post(user, %{status: "leave a like pls"})

    data =
      File.read!("test/fixtures/mastodon-undo-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    assert {:ok, :ignored} = Transmogrifier.handle_incoming(data)
  end

  test "it ignores compact Undo activities for unknown remote activity ids" do
    data = %{
      "id" => "https://annihilation.social/activities/fb505108-5807-4305-a650-4bbe9424f594",
      "type" => "Undo",
      "actor" => "https://annihilation.social/users/amerika",
      "object" => "https://annihilation.social/activities/40e813bd-6788-4ce0-8f97-d8d2d896e67f",
      "to" => [
        "https://annihilation.social/users/amerika/followers",
        "https://social.linux.pizza/users/balasubramanium"
      ],
      "cc" => [Pleroma.Constants.as_public()]
    }

    assert {:ok, :ignored} = Transmogrifier.handle_incoming(data)
    refute Activity.get_by_ap_id(data["id"])
  end

  test "it works for incoming unlikes with an existing like activity" do
    user = insert(:user)
    {:ok, activity} = CommonAPI.post(user, %{status: "leave a like pls"})

    like_data =
      File.read!("test/fixtures/mastodon-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _liker = insert(:user, ap_id: like_data["actor"], local: false)

    {:ok, %Activity{data: like_data, local: false}} = Transmogrifier.handle_incoming(like_data)

    data =
      File.read!("test/fixtures/mastodon-undo-like.json")
      |> Jason.decode!()
      |> Map.put("object", like_data)
      |> Map.put("actor", like_data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == "http://mastodon.example.org/users/admin"
    assert data["type"] == "Undo"
    assert data["id"] == "http://mastodon.example.org/users/admin#likes/2/undo"
    assert data["object"] == "http://mastodon.example.org/users/admin#likes/2"

    note = Object.get_by_ap_id(like_data["object"])
    assert note.data["like_count"] == 0
    assert note.data["likes"] == []
  end

  test "it works for incoming unlikes when the nested like has a new id" do
    user = insert(:user)
    {:ok, activity} = CommonAPI.post(user, %{status: "leave a like pls"})

    like_data =
      File.read!("test/fixtures/mastodon-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _liker = insert(:user, ap_id: like_data["actor"], local: false)

    {:ok, %Activity{data: like_data, local: false}} = Transmogrifier.handle_incoming(like_data)

    nested_like =
      like_data
      |> Map.put("id", "http://mastodon.example.org/users/admin#likes/new-transient-id")

    data =
      File.read!("test/fixtures/mastodon-undo-like.json")
      |> Jason.decode!()
      |> Map.put("object", nested_like)
      |> Map.put("actor", like_data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Undo"
    assert data["object"] == "http://mastodon.example.org/users/admin#likes/2"

    note = Object.get_by_ap_id(like_data["object"])
    assert note.data["like_count"] == 0
    assert note.data["likes"] == []

    {:ok, %Activity{local: false}} = Transmogrifier.handle_incoming(like_data)

    note = Object.get_by_ap_id(like_data["object"])
    assert note.data["like_count"] == 0
    assert note.data["likes"] == []
    refute Activity.get_by_ap_id(like_data["id"])
  end

  test "it works for incoming unlikes with an existing like activity and a compact object" do
    user = insert(:user)
    {:ok, activity} = CommonAPI.post(user, %{status: "leave a like pls"})

    like_data =
      File.read!("test/fixtures/mastodon-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _liker = insert(:user, ap_id: like_data["actor"], local: false)

    {:ok, %Activity{data: like_data, local: false}} = Transmogrifier.handle_incoming(like_data)

    data =
      File.read!("test/fixtures/mastodon-undo-like.json")
      |> Jason.decode!()
      |> Map.put("object", like_data["id"])
      |> Map.put("actor", like_data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == "http://mastodon.example.org/users/admin"
    assert data["type"] == "Undo"
    assert data["id"] == "http://mastodon.example.org/users/admin#likes/2/undo"
    assert data["object"] == "http://mastodon.example.org/users/admin#likes/2"
  end

  test "it works for incoming unannounces with an existing notice" do
    user = insert(:user)
    {:ok, activity} = CommonAPI.post(user, %{status: "hey"})

    announce_data =
      File.read!("test/fixtures/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _announcer = insert(:user, ap_id: announce_data["actor"], local: false)

    {:ok, %Activity{data: announce_data, local: false}} =
      Transmogrifier.handle_incoming(announce_data)

    data =
      File.read!("test/fixtures/mastodon-undo-announce.json")
      |> Jason.decode!()
      |> Map.put("object", announce_data)
      |> Map.put("actor", announce_data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Undo"

    assert data["object"] ==
             "http://mastodon.example.org/users/admin/statuses/99542391527669785/activity"
  end

  test "it works for incoming unfollows with an existing follow" do
    user = insert(:user)

    follow_data =
      File.read!("test/fixtures/mastodon-follow-activity.json")
      |> Jason.decode!()
      |> Map.put("object", user.ap_id)

    _follower = insert(:user, ap_id: follow_data["actor"], local: false)

    {:ok, %Activity{data: _, local: false}} = Transmogrifier.handle_incoming(follow_data)

    data =
      File.read!("test/fixtures/mastodon-unfollow-activity.json")
      |> Jason.decode!()
      |> Map.put("object", follow_data)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Undo"
    assert data["object"]["type"] == "Follow"
    assert data["object"]["object"] == user.ap_id
    assert data["actor"] == "http://mastodon.example.org/users/admin"

    refute User.following?(User.get_cached_by_ap_id(data["actor"]), user)
  end

  test "an incoming group unfollow removes the mirrored membership" do
    group = insert(:user, actor_type: "Group", local: true)

    follow_data =
      File.read!("test/fixtures/mastodon-follow-activity.json")
      |> Jason.decode!()
      |> Map.put("object", group.ap_id)

    follower = insert(:user, ap_id: follow_data["actor"], local: false)

    {:ok, %Activity{local: false}} = Transmogrifier.handle_incoming(follow_data)
    assert %GroupMembership{state: "active"} = GroupMembership.get(group, follower)

    undo_data =
      File.read!("test/fixtures/mastodon-unfollow-activity.json")
      |> Jason.decode!()
      |> Map.put("object", follow_data)

    assert {:ok, %Activity{data: %{"type" => "Undo"}}} =
             Transmogrifier.handle_incoming(undo_data)

    refute GroupMembership.get(group, follower)
  end

  test "it works for incoming unblocks with an existing block" do
    user = insert(:user)

    block_data =
      File.read!("test/fixtures/mastodon-block-activity.json")
      |> Jason.decode!()
      |> Map.put("object", user.ap_id)

    _blocker = insert(:user, ap_id: block_data["actor"], local: false)

    {:ok, %Activity{data: _, local: false}} = Transmogrifier.handle_incoming(block_data)

    data =
      File.read!("test/fixtures/mastodon-unblock-activity.json")
      |> Jason.decode!()
      |> Map.put("object", block_data)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)
    assert data["type"] == "Undo"
    assert data["object"] == block_data["id"]

    blocker = User.get_cached_by_ap_id(data["actor"])

    refute User.blocks?(blocker, user)
  end
end
