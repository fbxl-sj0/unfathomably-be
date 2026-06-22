# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.GroupPreviewControllerTest do
  use Pleroma.Web.ConnCase

  import Pleroma.Factory

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "GET /api/v1/groups/:id/preview" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "renders native items from a remote group outbox", %{conn: conn} do
      group_url = "https://lotide.example.org/c/general"
      outbox_url = "https://lotide.example.org/c/general/outbox"
      page_url = "https://lotide.example.org/c/general/outbox?page=1"
      post_url = "https://lotide.example.org/posts/1"

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "general@lotide.example.org",
          ap_id: group_url,
          name: "General"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^group_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => group_url,
                "type" => "Group",
                "name" => "General",
                "outbox" => outbox_url
              })
          }

        %{method: :get, url: ^outbox_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => outbox_url,
                "type" => "OrderedCollection",
                "totalItems" => 1,
                "first" => page_url
              })
          }

        %{method: :get, url: ^page_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => page_url,
                "type" => "OrderedCollectionPage",
                "orderedItems" => [
                  %{
                    "id" => "https://lotide.example.org/activities/1",
                    "type" => "Create",
                    "actor" => "https://lotide.example.org/users/alice",
                    "published" => "2026-06-20T00:00:00Z",
                    "object" => %{
                      "id" => post_url,
                      "type" => "Article",
                      "name" => "A useful community post",
                      "content" => "<p>This should show a meaningful body preview.</p>",
                      "url" => post_url
                    }
                  }
                ]
              })
          }
      end)

      assert %{
               "total_items" => 1,
               "items" => [
                 %{
                   "id" => ^post_url,
                   "type" => "Article",
                   "title" => "A useful community post",
                   "summary" => "This should show a meaningful body preview.",
                   "url" => ^post_url,
                   "platform_family" => "longform",
                   "source_kind_label" => "Group",
                   "capabilities" => ["follow community", "read posts", "send replies"],
                   "render_hint" => %{
                     "layout" => "article",
                     "primary_action" => "read"
                   },
                   "published" => "2026-06-20T00:00:00Z"
                 }
               ]
             } =
               conn
               |> get("/api/v1/groups/#{group.id}/preview")
               |> json_response(200)
    end

    test "returns 404 when the group does not exist", %{conn: conn} do
      assert %{"error" => "Record not found"} =
               conn
               |> get("/api/v1/groups/404404/preview")
               |> json_response(404)
    end
  end

  describe "public group reads" do
    test "allow lookup, empty timeline, and preview without an OAuth token", %{conn: conn} do
      group_url = "https://lotide.example.org/c/general"
      outbox_url = "https://lotide.example.org/c/general/outbox"

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "general@lotide.example.org",
          ap_id: group_url,
          name: "General"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^group_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => group_url,
                "type" => "Group",
                "name" => "General",
                "outbox" => outbox_url
              })
          }

        %{method: :get, url: ^outbox_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => outbox_url,
                "type" => "OrderedCollection",
                "orderedItems" => [
                  %{
                    "id" => "https://lotide.example.org/posts/1",
                    "type" => "Note",
                    "name" => "Public preview item",
                    "content" => "<p>Visible before login.</p>"
                  }
                ]
              })
          }
      end)

      assert %{
               "id" => group_id,
               "display_name" => "General",
               "relationship" => %{"member" => false}
             } =
               conn
               |> get("/api/v1/groups/lookup?name=#{group.id}")
               |> json_response(200)

      assert group_id == to_string(group.id)

      assert [] =
               conn
               |> get("/api/v1/timelines/group/#{group.id}")
               |> json_response(200)

      assert %{
               "items" => [
                 %{
                   "title" => "Public preview item",
                   "summary" => "Visible before login."
                 }
               ]
             } =
               conn
               |> get("/api/v1/groups/#{group.id}/preview?limit=1")
               |> json_response(200)
    end
  end
end
