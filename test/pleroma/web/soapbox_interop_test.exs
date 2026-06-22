# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.SoapboxInteropTest do
  use Pleroma.Web.ConnCase, async: true

  import Pleroma.Factory

  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  describe "Soapbox/Rebased HTTP contract" do
    test "supports list exclusivity in create, show, and home timeline filtering" do
      %{conn: conn, user: user} = oauth_access(["read:lists", "write:lists", "read:statuses"])
      hidden_author = insert(:user)
      visible_author = insert(:user)

      {:ok, user, hidden_author} = User.follow(user, hidden_author)
      {:ok, _user, visible_author} = User.follow(user, visible_author)

      list =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/lists", %{"title" => "Quiet", "exclusive" => true})
        |> json_response_and_validate_schema(200)

      assert %{"id" => list_id, "title" => "Quiet", "exclusive" => true} = list

      assert %{"exclusive" => true} =
               conn
               |> get("/api/v1/lists/#{list_id}")
               |> json_response_and_validate_schema(200)

      assert %{} =
               conn
               |> put_req_header("content-type", "application/json")
               |> post("/api/v1/lists/#{list_id}/accounts", %{
                 "account_ids" => [hidden_author.id]
               })
               |> json_response_and_validate_schema(200)

      {:ok, _hidden_activity} = CommonAPI.post(hidden_author, %{status: "hidden"})
      {:ok, %{id: visible_activity_id}} = CommonAPI.post(visible_author, %{status: "visible"})

      assert [%{"id" => ^visible_activity_id}] =
               conn
               |> get("/api/v1/timelines/home")
               |> json_response_and_validate_schema(200)
    end

    test "supports bookmark folders and folder-filtered bookmarks" do
      %{conn: conn} = oauth_access(["read:bookmarks", "write:bookmarks"])
      author = insert(:user)
      {:ok, activity} = CommonAPI.post(author, %{status: "save this"})

      folder =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/pleroma/bookmark_folders", %{name: "Read later", emoji: nil})
        |> json_response_and_validate_schema(200)

      assert %{
               "id" => folder_id,
               "name" => "Read later",
               "emoji" => nil,
               "emoji_url" => nil
             } = folder

      status =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/statuses/#{activity.id}/bookmark", %{folder_id: folder_id})
        |> json_response_and_validate_schema(200)

      assert status["bookmarked"] == true
      assert status["pleroma"]["bookmark_folder"] == folder_id

      assert [%{"id" => id, "pleroma" => %{"bookmark_folder" => ^folder_id}}] =
               conn
               |> get("/api/v1/bookmarks?folder_id=#{folder_id}")
               |> json_response_and_validate_schema(200)

      assert id == status["id"]
    end

    test "exposes grouped notification endpoints with Mastodon-compatible paths" do
      %{conn: conn} = oauth_access(["read:notifications"])

      assert %{"accounts" => [], "notification_groups" => [], "statuses" => []} =
               conn
               |> get("/api/v2/notifications")
               |> json_response_and_validate_schema(200)

      assert %{"count" => count} =
               conn
               |> get("/api/v2/notifications/unread_count")
               |> json_response_and_validate_schema(200)

      assert is_integer(count)
    end
  end
end
