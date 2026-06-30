# Pleroma: A lightweight social networking server
# Copyright Ãƒâ€šÃ‚Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.LikeHandlingTest do
  use Pleroma.DataCase, async: true

  require Pleroma.Constants

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  test "it works for incoming likes" do
    user = insert(:user)

    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    data =
      File.read!("test/fixtures/mastodon-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _actor = insert(:user, ap_id: data["actor"], local: false)

    {:ok, %Activity{data: data, local: false} = activity} = Transmogrifier.handle_incoming(data)

    refute Enum.empty?(activity.recipients)

    assert data["actor"] == "http://mastodon.example.org/users/admin"
    assert data["type"] == "Like"
    assert data["id"] == "http://mastodon.example.org/users/admin#likes/2"
    assert data["object"] == activity.data["object"]
  end

  @tag capture_log: true
  test "it rejects malformed incoming likes without raising" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://malformed-like.example/users/alice",
        follower_address: "https://malformed-like.example/users/alice/followers"
      )

    data = %{
      "id" => "https://malformed-like.example/activities/like/1",
      "actor" => actor.ap_id,
      "object" => %{"type" => "Note", "content" => "missing id"},
      "published" => "2026-06-29T00:00:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [],
      "type" => "Like"
    }

    assert {:error, _} = Transmogrifier.handle_incoming(data)
  end

  test "it hydrates an unknown reply thread before applying a late remote like" do
    author =
      insert(:user,
        local: false,
        ap_id: "https://mbin.example/u/author",
        follower_address: "https://mbin.example/u/author/followers"
      )

    liker =
      insert(:user,
        local: false,
        ap_id: "https://mbin.example/u/liker",
        follower_address: "https://mbin.example/u/liker/followers"
      )

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://mbin.example/m/main",
        follower_address: "https://mbin.example/m/main/followers"
      )

    root_url = "https://mbin.example/m/main/p/1"
    reply_url = "https://mbin.example/m/main/p/1/comment/2"

    root = %{
      "id" => root_url,
      "type" => "Page",
      "actor" => author.ap_id,
      "attributedTo" => author.ap_id,
      "audience" => group.ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.ap_id],
      "context" => root_url,
      "name" => "Mbin root thread",
      "content" => "<p>Mbin root thread</p>",
      "published" => "2026-06-24T00:00:00Z"
    }

    reply = %{
      "id" => reply_url,
      "type" => "Note",
      "actor" => author.ap_id,
      "attributedTo" => author.ap_id,
      "audience" => group.ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.ap_id],
      "context" => root_url,
      "content" => "<p>Mbin reply</p>",
      "inReplyTo" => root_url,
      "published" => "2026-06-24T00:01:00Z"
    }

    Tesla.Mock.mock(fn
      %{method: :get, url: ^root_url} ->
        %Tesla.Env{
          status: 200,
          body: Jason.encode!(root),
          headers: HttpRequestMock.activitypub_object_headers()
        }

      %{method: :get, url: ^reply_url} ->
        %Tesla.Env{
          status: 200,
          body: Jason.encode!(reply),
          headers: HttpRequestMock.activitypub_object_headers()
        }
    end)

    like = %{
      "id" => "https://mbin.example/activities/like/1",
      "actor" => liker.ap_id,
      "object" => reply_url,
      "published" => "2026-06-24T00:02:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "type" => "Like"
    }

    assert {:ok, %Activity{data: %{"type" => "Like"} = data, recipients: recipients}} =
             Transmogrifier.handle_incoming(like)

    assert data["object"] == reply_url
    assert data["audience"] == [group.ap_id]
    assert group.ap_id in recipients

    assert %Object{} = Object.get_by_ap_id(root_url)

    assert %Object{data: %{"inReplyTo" => ^root_url, "like_count" => 1}} =
             Object.get_by_ap_id(reply_url)

    assert %Activity{} = Activity.get_create_by_object_ap_id(root_url)
    assert %Activity{} = Activity.get_create_by_object_ap_id(reply_url)
  end

  test "it works for incoming misskey likes, turning them into EmojiReacts" do
    user = insert(:user)

    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    data =
      File.read!("test/fixtures/misskey-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _actor = insert(:user, ap_id: data["actor"], local: false)

    {:ok, %Activity{data: activity_data, local: false}} = Transmogrifier.handle_incoming(data)

    assert activity_data["actor"] == data["actor"]
    assert activity_data["type"] == "EmojiReact"
    assert activity_data["id"] == data["id"]
    assert activity_data["object"] == activity.data["object"]
    assert activity_data["content"] == List.to_string([0x1F36E])
  end

  test "it works for incoming misskey likes that contain unicode emojis, turning them into EmojiReacts" do
    user = insert(:user)
    star = [0x2B50] |> List.to_string()

    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    data =
      File.read!("test/fixtures/misskey-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("_misskey_reaction", star)

    _actor = insert(:user, ap_id: data["actor"], local: false)

    {:ok, %Activity{data: activity_data, local: false}} = Transmogrifier.handle_incoming(data)

    assert activity_data["actor"] == data["actor"]
    assert activity_data["type"] == "EmojiReact"
    assert activity_data["id"] == data["id"]
    assert activity_data["object"] == activity.data["object"]
    assert activity_data["content"] == star
  end

  test "it accepts misskey-style Like reactions with emoji in content" do
    user = insert(:user)
    star = [0x2B50] |> List.to_string()

    {:ok, activity} = CommonAPI.post(user, %{status: "hello"})

    data =
      File.read!("test/fixtures/misskey-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.delete("_misskey_reaction")
      |> Map.put("content", star)

    _actor = insert(:user, ap_id: data["actor"], local: false)

    {:ok, %Activity{data: activity_data, local: false}} = Transmogrifier.handle_incoming(data)

    assert activity_data["actor"] == data["actor"]
    assert activity_data["type"] == "EmojiReact"
    assert activity_data["id"] == data["id"]
    assert activity_data["object"] == activity.data["object"]
    assert activity_data["content"] == star
  end
end
