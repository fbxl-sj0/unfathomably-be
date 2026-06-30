# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.SourceControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Instances.Instance
  alias Pleroma.Repo
  alias Pleroma.User

  import Pleroma.Factory

  require Pleroma.Constants

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "GET /api/v1/sources and /api/v1/feeds" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "lists followed feed-like actors without returning groups or normal profiles", %{
      conn: conn,
      user: user
    } do
      source =
        insert(:user,
          actor_type: "Application",
          local: false,
          nickname: "library@audio.example.org",
          ap_id: "https://audio.example.org/federation/music/libraries/everyone",
          name: "Everyone's Music"
        )

      profile =
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
      {:ok, _, _} = User.follow(user, profile)
      {:ok, _, _} = User.follow(user, group)

      source_id = to_string(source.id)

      assert [
               %{
                 "id" => ^source_id,
                 "display_name" => "Everyone's Music",
                 "source_profile" => "library",
                 "relationship" => %{"following" => true}
               }
             ] =
               conn
               |> get("/api/v1/feeds")
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
               |> get("/api/v1/feeds?q=blog")
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
               |> get("/api/v1/feeds/search?q=library")
               |> json_response(200)
    end

    test "classifies common feed software from stable ActivityPub URL shapes", %{conn: conn} do
      cases = [
        {"https://longform.example.org/api/collections/notes", "Person", "writefreely",
         "WriteFreely"},
        {"https://wordpress.example.org/wp-json/activitypub/1.0/actors/1", "Application",
         "wordpress", "WordPress"},
        {"https://audio.example.org/federation/music/libraries/everyone", "Application",
         "funkwhale", "Funkwhale"},
        {"https://video.example.org/federation/user/streamer", "Service", "owncast", "Owncast"},
        {"https://books.bookwyrm.example.org/user/shelf", "Person", "bookwyrm", "BookWyrm"},
        {"https://pod.castopod.example.org/@news", "Service", "castopod", "Castopod"}
      ]

      for {ap_id, actor_type, platform, label} <- cases do
        source =
          insert(:user,
            actor_type: actor_type,
            local: false,
            nickname: "source-#{platform}@example.org",
            ap_id: ap_id,
            inbox: ap_id <> "/inbox",
            shared_inbox: "https://example.org/inbox",
            name: label
          )

        assert %{
                 "id" => source_id,
                 "platform" => ^platform,
                 "platform_label" => ^label
               } =
                 conn
                 |> get("/api/v1/sources/#{source.id}")
                 |> json_response(200)

        assert source_id == to_string(source.id)
      end
    end

    test "uses NodeInfo software before hostname platform guesses", %{conn: conn} do
      insert(:instance,
        host: "social.owncast.online",
        metadata: %Instance.Pleroma.Instances.Metadata{
          software_name: "mastodon",
          software_version: "4.5.11"
        }
      )

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "updates@social.owncast.online",
          ap_id: "https://social.owncast.online/users/updates",
          inbox: "https://social.owncast.online/users/updates/inbox",
          name: "Updates"
        )

      assert %{
               "platform" => "mastodon",
               "platform_label" => "Mastodon",
               "platform_family" => "microblog",
               "platform_confidence" => "software"
             } =
               conn
               |> get("/api/v1/sources/#{source.id}")
               |> json_response(200)
    end

    test "lists followed feed actors detected from NodeInfo metadata", %{conn: conn, user: user} do
      insert(:instance,
        host: "open.audio",
        metadata: %Instance.Pleroma.Instances.Metadata{
          software_name: "funkwhale",
          software_version: "1.4.0"
        }
      )

      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "funkwhale_admin@open.audio",
          ap_id: "https://open.audio/federation/actors/funkwhale_admin",
          inbox: "https://open.audio/federation/actors/funkwhale_admin/inbox",
          name: "funkwhale_admin"
        )

      {:ok, _, _} = User.follow(user, source)
      source_id = to_string(source.id)

      assert [
               %{
                 "id" => ^source_id,
                 "platform" => "funkwhale",
                 "source_profile" => "library",
                 "relationship" => %{"following" => true}
               }
             ] =
               conn
               |> get("/api/v1/feeds")
               |> json_response(200)
    end

    test "does not treat a normal Mastodon account on an Owncast domain as a feed", %{
      conn: conn
    } do
      insert(:instance,
        host: "social.owncast.online",
        metadata: %Instance.Pleroma.Instances.Metadata{
          software_name: "mastodon",
          software_version: "4.5.11"
        }
      )

      insert(:user,
        actor_type: "Person",
        local: false,
        nickname: "owncast@social.owncast.online",
        ap_id: "https://social.owncast.online/users/owncast",
        inbox: "https://social.owncast.online/users/owncast/inbox",
        name: "Owncast"
      )

      assert [] =
               conn
               |> get("/api/v1/feeds/search?q=owncast")
               |> json_response(200)
    end

    test "resolves source WebFinger handles and stores actor outboxes", %{conn: conn} do
      actor_url = "https://blog.example/wp-json/activitypub/1.0/actors/7"
      outbox_url = actor_url <> "/outbox"

      webfinger_url =
        "https://blog.example/.well-known/webfinger?resource=acct%3Aauthor%40blog.example"

      decoded_webfinger_url = URI.decode(webfinger_url)
      nodeinfo_url = "https://blog.example/.well-known/nodeinfo"

      Tesla.Mock.mock(fn
        %{method: :get, url: url} when url in [webfinger_url, decoded_webfinger_url] ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "subject" => "acct:author@blog.example",
                "links" => [
                  %{
                    "rel" => "self",
                    "type" => "application/activity+json",
                    "href" => actor_url
                  }
                ]
              })
          }

        %{method: :get, url: ^nodeinfo_url} ->
          %Tesla.Env{status: 404, body: ""}

        %{method: :get, url: ^actor_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => actor_url,
                "type" => "Person",
                "preferredUsername" => "author",
                "name" => "Blog Author",
                "inbox" => actor_url <> "/inbox",
                "outbox" => outbox_url
              })
          }
      end)

      assert [
               %{
                 "ap_id" => ^actor_url,
                 "display_name" => "Blog Author",
                 "source_profile" => "blog_publisher"
               }
             ] =
               conn
               |> get("/api/v1/feeds/search?q=#{URI.encode_www_form("@author@blog.example")}")
               |> json_response(200)

      assert %User{outbox_address: ^outbox_url} = User.get_cached_by_ap_id(actor_url)
    end

    test "resolving a known source updates the existing actor instead of duplicating it", %{
      conn: conn
    } do
      actor_url = "https://blog.example/wp-json/activitypub/1.0/actors/8"
      outbox_url = actor_url <> "/outbox"

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "stale-author@blog.example",
          ap_id: actor_url,
          uri: actor_url,
          name: "Stale Blog Author",
          outbox_address: actor_url <> "/old-outbox"
        )

      webfinger_url =
        "https://blog.example/.well-known/webfinger?resource=acct%3Aauthor%40blog.example"

      decoded_webfinger_url = URI.decode(webfinger_url)
      nodeinfo_url = "https://blog.example/.well-known/nodeinfo"

      Tesla.Mock.mock(fn
        %{method: :get, url: url} when url in [webfinger_url, decoded_webfinger_url] ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "subject" => "acct:author@blog.example",
                "links" => [
                  %{
                    "rel" => "self",
                    "type" => "application/activity+json",
                    "href" => actor_url
                  }
                ]
              })
          }

        %{method: :get, url: ^nodeinfo_url} ->
          %Tesla.Env{status: 404, body: ""}

        %{method: :get, url: ^actor_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => actor_url,
                "type" => "Person",
                "preferredUsername" => "author",
                "name" => "Fresh Blog Author",
                "inbox" => actor_url <> "/inbox",
                "outbox" => outbox_url
              })
          }
      end)

      assert [%{"ap_id" => ^actor_url, "display_name" => "Fresh Blog Author"}] =
               conn
               |> get("/api/v1/feeds/search?q=#{URI.encode_www_form("@author@blog.example")}")
               |> json_response(200)

      assert %User{name: "Fresh Blog Author", outbox_address: ^outbox_url} = Repo.reload(source)
    end

    test "falls back to Owncast public stream status when the outbox has no preview items", %{
      conn: conn
    } do
      actor = "https://stream.example/federation/user/streamer"
      outbox = actor <> "/outbox"

      Tesla.Mock.mock(fn
        %{method: :get, url: ^actor} ->
          %Tesla.Env{
            status: 200,
            body: %{
              "id" => actor,
              "type" => "Service",
              "preferredUsername" => "streamer",
              "name" => "Streamer",
              "inbox" => actor <> "/inbox",
              "outbox" => outbox
            }
          }

        %{method: :get, url: ^outbox} ->
          %Tesla.Env{
            status: 200,
            body: %{
              "id" => outbox,
              "type" => "OrderedCollection",
              "totalItems" => 12,
              "first" => %{
                "type" => "OrderedCollectionPage",
                "orderedItems" => []
              }
            }
          }

        %{method: :get, url: "https://stream.example/api/status"} ->
          %Tesla.Env{
            status: 200,
            body: %{
              "online" => true,
              "streamTitle" => "Test Stream",
              "viewerCount" => 7,
              "serverTime" => "2026-06-25T12:00:00Z"
            }
          }

        %{method: :get, url: "https://stream.example/api/yp"} ->
          %Tesla.Env{
            status: 200,
            body: %{
              "name" => "Streamer",
              "description" => "A test stream.",
              "logo" => "/logo.png"
            }
          }
      end)

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "streamer@stream.example",
          ap_id: actor,
          inbox: actor <> "/inbox",
          name: "Streamer"
        )

      assert %{
               "items" => [
                 %{
                   "id" =>
                     "https://stream.example/federation/user/streamer#owncast-stream-status",
                   "type" => "StreamStatus",
                   "title" => "Live now: Test Stream",
                   "summary" => summary,
                   "url" => "https://stream.example/",
                   "media_url" => "https://stream.example/hls/stream.m3u8",
                   "media_type" => "application/x-mpegURL",
                   "thumbnail_url" => "https://stream.example/logo.png",
                   "platform" => "owncast",
                   "source_kind" => "live_stream",
                   "source_kind_label" => "Live stream",
                   "capabilities" => [
                     "follow stream",
                     "preview live status",
                     "play stream"
                   ],
                   "render_hint" => %{
                     "layout" => "player",
                     "primary_action" => "play"
                   }
                 }
               ],
               "total_items" => 12
             } =
               conn
               |> get("/api/v1/feeds/#{source.id}/items")
               |> json_response(200)

      assert summary =~ "A test stream."
      assert summary =~ "7 viewers"
    end

    test "resolves Pixelfed actors as photo feeds and falls back to WebFinger Atom items", %{
      conn: conn
    } do
      actor = "https://pixey.example/users/stux"
      outbox = actor <> "/outbox"
      atom = actor <> ".atom"
      post = "https://pixey.example/p/stux/786695923908154355"
      image = "https://pixey.example/storage/m/photo.jpg"

      insert(:instance,
        host: "pixey.example",
        metadata: %Instance.Pleroma.Instances.Metadata{
          software_name: "pixelfed",
          software_version: "0.12.7"
        }
      )

      webfinger_url =
        "https://pixey.example/.well-known/webfinger?resource=acct%3Astux%40pixey.example"

      decoded_webfinger_url = URI.decode(webfinger_url)
      nodeinfo_url = "https://pixey.example/.well-known/nodeinfo"

      Tesla.Mock.mock(fn
        %{method: :get, url: url} when url in [webfinger_url, decoded_webfinger_url] ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "subject" => "acct:stux@pixey.example",
                "links" => [
                  %{
                    "rel" => "self",
                    "type" => "application/activity+json",
                    "href" => actor
                  },
                  %{
                    "rel" => "http://schemas.google.com/g/2010#updates-from",
                    "type" => "application/atom+xml",
                    "href" => atom
                  }
                ]
              })
          }

        %{method: :get, url: ^nodeinfo_url} ->
          %Tesla.Env{status: 404, body: ""}

        %{method: :get, url: ^actor} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => actor,
                "type" => "Person",
                "preferredUsername" => "stux",
                "name" => "stux",
                "inbox" => actor <> "/inbox",
                "outbox" => outbox,
                "followers" => actor <> "/followers"
              }),
            headers: HttpRequestMock.activitypub_object_headers()
          }

        %{method: :get, url: ^outbox} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => outbox,
                "type" => "OrderedCollection",
                "totalItems" => 148
              }),
            headers: HttpRequestMock.activitypub_object_headers()
          }

        %{method: :get, url: ^atom} ->
          %Tesla.Env{
            status: 200,
            body: pixelfed_atom_feed(atom, post, image)
          }

        %{method: :get, url: ^post} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => post,
                "type" => "Note",
                "content" => "A Pixelfed image post",
                "published" => "2025-01-19T20:48:44Z",
                "url" => post,
                "attributedTo" => actor,
                "to" => [Pleroma.Constants.as_public()],
                "cc" => [actor <> "/followers"],
                "attachment" => [
                  %{
                    "type" => "Document",
                    "mediaType" => "image/jpeg",
                    "url" => image,
                    "name" => "A Pixelfed image post"
                  }
                ]
              }),
            headers: HttpRequestMock.activitypub_object_headers()
          }
      end)

      assert [
               %{
                 "id" => source_id,
                 "ap_id" => ^actor,
                 "source_profile" => "photo_stream",
                 "source_kind" => "photo_feed",
                 "platform" => "pixelfed",
                 "platform_family" => "photo"
               }
             ] =
               conn
               |> get("/api/v1/feeds/search?q=#{URI.encode_www_form("@stux@pixey.example")}")
               |> json_response(200)

      assert %{
               "items" => [
                 %{
                   "id" => ^post,
                   "type" => "Image",
                   "thumbnail_url" => ^image,
                   "platform" => "pixelfed",
                   "platform_family" => "photo",
                   "status" => %{"uri" => ^post}
                 }
               ],
               "total_items" => 1
             } =
               conn
               |> get("/api/v1/feeds/#{source_id}/items")
               |> json_response(200)
    end

    test "resolves Mitra actors as microblog feeds and reads their outbox page", %{
      conn: conn
    } do
      actor = "https://public.mitra.example/users/admin"
      outbox = actor <> "/outbox"
      first = outbox <> "?page=true"
      post = "https://public.mitra.example/objects/019db9a6-8204-e6e9-5edf-25b82d84234b"

      insert(:instance,
        host: "public.mitra.example",
        metadata: %Instance.Pleroma.Instances.Metadata{
          software_name: "mitra",
          software_version: "5.5.0"
        }
      )

      webfinger_url =
        "https://public.mitra.example/.well-known/webfinger?resource=acct%3Aadmin%40public.mitra.example"

      decoded_webfinger_url = URI.decode(webfinger_url)
      nodeinfo_url = "https://public.mitra.example/.well-known/nodeinfo"

      note = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => post,
        "type" => "Note",
        "attributedTo" => actor,
        "content" => "<p>Apologies for the downtime.</p>",
        "context" => "https://public.mitra.example/collections/conversations/019db9a6",
        "published" => "2026-04-23T09:23:10Z",
        "to" => [Pleroma.Constants.as_public()],
        "cc" => [actor <> "/followers"],
        "replies" => post <> "/replies"
      }

      Tesla.Mock.mock(fn
        %{method: :get, url: url} when url in [webfinger_url, decoded_webfinger_url] ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "subject" => "acct:admin@public.mitra.example",
                "links" => [
                  %{
                    "rel" => "self",
                    "type" =>
                      "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
                    "href" => actor
                  },
                  %{
                    "rel" => "http://schemas.google.com/g/2010#updates-from",
                    "type" => "application/atom+xml",
                    "href" => "https://public.mitra.example/feeds/users/admin"
                  }
                ]
              })
          }

        %{method: :get, url: ^nodeinfo_url} ->
          %Tesla.Env{status: 404, body: ""}

        %{method: :get, url: ^actor} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => actor,
                "type" => "Person",
                "preferredUsername" => "admin",
                "name" => "admin",
                "inbox" => actor <> "/inbox",
                "outbox" => outbox,
                "followers" => actor <> "/followers"
              }),
            headers: HttpRequestMock.activitypub_object_headers()
          }

        %{method: :get, url: ^outbox} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => outbox,
                "type" => "OrderedCollection",
                "attributedTo" => actor,
                "first" => first
              }),
            headers: HttpRequestMock.activitypub_object_headers()
          }

        %{method: :get, url: ^first} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => first,
                "type" => "OrderedCollectionPage",
                "attributedTo" => actor,
                "orderedItems" => [
                  %{
                    "id" => "https://public.mitra.example/activities/announce/019b7a5e",
                    "type" => "Announce",
                    "actor" => actor,
                    "published" => "2026-01-01T16:23:10Z",
                    "to" => [Pleroma.Constants.as_public()],
                    "cc" => [actor <> "/followers"],
                    "object" => "https://mitra.example/objects/019b799a"
                  },
                  %{
                    "id" => "https://public.mitra.example/activities/create/019db9a6",
                    "type" => "Create",
                    "actor" => actor,
                    "published" => "2026-04-23T09:23:10Z",
                    "to" => [Pleroma.Constants.as_public()],
                    "cc" => [actor <> "/followers"],
                    "object" => note
                  }
                ]
              }),
            headers: HttpRequestMock.activitypub_object_headers()
          }

        %{method: :get, url: ^post} ->
          %Tesla.Env{
            status: 200,
            body: Jason.encode!(note),
            headers: HttpRequestMock.activitypub_object_headers()
          }
      end)

      assert [
               %{
                 "id" => source_id,
                 "ap_id" => ^actor,
                 "source_profile" => "microblog_feed",
                 "source_kind" => "microblog_feed",
                 "platform" => "mitra",
                 "platform_family" => "microblog"
               }
             ] =
               conn
               |> get(
                 "/api/v1/feeds/search?q=#{URI.encode_www_form("@admin@public.mitra.example")}"
               )
               |> json_response(200)

      assert %{
               "items" => [
                 %{
                   "id" => ^post,
                   "type" => "Note",
                   "platform" => "mitra",
                   "platform_family" => "microblog",
                   "status" => %{"uri" => ^post}
                 }
               ]
             } =
               conn
               |> get("/api/v1/feeds/#{source_id}/items")
               |> json_response(200)
    end

    test "searches RSS feed URLs as sources", %{conn: conn} do
      feed_url = "https://cms.example.org/fullrss2.xml"

      Tesla.Mock.mock(fn
        %{method: :get, url: ^feed_url} ->
          %Tesla.Env{
            status: 200,
            body: rss_feed(feed_url)
          }
      end)

      assert [
               %{
                 "display_name" => "ZeroHedge News",
                 "source_profile" => "rss_feed",
                 "source_kind" => "rss_feed",
                 "source_kind_label" => "RSS feed",
                 "capabilities" => ["follow feed", "read items", "share links"],
                 "relationship" => %{"following" => false},
                 "uri" => ^feed_url
               }
             ] =
               conn
               |> get("/api/v1/sources/search?q=#{URI.encode_www_form(feed_url)}")
               |> json_response(200)
    end

    test "follows RSS feed redirects and updates an existing source", %{conn: conn} do
      old_url = "https://cms.example.org/old.xml"
      new_url = "https://cms.example.org/fullrss2.xml"

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "rss-old@cms.example.org",
          ap_id: old_url,
          uri: old_url,
          name: "Old feed"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^old_url} ->
          %Tesla.Env{status: 301, headers: [{"location", new_url}], body: ""}

        %{method: :get, url: ^new_url} ->
          %Tesla.Env{status: 200, body: rss_feed(new_url)}
      end)

      assert [%{"uri" => ^new_url, "source_profile" => "rss_feed"}] =
               conn
               |> get("/api/v1/sources/search?q=#{URI.encode_www_form(old_url)}")
               |> json_response(200)

      assert %User{ap_id: ^new_url, uri: ^new_url, invisible: false, is_active: true} =
               Repo.reload(source)
    end

    test "retires an RSS source when the feed is explicitly gone", %{conn: conn} do
      feed_url = "https://cms.example.org/dead.xml"

      source =
        insert(:user,
          actor_type: "Service",
          local: false,
          nickname: "rss-dead@cms.example.org",
          ap_id: feed_url,
          uri: feed_url,
          name: "Dead feed",
          avatar: %{"url" => "https://cms.example.org/avatar.png"},
          banner: %{"url" => "https://cms.example.org/banner.png"},
          tags: ["old"]
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^feed_url} ->
          %Tesla.Env{status: 410, body: ""}
      end)

      assert [] =
               conn
               |> get("/api/v1/sources/search?q=#{URI.encode_www_form(feed_url)}")
               |> json_response(200)

      assert %User{
               is_active: false,
               invisible: true,
               is_discoverable: false,
               avatar: %{},
               banner: %{},
               tags: []
             } = Repo.reload(source)
    end
  end

  describe "POST /api/v1/sources/:id/follow and /api/v1/feeds/:id/follow" do
    setup do: oauth_access(["follow", "write:follows", "read:follows"])

    test "follows and unfollows unlocked subscription sources locally", %{conn: conn} do
      source =
        insert(:user,
          actor_type: "Application",
          local: false,
          nickname: "library@audio.example.org",
          ap_id: "http://audio.example.org/federation/music/libraries/local-source",
          inbox: "http://audio.example.org/inbox"
        )

      source_id = to_string(source.id)

      assert %{"id" => ^source_id, "following" => true, "requested" => false} =
               conn
               |> post("/api/v1/feeds/#{source.id}/follow")
               |> json_response(200)

      assert %{"id" => ^source_id, "following" => false, "requested" => false} =
               conn
               |> post("/api/v1/feeds/#{source.id}/unfollow")
               |> json_response(200)
    end

    test "follows a Funkwhale Person source detected by NodeInfo", %{conn: conn} do
      insert(:instance,
        host: "open.audio",
        metadata: %Instance.Pleroma.Instances.Metadata{
          software_name: "funkwhale",
          software_version: "1.4.0"
        }
      )

      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "funkwhale_admin@open.audio",
          ap_id: "https://open.audio/federation/actors/funkwhale_admin",
          inbox: "https://open.audio/federation/actors/funkwhale_admin/inbox",
          name: "funkwhale_admin"
        )

      source_id = to_string(source.id)

      assert %{"id" => ^source_id, "following" => true, "requested" => false} =
               conn
               |> post("/api/v1/feeds/#{source.id}/follow")
               |> json_response(200)
    end

    test "follows and unfollows RSS sources locally", %{conn: conn} do
      feed_url = "https://cms.example.org/fullrss2.xml"

      Tesla.Mock.mock(fn
        %{method: :get, url: ^feed_url} ->
          %Tesla.Env{
            status: 200,
            body: rss_feed(feed_url)
          }
      end)

      [source] =
        conn
        |> get("/api/v1/sources/search?q=#{URI.encode_www_form(feed_url)}")
        |> json_response(200)

      source_id = source["id"]

      assert %{"id" => ^source_id, "following" => true, "requested" => false} =
               conn
               |> post("/api/v1/sources/#{source_id}/follow")
               |> json_response(200)

      assert %{"id" => ^source_id, "following" => false, "requested" => false} =
               conn
               |> post("/api/v1/sources/#{source_id}/unfollow")
               |> json_response(200)
    end
  end

  describe "GET /api/v1/timelines/sources and /api/v1/timelines/feeds" do
    setup do: oauth_access(["read:statuses"])

    test "returns root posts from followed sources", %{conn: conn, user: user} do
      source =
        insert(:user,
          actor_type: "Application",
          local: false,
          nickname: "library@example.org",
          ap_id: "https://example.org/federation/music/libraries/writer"
        )

      unfollowed_source =
        insert(:user,
          actor_type: "Application",
          local: false,
          nickname: "other@example.org",
          ap_id: "https://example.org/federation/music/libraries/other"
        )

      profile =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "person@example.org",
          ap_id: "https://example.org/users/person"
        )

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "videos@example.org",
          ap_id: "https://example.org/c/videos"
        )

      {:ok, _, _} = Pleroma.FollowingRelationship.follow(user, source, :follow_accept)
      {:ok, _, _} = Pleroma.FollowingRelationship.follow(user, profile, :follow_accept)
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

      profile_root =
        insert(:note,
          user: profile,
          data: %{
            "content" => "<p>A followed profile root.</p>",
            "to" => [Pleroma.Constants.as_public(), profile.ap_id]
          }
        )

      _profile_activity =
        insert(:note_activity,
          user: profile,
          note: profile_root,
          local: false,
          data_attrs: %{"to" => [Pleroma.Constants.as_public(), profile.ap_id]}
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
               |> get("/api/v1/timelines/feeds")
               |> json_response(200)

      assert followed_activity_id == to_string(followed_activity.id)
      assert content =~ "A followed source root"
    end
  end

  defp rss_feed(feed_url) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0">
      <channel>
        <title>ZeroHedge News</title>
        <description>News and market commentary.</description>
        <link>https://cms.example.org/</link>
        <item>
          <title>First post</title>
          <link>https://cms.example.org/news/first-post</link>
          <guid>#{feed_url}#item-1</guid>
          <description>&lt;p&gt;A feed entry.&lt;/p&gt;</description>
          <pubDate>Wed, 24 Jun 2026 12:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
    """
  end

  defp pixelfed_atom_feed(atom_url, post_url, image_url) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
      <id>#{atom_url}</id>
      <title>stux on pixey.example</title>
      <updated>2025-01-19T20:48:44.000Z</updated>
      <entry>
        <id>#{post_url}</id>
        <title>A Pixelfed image post</title>
        <updated>2025-01-19T20:48:44.000Z</updated>
        <content type="html"><![CDATA[<p>A Pixelfed image post</p>]]></content>
        <link rel="alternate" href="#{post_url}" />
        <summary type="html">A Pixelfed image post</summary>
        <media:content url="#{image_url}" type="image/jpeg" medium="image" />
      </entry>
    </feed>
    """
  end
end
