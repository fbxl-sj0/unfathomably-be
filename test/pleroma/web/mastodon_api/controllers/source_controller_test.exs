# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.SourceControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.User

  import Pleroma.Factory

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "GET /api/v1/sources" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "lists followed non-group ActivityPub actors", %{conn: conn, user: user} do
      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "writer@example.org",
          ap_id: "https://example.org/users/writer",
          name: "Writer"
        )

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "writers@lotide.example",
          ap_id: "https://lotide.example/c/writers"
        )

      {:ok, _, _} = User.follow(user, source)
      {:ok, _, _} = User.follow(user, group)

      source_id = to_string(source.id)

      assert [
               %{
                 "id" => ^source_id,
                 "display_name" => "Writer",
                 "source_profile" => "activitypub_profile",
                 "relationship" => %{"following" => true}
               }
             ] =
               conn
               |> get("/api/v1/sources")
               |> json_response(200)
    end

    test "searches known sources without returning groups", %{conn: conn} do
      source =
        insert(:user,
          actor_type: "Application",
          local: false,
          nickname: "blog@example.org",
          ap_id: "https://example.org/wp-json/pterotype/v1/actor/-blog",
          name: "Example Blog"
        )

      insert(:user,
        actor_type: "Group",
        local: false,
        nickname: "blog@lotide.example",
        ap_id: "https://lotide.example/c/blog"
      )

      source_id = to_string(source.id)

      assert [%{"id" => ^source_id, "source_profile" => "blog_publisher"}] =
               conn
               |> get("/api/v1/sources?q=blog")
               |> json_response(200)
    end

    test "search endpoint uses the same source representation", %{conn: conn} do
      source =
        insert(:user,
          actor_type: "Application",
          local: false,
          nickname: "library@example.org",
          ap_id: "https://audio.example.org/federation/music/libraries/everyone",
          name: "Everyone's Music"
        )

      source_id = to_string(source.id)

      assert [
               %{
                 "id" => ^source_id,
                 "display_name" => "Everyone's Music",
                 "source_profile" => "library",
                 "relationship" => %{"following" => false}
               }
             ] =
               conn
               |> get("/api/v1/sources/search?q=library")
               |> json_response(200)
    end
  end

  describe "POST /api/v1/sources/:id/follow" do
    setup do: oauth_access(["follow", "write:follows", "read:follows"])

    test "follows and unfollows a source through CommonAPI follow state", %{conn: conn} do
      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "local-source",
          ap_id: "http://mastodon.example.org/users/local-source",
          inbox: "http://mastodon.example.org/inbox"
        )

      source_id = to_string(source.id)

      assert %{"id" => ^source_id, "following" => false, "requested" => true} =
               conn
               |> post("/api/v1/sources/#{source.id}/follow")
               |> json_response(200)

      assert %{"id" => ^source_id, "following" => false, "requested" => false} =
               conn
               |> post("/api/v1/sources/#{source.id}/unfollow")
               |> json_response(200)
    end
  end

  describe "GET /api/v1/timelines/sources" do
    setup do: oauth_access(["read:statuses"])

    test "returns root posts from followed sources", %{conn: conn, user: user} do
      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "writer@example.org",
          ap_id: "https://example.org/users/writer"
        )

      unfollowed_source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "other@example.org",
          ap_id: "https://example.org/users/other"
        )

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "videos@example.org",
          ap_id: "https://example.org/c/videos"
        )

      {:ok, _, _} = Pleroma.FollowingRelationship.follow(user, source, :follow_accept)
      {:ok, _, _} = Pleroma.FollowingRelationship.follow(user, group, :follow_accept)

      context = "https://example.org/posts/1"

      root =
        insert(:note,
          user: source,
          data: %{
            "content" => "<p>A followed source root.</p>",
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), source.ap_id]
          }
        )

      followed_activity =
        insert(:note_activity,
          user: source,
          note: root,
          local: false,
          data_attrs: %{
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), source.ap_id]
          }
        )

      reply =
        insert(:note,
          user: source,
          data: %{
            "content" => "<p>A followed source reply.</p>",
            "context" => context,
            "inReplyTo" => root.data["id"],
            "to" => [Pleroma.Constants.as_public(), source.ap_id]
          }
        )

      _reply_activity =
        insert(:note_activity,
          user: source,
          note: reply,
          local: false,
          data_attrs: %{
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), source.ap_id]
          }
        )

      other_root =
        insert(:note,
          user: unfollowed_source,
          data: %{
            "content" => "<p>An unfollowed source root.</p>",
            "to" => [Pleroma.Constants.as_public(), unfollowed_source.ap_id]
          }
        )

      _unfollowed_activity =
        insert(:note_activity,
          user: unfollowed_source,
          note: other_root,
          local: false,
          data_attrs: %{"to" => [Pleroma.Constants.as_public(), unfollowed_source.ap_id]}
        )

      group_root =
        insert(:note,
          user: group,
          data: %{
            "content" => "<p>A followed group root.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      _group_activity =
        insert(:note_activity,
          user: group,
          note: group_root,
          local: false,
          data_attrs: %{"to" => [Pleroma.Constants.as_public(), group.ap_id]}
        )

      assert [
               %{
                 "id" => followed_activity_id,
                 "content" => content
               }
             ] =
               conn
               |> get("/api/v1/timelines/sources")
               |> json_response(200)

      assert followed_activity_id == to_string(followed_activity.id)
      assert content =~ "A followed source root"
    end
  end
end
