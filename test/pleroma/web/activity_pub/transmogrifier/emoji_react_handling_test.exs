# Pleroma: A lightweight social networking server
# Copyright Ãƒâ€šÃ‚Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.EmojiReactHandlingTest do
  use Pleroma.DataCase, async: true

  require Pleroma.Constants

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  test "it works for incoming emoji reactions" do
    user = insert(:user)
    other_user = insert(:user, local: false)
    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    data =
      File.read!("test/fixtures/emoji-reaction.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", other_user.ap_id)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == other_user.ap_id
    assert data["type"] == "EmojiReact"
    assert data["id"] == "http://mastodon.example.org/users/admin#reactions/2"
    assert data["object"] == activity.data["object"]
    emoji = List.to_string([0x1F44C])
    assert data["content"] == emoji

    object = Object.get_by_ap_id(data["object"])

    assert object.data["reaction_count"] == 1
    assert [[^emoji, _, nil]] = object.data["reactions"]
  end

  @tag capture_log: true
  test "it rejects malformed incoming emoji reactions without raising" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://malformed-react.example/users/alice",
        follower_address: "https://malformed-react.example/users/alice/followers"
      )

    data = %{
      "id" => "https://malformed-react.example/activities/react/1",
      "actor" => actor.ap_id,
      "content" => [0x1F44D] |> List.to_string(),
      "object" => %{"type" => "Note", "content" => "missing id"},
      "published" => "2026-06-29T00:00:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [],
      "type" => "EmojiReact"
    }

    assert {:error, _} = Transmogrifier.handle_incoming(data)
  end

  test "it rewrites incoming Dislike activities into thumbs-down reactions" do
    user = insert(:user)
    other_user = insert(:user, local: false)
    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    thumbs_down = [0x1F44E] |> List.to_string()

    data = %{
      "id" => "https://mbin.example/activities/dislike/1",
      "actor" => other_user.ap_id,
      "object" => activity.data["object"],
      "published" => "2026-06-24T00:00:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [other_user.follower_address],
      "type" => "Dislike"
    }

    assert {:ok, %Activity{data: activity_data, local: false}} =
             Transmogrifier.handle_incoming(data)

    assert activity_data["actor"] == other_user.ap_id
    assert activity_data["type"] == "EmojiReact"
    assert activity_data["id"] == data["id"]
    assert activity_data["object"] == activity.data["object"]
    assert activity_data["content"] == thumbs_down

    object = Object.get_by_ap_id(activity.data["object"])

    assert object.data["reaction_count"] == 1
    assert match?([[^thumbs_down, _, nil]], object.data["reactions"])
  end

  test "it unwraps Mbin group announces around Dislike activities" do
    user = insert(:user)
    other_user = insert(:user, local: false)

    group =
      insert(:user,
        actor_type: "Group",
        local: false,
        ap_id: "https://mbin.example/m/main",
        follower_address: "https://mbin.example/m/main/followers"
      )

    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    thumbs_down = [0x1F44E] |> List.to_string()

    dislike = %{
      "id" => "https://mbin.example/activities/dislike/2",
      "actor" => other_user.ap_id,
      "object" => activity.data["object"],
      "published" => "2026-06-24T00:00:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "audience" => group.ap_id,
      "type" => "Dislike"
    }

    announce = %{
      "id" => "https://mbin.example/activities/announce/dislike/2",
      "actor" => group.ap_id,
      "object" => dislike,
      "published" => "2026-06-24T00:00:01Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "type" => "Announce"
    }

    assert {:ok, %Activity{data: activity_data, local: false}} =
             Transmogrifier.handle_incoming(announce)

    assert activity_data["actor"] == other_user.ap_id
    assert activity_data["type"] == "EmojiReact"
    assert activity_data["id"] == dislike["id"]
    assert activity_data["content"] == thumbs_down
    assert activity_data["audience"] == [group.ap_id]
  end

  test "it unwraps group announces around EmojiReact activities" do
    user = insert(:user)
    other_user = insert(:user, local: false)

    group =
      insert(:user,
        actor_type: "Group",
        local: false,
        ap_id: "https://mbin.example/m/main",
        follower_address: "https://mbin.example/m/main/followers"
      )

    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})
    thumbs_up = [0x1F44D] |> List.to_string()

    reaction = %{
      "id" => "https://mbin.example/activities/react/1",
      "actor" => other_user.ap_id,
      "content" => thumbs_up,
      "object" => activity.data["object"],
      "published" => "2026-06-29T00:00:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "audience" => group.ap_id,
      "type" => "EmojiReact"
    }

    announce = %{
      "id" => "https://mbin.example/activities/announce/react/1",
      "actor" => group.ap_id,
      "object" => reaction,
      "published" => "2026-06-29T00:00:01Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "type" => "Announce"
    }

    assert {:ok, %Activity{data: activity_data, local: false}} =
             Transmogrifier.handle_incoming(announce)

    assert activity_data["actor"] == other_user.ap_id
    assert activity_data["type"] == "EmojiReact"
    assert activity_data["id"] == reaction["id"]
    assert activity_data["content"] == thumbs_up
    assert activity_data["audience"] == [group.ap_id]

    object = Object.get_by_ap_id(activity.data["object"])

    assert object.data["reaction_count"] == 1
    assert match?([[^thumbs_up, _, nil]], object.data["reactions"])
  end

  test "it rewrites incoming Undo Dislike activities into Undo EmojiReact" do
    user = insert(:user)
    other_user = insert(:user, local: false)
    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    thumbs_down = [0x1F44E] |> List.to_string()

    dislike = %{
      "id" => "https://mbin.example/activities/dislike/3",
      "actor" => other_user.ap_id,
      "object" => activity.data["object"],
      "published" => "2026-06-24T00:00:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [other_user.follower_address],
      "type" => "Dislike"
    }

    assert {:ok, %Activity{data: %{"type" => "EmojiReact"}}} =
             Transmogrifier.handle_incoming(dislike)

    undo = %{
      "id" => "https://mbin.example/activities/undo/dislike/3",
      "actor" => other_user.ap_id,
      "object" => Map.delete(dislike, "id"),
      "published" => "2026-06-24T00:01:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [other_user.follower_address],
      "type" => "Undo"
    }

    assert {:ok, %Activity{data: undo_data, local: false}} =
             Transmogrifier.handle_incoming(undo)

    assert undo_data["type"] == "Undo"
    assert undo_data["object"] == dislike["id"]

    object = Object.get_by_ap_id(activity.data["object"])

    assert object.data["reaction_count"] == 0
    refute Enum.any?(object.data["reactions"], fn [emoji | _] -> emoji == thumbs_down end)
  end

  test "it sends local downvotes as Dislike and embeds Dislike in their Undo" do
    author = insert(:user)
    voter = insert(:user)
    {:ok, post} = CommonAPI.post(author, %{status: "hello"})

    assert {:ok, %Activity{} = dislike} = CommonAPI.dislike(post.id, voter)
    assert dislike.data["type"] == "EmojiReact"
    assert dislike.data["content"] == "👎"
    assert dislike.data["_pleroma_reaction_type"] == "Dislike"

    assert {:ok, outgoing} = Transmogrifier.prepare_outgoing(dislike.data)
    assert outgoing["type"] == "Dislike"
    refute Map.has_key?(outgoing, "content")
    refute Map.has_key?(outgoing, "_misskey_reaction")
    refute Map.has_key?(outgoing, "_pleroma_reaction_type")

    {:ok, undo_data, _meta} = Pleroma.Web.ActivityPub.Builder.undo(voter, dislike)
    assert {:ok, outgoing_undo} = Transmogrifier.prepare_outgoing(undo_data)
    assert outgoing_undo["type"] == "Undo"
    assert outgoing_undo["object"]["type"] == "Dislike"
    refute Map.has_key?(outgoing_undo["object"], "content")

    assert {:ok, %Activity{data: %{"type" => "Undo"}}} = CommonAPI.undislike(post.id, voter)
    object = Object.get_by_ap_id(post.data["object"])
    assert object.data["reaction_count"] == 0
  end

  test "it works for incoming custom emoji reactions" do
    user = insert(:user)
    other_user = insert(:user, local: false)
    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    data =
      File.read!("test/fixtures/custom-emoji-reaction.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", other_user.ap_id)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == other_user.ap_id
    assert data["type"] == "EmojiReact"
    assert data["id"] == "https://misskey.local.live/likes/917ocsybgp"
    assert data["object"] == activity.data["object"]
    assert data["content"] == ":hanapog:"

    assert data["tag"] == [
             %{
               "id" => "https://misskey.local.live/emojis/hanapog",
               "type" => "Emoji",
               "name" => "hanapog",
               "updated" => "2022-06-07T12:00:05.773Z",
               "icon" => %{
                 "type" => "Image",
                 "url" =>
                   "https://misskey.local.live/files/webpublic-8f8a9768-7264-4171-88d6-2356aabeadcd"
               }
             }
           ]

    object = Object.get_by_ap_id(data["object"])

    assert object.data["reaction_count"] == 1

    assert match?(
             [
               [
                 "hanapog",
                 _,
                 "https://misskey.local.live/files/webpublic-8f8a9768-7264-4171-88d6-2356aabeadcd"
               ]
             ],
             object.data["reactions"]
           )
  end

  test "it works for incoming unqualified emoji reactions" do
    user = insert(:user)
    other_user = insert(:user, local: false)
    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    # woman detective emoji, unqualified
    unqualified_emoji = [0x1F575, 0x200D, 0x2640] |> List.to_string()

    data =
      File.read!("test/fixtures/emoji-reaction.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", other_user.ap_id)
      |> Map.put("content", unqualified_emoji)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == other_user.ap_id
    assert data["type"] == "EmojiReact"
    assert data["id"] == "http://mastodon.example.org/users/admin#reactions/2"
    assert data["object"] == activity.data["object"]
    # woman detective emoji, fully qualified
    emoji = [0x1F575, 0xFE0F, 0x200D, 0x2640, 0xFE0F] |> List.to_string()
    assert data["content"] == emoji

    object = Object.get_by_ap_id(data["object"])

    assert object.data["reaction_count"] == 1
    assert match?([[^emoji, _, _]], object.data["reactions"])
  end

  test "it reject invalid emoji reactions" do
    user = insert(:user)
    other_user = insert(:user, local: false)
    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    data =
      File.read!("test/fixtures/emoji-reaction-too-long.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", other_user.ap_id)

    assert {:error, _} = Transmogrifier.handle_incoming(data)

    data =
      File.read!("test/fixtures/emoji-reaction-no-emoji.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", other_user.ap_id)

    assert {:error, _} = Transmogrifier.handle_incoming(data)
  end
end
