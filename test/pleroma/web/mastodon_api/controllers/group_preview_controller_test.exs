# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.GroupPreviewControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Instances

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
                      "url" => post_url,
                      "replies" => %{
                        "type" => "Collection",
                        "totalItems" => 3
                      }
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
                   "comments_count" => 3,
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

    test "renders locally-known group preview items as statuses with reply counts", %{
      conn: conn
    } do
      group_url = "https://peertube.example/video-channels/root42"
      outbox_url = "https://peertube.example/video-channels/root42/outbox"
      video_url = "https://peertube.example/videos/watch/1"
      comments_url = "https://peertube.example/videos/watch/1/comments"

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "root42@peertube.example",
          ap_id: group_url,
          name: "root42"
        )

      author =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "root_42@peertube.example",
          ap_id: "https://peertube.example/accounts/root_42",
          name: "root_42"
        )

      video =
        insert(:note,
          user: author,
          data: %{
            "id" => video_url,
            "type" => "Video",
            "actor" => author.ap_id,
            "attributedTo" => author.ap_id,
            "name" => "A cached channel video",
            "content" => "<p>This was imported before the channel preview.</p>",
            "comments" => comments_url
          }
        )

      activity = insert(:note_activity, user: author, note: video)

      Tesla.Mock.mock(fn
        %{method: :get, url: ^group_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => group_url,
                "type" => "Group",
                "name" => "root42",
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
                "orderedItems" => [
                  %{
                    "id" => video_url,
                    "type" => "Video",
                    "name" => "A cached channel video",
                    "content" => "<p>This was imported before the channel preview.</p>",
                    "comments" => comments_url
                  }
                ]
              })
          }

        %{method: :get, url: ^video_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => video_url,
                "type" => "Video",
                "actor" => author.ap_id,
                "attributedTo" => author.ap_id,
                "name" => "A cached channel video",
                "content" => "<p>This was imported before the channel preview.</p>",
                "comments" => comments_url
              })
          }

        %{method: :get, url: ^comments_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => comments_url,
                "type" => "OrderedCollection",
                "totalItems" => "2"
              })
          }
      end)

      assert %{
               "items" => [
                 %{
                   "id" => ^video_url,
                   "comments_count" => 2,
                   "status" => %{
                     "id" => status_id,
                     "replies_count" => 2
                   }
                 }
               ]
             } =
               conn
               |> get("/api/v1/groups/#{group.id}/preview")
               |> json_response(200)

      assert status_id == to_string(activity.id)
    end

    test "returns 404 when the group does not exist", %{conn: conn} do
      assert %{"error" => "Record not found"} =
               conn
               |> get("/api/v1/groups/404404/preview")
               |> json_response(404)
    end

    test "marks the host unreachable when the remote group returns invalid ActivityPub JSON", %{
      conn: conn
    } do
      group_url = "https://parked.example/video-channels/dead"

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "dead@parked.example",
          ap_id: group_url,
          name: "Dead channel"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^group_url} ->
          %Tesla.Env{
            status: 200,
            body: "<!DOCTYPE html><html><body>parked domain</body></html>"
          }
      end)

      assert %{"error" => "Remote group returned invalid ActivityPub JSON"} =
               conn
               |> get("/api/v1/groups/#{group.id}/preview")
               |> json_response(502)

      refute Instances.reachable?("parked.example")
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
