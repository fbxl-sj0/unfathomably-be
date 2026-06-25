# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.SourceItemsControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Instances

  require Pleroma.Constants

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
                        "mimeType" => "audio/ogg",
                        "href" => media_url,
                        "bitrate" => 192_000,
                        "size" => "3456789"
                      }
                    ],
                    "duration" => "PT3M27S",
                    "license" => "https://creativecommons.org/licenses/by-sa/4.0/",
                    "track" => %{
                      "name" => "Atacameo (Trote)",
                      "musicbrainzId" => "11111111-1111-1111-1111-111111111111",
                      "artist_credit" => [
                        %{
                          "credit" => "Los Jaivas",
                          "artist" => %{
                            "name" => "Los Jaivas"
                          }
                        }
                      ],
                      "album" => %{
                        "id" => "https://audio.example.org/federation/music/albums/1",
                        "name" => "Alturas",
                        "image" => %{
                          "url" => "https://audio.example.org/api/v1/albums/1/cover.jpg",
                          "mediaType" => "image/jpeg"
                        }
                      }
                    },
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
                   "thumbnail_url" => "https://audio.example.org/api/v1/albums/1/cover.jpg",
                   "duration" => "PT3M27S",
                   "media_bitrate" => 192_000,
                   "media_size" => 3_456_789,
                   "album" => "Alturas",
                   "album_url" => "https://audio.example.org/federation/music/albums/1",
                   "artists" => ["Los Jaivas"],
                   "license" => "https://creativecommons.org/licenses/by-sa/4.0/",
                   "musicbrainz_id" => "11111111-1111-1111-1111-111111111111",
                   "musicbrainz_url" =>
                     "https://musicbrainz.org/recording/11111111-1111-1111-1111-111111111111",
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

    test "renders RSS feed entries as native source items", %{conn: conn} do
      feed_url = "https://cms.example.org/fullrss2.xml"
      item_url = "https://cms.example.org/news/first-post"
      item_id = feed_url <> "#item-1"

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "rss-1111222233334444@cms.example.org",
          ap_id: feed_url,
          name: "ZeroHedge News"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^feed_url} ->
          %Tesla.Env{
            status: 200,
            body: rss_feed(feed_url, item_url)
          }
      end)

      assert %{
               "total_items" => 1,
               "next" => nil,
               "items" => [
                 %{
                   "id" => ^item_id,
                   "type" => "Article",
                   "title" => "First post",
                   "summary" => "A feed entry.",
                   "url" => ^item_url,
                   "published" => "2026-06-24T12:00:00Z",
                   "platform" => "rss",
                   "platform_label" => "RSS/Atom",
                   "platform_family" => "longform",
                   "platform_confidence" => "software",
                   "source_kind" => "rss_feed",
                   "source_kind_label" => "RSS feed",
                   "capabilities" => ["follow feed", "read items", "share links"],
                   "render_hint" => %{
                     "layout" => "article",
                     "primary_action" => "read"
                   },
                   "status" => %{
                     "id" => status_id,
                     "content" => status_content,
                     "account" => %{
                       "acct" => "rss-1111222233334444@cms.example.org"
                     }
                   }
                 } = item
               ]
             } =
               conn
               |> get("/api/v1/sources/#{source.id}/items")
               |> json_response(200)

      assert is_binary(status_id)
      assert status_content =~ "A feed entry."
      assert status_content =~ item_url
      assert Map.has_key?(item, "status")
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

    test "uses collection fetch fallback for protected outbox pages", %{conn: conn} do
      actor_url = "https://gts.example.org/users/source"
      outbox_url = "#{actor_url}/outbox"
      post_url = "#{actor_url}/statuses/1"

      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "source@gts.example.org",
          ap_id: actor_url,
          name: "Source"
        )

      clear_config([:activitypub, :sign_object_fetches], true)

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

        %{method: :get, url: ^outbox_url, headers: headers} ->
          if preview_collection_request?(headers) do
            %Tesla.Env{
              status: 401,
              body: Jason.encode!(%{"error" => "signed fetch required"})
            }
          else
            %Tesla.Env{
              status: 200,
              headers: [{"content-type", "application/activity+json"}],
              body:
                Jason.encode!(%{
                  "@context" => "https://www.w3.org/ns/activitystreams",
                  "type" => "OrderedCollectionPage",
                  "partOf" => outbox_url,
                  "orderedItems" => [
                    %{
                      "id" => post_url,
                      "type" => "Note",
                      "content" => "Collection pages should preview.",
                      "attributedTo" => actor_url,
                      "published" => "2026-06-24T00:00:00Z",
                      "to" => [Pleroma.Constants.as_public()]
                    }
                  ]
                })
            }
          end
      end)

      assert %{
               "items" => [
                 %{
                   "id" => ^post_url,
                   "platform" => "gotosocial",
                   "platform_label" => "GoToSocial",
                   "render_hint" => %{"layout" => "status"}
                 }
               ]
             } =
               conn
               |> get("/api/v1/sources/#{source.id}/items")
               |> json_response(200)
    end

    test "falls back to a cached actor card when a known profile source cannot be previewed", %{
      conn: conn
    } do
      actor_url = "https://gts.example.org/users/source"

      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "source@gts.example.org",
          ap_id: actor_url,
          uri: "https://gts.example.org/@source",
          name: "Source"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^actor_url} ->
          %Tesla.Env{
            status: 200,
            body: "not activitypub json"
          }
      end)

      assert %{
               "items" => [
                 %{
                   "id" => ^actor_url,
                   "title" => "Source",
                   "platform" => "gotosocial",
                   "platform_label" => "GoToSocial",
                   "preview_warning" => "Remote source returned a non-ActivityPub preview body."
                 }
               ]
             } =
               conn
               |> get("/api/v1/sources/#{source.id}/items")
               |> json_response(200)
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

      refute Instances.reachable?("broken.example.org")
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

  defp rss_feed(feed_url, item_url) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0">
      <channel>
        <title>ZeroHedge News</title>
        <description>News and market commentary.</description>
        <link>https://cms.example.org/</link>
        <item>
          <title>First post</title>
          <link>#{item_url}</link>
          <guid>#{feed_url}#item-1</guid>
          <description>&lt;p&gt;A feed entry.&lt;/p&gt;</description>
          <pubDate>Wed, 24 Jun 2026 12:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
    """
  end

  defp preview_collection_request?(headers) do
    Enum.any?(headers, fn
      {name, value} ->
        String.downcase(to_string(name)) == "accept" and
          String.contains?(to_string(value), "application/ld+json")

      _ ->
        false
    end)
  end
end
