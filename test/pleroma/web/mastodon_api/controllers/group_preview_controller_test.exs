# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.GroupPreviewControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Instances
  alias Pleroma.Instances.Instance

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

    test "deduplicates forum posts exposed through Hubzilla Add wrappers", %{conn: conn} do
      group_url = "https://hubzilla.example/channel/adminsforum"
      outbox_url = "https://hubzilla.example/outbox/adminsforum"
      post_url = "https://hubzilla.example/item/topic-1"
      activity_url = "https://hubzilla.example/activity/topic-1"

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "adminsforum@hubzilla.example",
          ap_id: group_url,
          name: "Hubzilla Support Forum"
        )

      create = %{
        "id" => activity_url,
        "type" => "Create",
        "actor" => "https://hubzilla.example/channel/alice",
        "published" => "2026-06-06T14:57:35Z",
        "object" => %{
          "id" => post_url,
          "type" => "Note",
          "content" => "<p>Share content to a channel forum</p>",
          "url" => post_url
        }
      }

      Tesla.Mock.mock(fn
        %{method: :get, url: ^group_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => group_url,
                "type" => "Group",
                "name" => "Hubzilla Support Forum",
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
                "type" => "OrderedCollectionPage",
                "totalItems" => 2,
                "orderedItems" => [
                  %{
                    "id" => "https://hubzilla.example/activity/add-topic-1",
                    "type" => "Add",
                    "actor" => group_url,
                    "published" => "2026-06-06T14:57:36Z",
                    "object" => create,
                    "target" => %{
                      "id" => "https://hubzilla.example/conversation/topic-1",
                      "type" => "Collection",
                      "attributedTo" => group_url
                    }
                  },
                  create
                ]
              })
          }
      end)

      assert %{
               "items" => [
                 %{
                   "id" => ^post_url,
                   "type" => "Note",
                   "title" => "Share content to a channel forum",
                   "published" => "2026-06-06T14:57:35Z"
                 }
               ]
             } =
               conn
               |> get("/api/v1/groups/#{group.id}/preview")
               |> json_response(200)
    end

    test "uses Discourse category JSON when the ActivityPub outbox only exposes accepts", %{
      conn: conn
    } do
      actor_url = "https://socialhub.example/ap/actor/fediverse-report"
      outbox_url = actor_url <> "/outbox"
      category_url = "https://socialhub.example/c/fediversity/fediverse-report/83"
      category_json_url = category_url <> ".json"

      topic_url =
        "https://socialhub.example/t/ai-bots-are-overwhelming-the-signup-application-process/8790"

      topic_json_url = topic_url <> ".json"
      post_ap_id = "https://mastodon.example/users/fediversereport/statuses/1"

      insert(:instance,
        host: "socialhub.example",
        metadata: %Instance.Pleroma.Instances.Metadata{
          software_name: "discourse",
          software_version: "3.5.0"
        }
      )

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "fediversereport@socialhub.example",
          ap_id: actor_url,
          uri: category_url,
          outbox_address: outbox_url,
          name: "Fediverse Report"
        )

      author =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "fediversereport@mastodon.example",
          ap_id: "https://mastodon.example/users/fediversereport",
          name: "Fediverse Report"
        )

      note =
        insert(:note,
          user: author,
          data: %{
            "id" => post_ap_id,
            "type" => "Note",
            "actor" => author.ap_id,
            "attributedTo" => author.ap_id,
            "content" => "<p>This should be the interactive Discourse topic status.</p>",
            "to" => [Pleroma.Constants.as_public()]
          }
        )

      activity = insert(:note_activity, user: author, note: note)

      Tesla.Mock.mock(fn
        %{method: :get, url: ^category_json_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "topic_list" => %{
                  "more_topics_url" => "/c/fediversity/fediverse-report/83?page=1",
                  "topics" => [
                    %{
                      "id" => 3730,
                      "title" => "About The Fediverse report",
                      "slug" => "about-the-fediverse-report",
                      "excerpt" => "Pinned category explainer",
                      "created_at" => "2023-12-01T18:38:29.091Z",
                      "pinned" => true,
                      "posts_count" => 2
                    },
                    %{
                      "id" => 8790,
                      "title" => "ai bots are overwhelming the signup application process",
                      "fancy_title" => "ai bots are overwhelming the signup application process",
                      "slug" => "ai-bots-are-overwhelming-the-signup-application-process",
                      "excerpt" => "A real topic excerpt&hellip;",
                      "created_at" => "2026-06-25T17:56:57.101Z",
                      "last_posted_at" => "2026-06-26T08:40:26.199Z",
                      "reply_count" => 4,
                      "posts_count" => 5,
                      "image_url" => "/uploads/topic.png"
                    }
                  ]
                }
              })
          }

        %{method: :get, url: ^topic_json_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "post_stream" => %{
                  "posts" => [
                    %{
                      "id" => 30967,
                      "activity_pub_object_id" => post_ap_id,
                      "activity_pub_object_type" => "Note",
                      "activity_pub_url" =>
                        "https://mastodon.example/@fediversereport/116812035822107731"
                    }
                  ]
                }
              })
          }
      end)

      assert %{
               "total_items" => 1,
               "next" =>
                 "https://socialhub.example/c/fediversity/fediverse-report/83.json?page=1",
               "items" => [
                 %{
                   "id" => ^topic_url,
                   "type" => "Article",
                   "title" => "ai bots are overwhelming the signup application process",
                   "summary" => "A real topic excerpt...",
                   "url" => ^topic_url,
                   "thumbnail_url" => "https://socialhub.example/uploads/topic.png",
                   "platform" => "discourse",
                   "platform_family" => "longform",
                   "comments_count" => 4,
                   "published" => "2026-06-25T17:56:57.101Z",
                   "status" => %{
                     "id" => status_id,
                     "content" => status_content
                   }
                 }
               ]
             } =
               conn
               |> get("/api/v1/groups/#{group.id}/preview")
               |> json_response(200)

      assert status_id == to_string(activity.id)
      assert status_content =~ "interactive Discourse topic status"
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
