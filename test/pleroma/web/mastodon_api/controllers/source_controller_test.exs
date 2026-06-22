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
end
