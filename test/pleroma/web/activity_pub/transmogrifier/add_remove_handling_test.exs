# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.AddRemoveHandlingTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase, async: true

  require Pleroma.Constants

  import Pleroma.Factory

  alias Pleroma.GroupMembership
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI

  test "it accepts Add/Remove activities" do
    user =
      "test/fixtures/users_mock/user.json"
      |> File.read!()
      |> String.replace("{{nickname}}", "lain")

    object_id = "c61d6733-e256-4fe1-ab13-1e369789423f"

    object =
      "test/fixtures/statuses/note.json"
      |> File.read!()
      |> String.replace("{{nickname}}", "lain")
      |> String.replace("{{object_id}}", object_id)

    object_url = "https://example.com/objects/#{object_id}"

    actor = "https://example.com/users/lain"

    Tesla.Mock.mock(fn
      %{
        method: :get,
        url: ^actor
      } ->
        %Tesla.Env{
          status: 200,
          body: user,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{
        method: :get,
        url: ^object_url
      } ->
        %Tesla.Env{
          status: 200,
          body: object,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{method: :get, url: "https://example.com/users/lain/collections/featured"} ->
        %Tesla.Env{
          status: 200,
          body:
            "test/fixtures/users_mock/masto_featured.json"
            |> File.read!()
            |> String.replace("{{domain}}", "example.com")
            |> String.replace("{{nickname}}", "lain"),
          headers: [{"content-type", "application/activity+json"}]
        }
    end)

    message = %{
      "id" => "https://example.com/objects/d61d6733-e256-4fe1-ab13-1e369789423f",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://example.com/users/lain/collections/featured",
      "type" => "Add",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => ["https://example.com/users/lain/followers"],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(message)
    assert activity.data == message
    user = User.get_cached_by_ap_id(actor)
    assert user.pinned_objects[object_url]

    remove = %{
      "id" => "http://localhost:400/objects/d61d6733-e256-4fe1-ab13-1e369789423d",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://example.com/users/lain/collections/featured",
      "type" => "Remove",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => ["https://example.com/users/lain/followers"],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(remove)
    assert activity.data == remove

    user = refresh_record(user)
    refute user.pinned_objects[object_url]
  end

  test "Add/Remove activities for remote users without featured address" do
    user = insert(:user, local: false, domain: "example.com")

    user =
      user
      |> Ecto.Changeset.change(featured_address: nil)
      |> Repo.update!()

    %{host: host} = URI.parse(user.ap_id)

    user_data =
      "test/fixtures/users_mock/user.json"
      |> File.read!()
      |> String.replace("{{nickname}}", user.nickname)

    object_id = "c61d6733-e256-4fe1-ab13-1e369789423f"

    object =
      "test/fixtures/statuses/note.json"
      |> File.read!()
      |> String.replace("{{nickname}}", user.nickname)
      |> String.replace("{{object_id}}", object_id)

    object_url = "https://#{host}/objects/#{object_id}"

    actor = "https://#{host}/users/#{user.nickname}"

    featured = "https://#{host}/users/#{user.nickname}/collections/featured"

    Tesla.Mock.mock(fn
      %{
        method: :get,
        url: ^actor
      } ->
        %Tesla.Env{
          status: 200,
          body: user_data,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{
        method: :get,
        url: ^object_url
      } ->
        %Tesla.Env{
          status: 200,
          body: object,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{method: :get, url: ^featured} ->
        %Tesla.Env{
          status: 200,
          body:
            "test/fixtures/users_mock/masto_featured.json"
            |> File.read!()
            |> String.replace("{{domain}}", "#{host}")
            |> String.replace("{{nickname}}", user.nickname),
          headers: [{"content-type", "application/activity+json"}]
        }
    end)

    message = %{
      "id" => "https://#{host}/objects/d61d6733-e256-4fe1-ab13-1e369789423f",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://#{host}/users/#{user.nickname}/collections/featured",
      "type" => "Add",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => ["https://#{host}/users/#{user.nickname}/followers"],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(message)
    assert activity.data == message
    user = User.get_cached_by_ap_id(actor)
    assert user.pinned_objects[object_url]
  end

  test "Mbin-style Add/Remove pins objects on the target group collection" do
    moderator =
      insert(:user,
        local: false,
        ap_id: "https://mbin.example/u/mod",
        follower_address: "https://mbin.example/u/mod/followers"
      )

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://mbin.example/m/main",
        follower_address: "https://mbin.example/m/main/followers",
        featured_address: "https://mbin.example/m/main/pinned",
        attributed_to_address: "https://mbin.example/m/main/moderators"
      )

    author = insert(:user)
    {:ok, post} = CommonAPI.post(author, %{status: "pin me for the magazine"})
    object_id = post.data["object"]

    add = %{
      "id" => "https://mbin.example/activities/add/pin/1",
      "actor" => moderator.ap_id,
      "object" => object_id,
      "target" => group.featured_address,
      "type" => "Add",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(add)
    assert activity.data == add

    group = User.get_cached_by_ap_id(group.ap_id)
    assert group.pinned_objects[object_id]

    remove = %{
      "id" => "https://mbin.example/activities/remove/pin/1",
      "actor" => moderator.ap_id,
      "object" => object_id,
      "target" => group.featured_address,
      "type" => "Remove",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(remove)
    assert activity.data == remove

    group = User.get_cached_by_ap_id(group.ap_id)
    refute group.pinned_objects[object_id]
  end

  test "Mbin-style moderator collection activities are accepted without granting local roles" do
    moderator =
      insert(:user,
        local: false,
        ap_id: "https://mbin.example/u/mod",
        follower_address: "https://mbin.example/u/mod/followers"
      )

    added = insert(:user, local: false, ap_id: "https://mbin.example/u/helper")

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://mbin.example/m/main",
        follower_address: "https://mbin.example/m/main/followers",
        featured_address: "https://mbin.example/m/main/pinned",
        attributed_to_address: "https://mbin.example/m/main/moderators"
      )

    add = %{
      "id" => "https://mbin.example/activities/add/mod/1",
      "actor" => moderator.ap_id,
      "object" => added.ap_id,
      "target" => group.attributed_to_address,
      "type" => "Add",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(add)
    assert activity.data == add

    group = User.get_cached_by_ap_id(group.ap_id)
    assert group.pinned_objects == %{}
  end

  test "Mbin-style moderator collection activities update local group moderators when authorized" do
    owner = insert(:user)
    added = insert(:user)

    group =
      insert(:user,
        local: true,
        actor_type: "Group",
        attributed_to_address: "https://#{Pleroma.Web.Endpoint.host()}/groups/modtest/moderators",
        featured_address: "https://#{Pleroma.Web.Endpoint.host()}/groups/modtest/pinned"
      )

    {:ok, _membership} = GroupMembership.ensure_owner(group, owner)

    add = %{
      "id" => "https://#{Pleroma.Web.Endpoint.host()}/activities/add/local-mod/1",
      "actor" => owner.ap_id,
      "object" => added.ap_id,
      "target" => group.attributed_to_address,
      "type" => "Add",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(add)
    assert activity.data == add
    assert GroupMembership.role(group, added) == "moderator"

    remove = %{
      "id" => "https://#{Pleroma.Web.Endpoint.host()}/activities/remove/local-mod/1",
      "actor" => owner.ap_id,
      "object" => added.ap_id,
      "target" => group.attributed_to_address,
      "type" => "Remove",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(remove)
    assert activity.data == remove
    assert GroupMembership.role(group, added) == "user"
  end

  test "Mbin-style moderator collection activities do not let unrelated local users manage a local group" do
    intruder = insert(:user)
    added = insert(:user)

    group =
      insert(:user,
        local: true,
        actor_type: "Group",
        attributed_to_address: "https://#{Pleroma.Web.Endpoint.host()}/groups/locked/moderators",
        featured_address: "https://#{Pleroma.Web.Endpoint.host()}/groups/locked/pinned"
      )

    add = %{
      "id" => "https://#{Pleroma.Web.Endpoint.host()}/activities/add/local-mod/2",
      "actor" => intruder.ap_id,
      "object" => added.ap_id,
      "target" => group.attributed_to_address,
      "type" => "Add",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(add)
    assert activity.data == add
    assert GroupMembership.role(group, added) == "user"
  end
end
