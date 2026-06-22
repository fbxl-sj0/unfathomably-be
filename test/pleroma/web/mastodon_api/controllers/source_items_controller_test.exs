# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.SourceItemsControllerTest do
  use Pleroma.Web.ConnCase

  import Pleroma.Factory

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "GET /api/v1/sources/:id/items" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "renders native audio items from a remote library collection", %{conn: conn} do
      library_url = "https://audio.example.org/federation/music/libraries/everyone"
      page_url = "https://audio.example.org/federation/music/libraries/everyone?page=1"
      track_url = "https://audio.example.org/library/tracks/1"
      media_url = "https://audio.example.org/api/v1/listen/1.ogg"

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "collection@example.org",
          ap_id: library_url,
          name: "everyone"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^library_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => library_url,
                "type" => "Library",
                "name" => "everyone",
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
                "type" => "CollectionPage",
                "items" => [
                  %{
                    "id" => track_url,
                    "type" => "Audio",
                    "name" => "Atacameo (Trote)",
                    "summary" => "<p>A public library track.</p>",
                    "url" => [
                      %{
                        "type" => "Link",
                        "mediaType" => "text/html",
                        "href" => track_url
                      },
                      %{
                        "type" => "Link",
                        "mediaType" => "audio/ogg",
                        "href" => media_url
                      }
                    ],
                    "published" => "2026-06-19T00:00:00Z"
                  }
                ]
              })
          }
      end)

      assert %{
               "total_items" => 1,
               "items" => [
                 %{
                   "id" => ^track_url,
                   "type" => "Audio",
                   "title" => "Atacameo (Trote)",
                   "summary" => "A public library track.",
                   "url" => ^track_url,
                   "media_url" => ^media_url,
                   "media_type" => "audio/ogg",
                   "platform" => "funkwhale",
                   "platform_label" => "Funkwhale",
                   "platform_family" => "audio",
                   "platform_confidence" => "software",
                   "thumbnail_url" => nil,
                   "duration" => nil,
                   "event_start" => nil,
                   "location" => nil,
                   "source_kind" => "funkwhale_library",
                   "source_kind_label" => "Library",
                   "capabilities" => ["follow library", "preview tracks", "owner inbox"],
                   "render_hint" => %{
                     "layout" => "player",
                     "primary_action" => "play"
                   },
                   "published" => "2026-06-19T00:00:00Z"
                 }
               ]
             } =
               conn
               |> get("/api/v1/sources/#{source.id}/items")
               |> json_response(200)
    end

    test "returns 404 when the source does not exist", %{conn: conn} do
      assert %{"error" => "Record not found"} =
               conn
               |> get("/api/v1/sources/404404/items")
               |> json_response(404)
    end

    test "includes a normal status payload for cached profile posts", %{conn: conn} do
      actor_url = "https://microblog.example.org/users/source"
      outbox_url = "#{actor_url}/outbox"
      post_url = "#{actor_url}/statuses/1"

      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "source@microblog.example.org",
          ap_id: actor_url,
          name: "Source"
        )

      note =
        insert(:note,
          user: source,
          data: %{
            "id" => post_url,
            "content" => "This should render as an interactive status.",
            "source" => "This should render as an interactive status."
          }
        )

      activity = insert(:note_activity, user: source, note: note)

      Tesla.Mock.mock(fn
        %{method: :get, url: ^actor_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => actor_url,
                "type" => "Person",
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
                    "id" => post_url,
                    "type" => "Note",
                    "content" => "This should render as an interactive status.",
                    "attributedTo" => actor_url,
                    "published" => "2026-06-22T00:00:00Z"
                  }
                ]
              })
          }
      end)

      assert %{
               "items" => [
                 %{
                   "id" => ^post_url,
                   "render_hint" => %{"layout" => "status"},
                   "status" => %{
                     "id" => status_id,
                     "account" => %{"id" => account_id},
                     "content" => content
                   }
                 }
               ]
             } =
               conn
               |> get("/api/v1/sources/#{source.id}/items")
               |> json_response(200)

      assert status_id == to_string(activity.id)
      assert account_id == to_string(source.id)
      assert content =~ "interactive status"
    end

    test "returns 502 when the remote source returns invalid ActivityPub JSON", %{conn: conn} do
      source_url = "https://broken.example.org/outbox"

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "broken@example.org",
          ap_id: source_url,
          name: "Broken source"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^source_url} ->
          %Tesla.Env{
            status: 200,
            body: "not json"
          }
      end)

      assert %{"error" => "Remote source returned invalid ActivityPub JSON"} =
               conn
               |> get("/api/v1/sources/#{source.id}/items")
               |> json_response(502)
    end

    test "caps remote source preview titles and summaries", %{conn: conn} do
      collection_url = "https://large.example.org/outbox"
      long_title = String.duplicate("Title ", 80)
      long_summary = "<p>" <> String.duplicate("Summary ", 220) <> "</p>"

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "large@example.org",
          ap_id: collection_url,
          name: "large"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^collection_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => collection_url,
                "type" => "Collection",
                "items" => [
                  %{
                    "id" => "https://large.example.org/posts/1",
                    "type" => "Article",
                    "name" => long_title,
                    "content" => long_summary
                  }
                ]
              })
          }
      end)

      assert %{"items" => [%{"title" => title, "summary" => summary}]} =
               conn
               |> get("/api/v1/sources/#{source.id}/items")
               |> json_response(200)

      assert String.length(title) <= 243
      assert String.ends_with?(title, "...")
      assert String.length(summary) <= 1_003
      assert String.ends_with?(summary, "...")
    end

    test "renders native families from ActivityPub object types when source software is unknown",
         %{
           conn: conn
         } do
      collection_url = "https://unknown.example.org/outbox"

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "unknown@example.org",
          ap_id: collection_url,
          name: "unknown"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^collection_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => collection_url,
                "type" => "Collection",
                "totalItems" => 7,
                "items" => [
                  %{"id" => "https://unknown.example.org/articles/1", "type" => "Article"},
                  %{"id" => "https://unknown.example.org/notes/1", "type" => "Note"},
                  %{"id" => "https://unknown.example.org/photos/1", "type" => "Image"},
                  %{"id" => "https://unknown.example.org/videos/1", "type" => "Video"},
                  %{"id" => "https://unknown.example.org/events/1", "type" => "Event"},
                  %{"id" => "https://unknown.example.org/groups/1", "type" => "Group"},
                  %{"id" => "https://unknown.example.org/audio/1", "type" => "Audio"}
                ]
              })
          }
      end)

      assert %{
               "items" => items
             } =
               conn
               |> get("/api/v1/sources/#{source.id}/items")
               |> json_response(200)

      assert Enum.map(items, & &1["platform_family"]) == [
               "longform",
               "microblog",
               "photo",
               "video",
               "events",
               "groups",
               "audio"
             ]

      assert Enum.map(items, &get_in(&1, ["render_hint", "layout"])) == [
               "article",
               "status",
               "gallery",
               "player",
               "event",
               "community",
               "player"
             ]

      assert Enum.map(items, & &1["source_kind"]) == [
               "service",
               "service",
               "service",
               "service",
               "service",
               "service",
               "service"
             ]

      assert Enum.all?(items, &(&1["capabilities"] == ["follow", "preview"]))
    end
  end
end
