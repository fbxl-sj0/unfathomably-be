# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedGroupControllerTest do
  use Pleroma.Web.ConnCase

  require Pleroma.Constants

  alias Pleroma.GroupMembership
  alias Pleroma.Instances
  alias Pleroma.Notification
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.FederatedTarget

  import Pleroma.Factory
  import Mock

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "GET /api/v1/groups" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "lists followed ActivityPub Group actors", %{conn: conn, user: user} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "coffee@lotide.example",
          ap_id: "https://lotide.example/c/coffee",
          name: "Coffee",
          follower_count: 12
        )

      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "blog@example.org",
          ap_id: "https://example.org/users/blog",
          name: "Example Blog"
        )

      {:ok, _, _} = User.follow(user, group)
      {:ok, _, _} = User.follow(user, source)

      group_id = to_string(group.id)

      assert [
               %{
                 "id" => ^group_id,
                 "display_name" => "Coffee",
                 "members_count" => 1,
                 "target_profile" => "threadiverse_forum",
                 "relationship" => %{"member" => true}
               }
             ] =
               conn
               |> get("/api/v1/groups")
               |> json_response(200)
    end

    test "does not list followed groups from consistently unreachable instances", %{
      conn: conn,
      user: user
    } do
      reachable_group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "live@live.example",
          ap_id: "https://live.example/c/live",
          name: "Live"
        )

      unreachable_group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "dead@dead.example",
          ap_id: "https://dead.example/c/dead",
          name: "Dead"
        )

      {:ok, _, _} = User.follow(user, reachable_group)
      {:ok, _, _} = User.follow(user, unreachable_group)
      Instances.set_consistently_unreachable("dead.example")

      reachable_group_id = to_string(reachable_group.id)

      assert [%{"id" => ^reachable_group_id}] =
               conn
               |> get("/api/v1/groups")
               |> json_response(200)
    end

    test "searches known groups without returning source actors", %{conn: conn} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "games@lotide.example",
          ap_id: "https://lotide.example/communities/games",
          name: "Games",
          follower_count: 9
        )

      insert(:user,
        actor_type: "Person",
        local: false,
        nickname: "games@example.org",
        ap_id: "https://example.org/users/games",
        name: "Games Blogger"
      )

      group_id = to_string(group.id)

      assert [%{"id" => ^group_id, "actor_type" => "Group"}] =
               conn
               |> get("/api/v1/groups?q=games")
               |> json_response(200)
    end

    test "does not search groups from consistently unreachable instances", %{conn: conn} do
      visible_group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "shared@live.example",
          ap_id: "https://live.example/c/shared",
          name: "Shared"
        )

      insert(:user,
        actor_type: "Group",
        local: false,
        nickname: "shared@dead.example",
        ap_id: "https://dead.example/c/shared",
        name: "Shared"
      )

      Instances.set_consistently_unreachable("dead.example")
      visible_group_id = to_string(visible_group.id)

      assert [%{"id" => ^visible_group_id}] =
               conn
               |> get("/api/v1/groups?q=shared")
               |> json_response(200)
    end
  end

  describe "GET /api/v1/groups/:id" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "renders a Soapbox-compatible group envelope", %{conn: conn} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "video@peertube.example",
          ap_id: "https://peertube.example/video-channels/video",
          name: "Video Channel",
          follower_count: 7
        )

      group_id = to_string(group.id)

      assert %{
               "id" => ^group_id,
               "owner" => %{"id" => ^group_id},
               "slug" => ^group_id,
               "members_count" => 7,
               "target_profile" => "collection_channel"
             } =
               conn
               |> get("/api/v1/groups/#{group.id}")
               |> json_response(200)
    end

    test "fetches a missing remote group member count from followers collection", %{conn: conn} do
      followers_url = "https://peertube.example/video-channels/video/followers"

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "video@peertube.example",
          ap_id: "https://peertube.example/video-channels/video",
          follower_address: followers_url,
          follower_count: 0,
          name: "Video Channel"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^followers_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => followers_url,
                "type" => "OrderedCollection",
                "totalItems" => "42"
              })
          }
      end)

      group_id = to_string(group.id)

      assert %{
               "id" => ^group_id,
               "members_count" => 42
             } =
               conn
               |> get("/api/v1/groups/#{group.id}")
               |> json_response(200)

      assert %{follower_count: 42} = User.get_cached_by_id(group.id)
    end

    test "fetches a missing remote group moderator count from attributedTo collection", %{
      conn: conn
    } do
      moderators_url = "https://mbin.example/m/main/moderators"

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "main@mbin.example",
          ap_id: "https://mbin.example/m/main",
          attributed_to_address: moderators_url,
          moderator_count: 0,
          name: "Main"
        )

      Tesla.Mock.mock(fn
        %{method: :get, url: ^moderators_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => moderators_url,
                "type" => "OrderedCollection",
                "totalItems" => "4",
                "orderedItems" => []
              })
          }
      end)

      group_id = to_string(group.id)

      assert %{
               "id" => ^group_id,
               "moderators_count" => 4,
               "source" => %{
                 "pleroma" => %{
                   "activitypub" => %{"attributed_to" => ^moderators_url}
                 }
               }
             } =
               conn
               |> get("/api/v1/groups/#{group.id}")
               |> json_response(200)

      assert %{moderator_count: 4} = User.get_cached_by_id(group.id)
    end
  end

  describe "GET /api/v1/groups/lookup" do
    test "resolves uncached WebFinger handles with a leading at sign", %{conn: conn} do
      actor_url = "https://wordpress.example/?author=0"
      outbox_url = "https://wordpress.example/wp-json/activitypub/1.0/actors/0/outbox"

      webfinger_url =
        "https://wordpress.example/.well-known/webfinger?resource=acct%3Ablog%40wordpress.example"

      decoded_webfinger_url = URI.decode(webfinger_url)

      Tesla.Mock.mock(fn
        %{method: :get, url: url} when url in [webfinger_url, decoded_webfinger_url] ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "subject" => "acct:blog@wordpress.example",
                "links" => [
                  %{
                    "rel" => "self",
                    "type" => "application/activity+json",
                    "href" => actor_url
                  }
                ]
              })
          }

        %{method: :get, url: ^actor_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "@context" => "https://www.w3.org/ns/activitystreams",
                "id" => actor_url,
                "type" => "Group",
                "preferredUsername" => "blog",
                "name" => "WordPress Blog",
                "inbox" => "https://wordpress.example/wp-json/activitypub/1.0/actors/0/inbox",
                "outbox" => outbox_url
              })
          }
      end)

      assert %{
               "actor_type" => "Group",
               "ap_id" => ^actor_url,
               "display_name" => "WordPress Blog",
               "source" => %{
                 "pleroma" => %{
                   "activitypub" => %{"outbox" => ^outbox_url}
                 }
               }
             } =
               conn
               |> get(
                 "/api/v1/groups/lookup?name=#{URI.encode_www_form("@blog@wordpress.example")}"
               )
               |> json_response(200)
    end
  end

  describe "GET /api/v1/groups/:id/preview" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "returns an empty successful preview for local groups", %{conn: conn, user: owner} do
      {:ok, group} =
        FederatedTarget.create_local_group(owner, %{
          "display_name" => "Local Preview Group"
        })

      assert %{"items" => [], "next" => nil, "total_items" => nil} =
               conn
               |> get("/api/v1/groups/#{group.id}/preview")
               |> json_response(200)
    end

    test "local group creation returns a clean duplicate error if nickname selection races", %{
      user: owner
    } do
      insert(:user, nickname: "race_group")

      with_mock User,
        [:passthrough],
        get_cached_by_nickname: fn
          "race_group" -> nil
          nickname -> passthrough([nickname])
        end do
        assert {:error, :already_exists} =
                 FederatedTarget.create_local_group(owner, %{
                   "display_name" => "Race Group",
                   "slug" => "race_group"
                 })
      end
    end
  end

  describe "GET /api/v1/groups/relationships" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "maps account follow state to group membership fields", %{conn: conn, user: user} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "music@lotide.example",
          ap_id: "https://lotide.example/c/music"
        )

      {:ok, _, _} = User.follow(user, group)
      group_id = to_string(group.id)

      assert [%{"id" => ^group_id, "member" => true, "role" => "user"}] =
               conn
               |> get("/api/v1/groups/relationships?id[]=#{group.id}")
               |> json_response(200)
    end
  end

  describe "POST /api/v1/groups/:id/join" do
    setup do: oauth_access(["follow", "write:follows", "read:follows"])

    test "joins and leaves a group through CommonAPI follow state", %{conn: conn} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "localgroup",
          ap_id: "http://mastodon.example.org/users/localgroup",
          inbox: "http://mastodon.example.org/inbox"
        )

      group_id = to_string(group.id)

      assert %{"id" => ^group_id, "member" => false, "requested" => true} =
               conn
               |> post("/api/v1/groups/#{group.id}/join")
               |> json_response(200)

      assert %{"id" => ^group_id, "member" => false, "requested" => false} =
               conn
               |> post("/api/v1/groups/#{group.id}/leave")
               |> json_response(200)
    end
  end

  describe "local group membership moderation" do
    test "lets members join an open local group immediately" do
      %{conn: owner_conn, user: _owner} =
        oauth_access(["write", "write:accounts", "read:accounts", "read:follows"])

      member = insert(:user)

      %{conn: member_conn} =
        oauth_access(["follow", "write:follows", "read:follows"], user: member)

      %{"id" => group_id} =
        owner_conn
        |> post("/api/v1/groups", %{display_name: "Open Workshop"})
        |> json_response(200)

      assert %{"id" => ^group_id, "member" => true, "requested" => false, "role" => "user"} =
               member_conn
               |> post("/api/v1/groups/#{group_id}/join")
               |> json_response(200)

      assert [%{"account" => %{"id" => member_id}, "role" => "user"}] =
               owner_conn
               |> get("/api/v1/groups/#{group_id}/memberships?role=user")
               |> json_response(200)

      assert member_id == to_string(member.id)
    end

    test "keeps closed local group joins pending until a moderator approves them" do
      %{conn: owner_conn, user: owner} =
        oauth_access(["write", "write:accounts", "read:accounts", "read:follows"])

      member = insert(:user)

      %{conn: member_conn} =
        oauth_access(["follow", "write:follows", "read:follows"], user: member)

      %{"id" => group_id} =
        owner_conn
        |> post("/api/v1/groups", %{
          display_name: "Closed Workshop",
          group_visibility: "members_only"
        })
        |> json_response(200)

      assert %{"id" => ^group_id, "member" => false, "requested" => true} =
               member_conn
               |> post("/api/v1/groups/#{group_id}/join")
               |> json_response(200)

      assert [%{"id" => member_id}] =
               owner_conn
               |> get("/api/v1/groups/#{group_id}/membership_requests")
               |> json_response(200)

      assert member_id == to_string(member.id)

      assert Enum.any?(Notification.for_user(owner), &(&1.type == "follow_request"))

      assert %{"id" => ^group_id, "member" => true, "requested" => false, "role" => "user"} =
               owner_conn
               |> post("/api/v1/groups/#{group_id}/membership_requests/#{member.id}/authorize")
               |> json_response(200)
    end

    test "lets owners and moderators manage local group roles and bans" do
      %{conn: owner_conn, user: owner} =
        oauth_access(["write", "write:accounts", "read:accounts", "read:follows"])

      moderator = insert(:user)
      third = insert(:user)

      %{conn: moderator_conn} =
        oauth_access(["follow", "write:follows", "write", "write:accounts", "read:follows"],
          user: moderator
        )

      %{conn: third_conn} =
        oauth_access(["follow", "write:follows", "read:follows"], user: third)

      %{"id" => group_id} =
        owner_conn
        |> post("/api/v1/groups", %{display_name: "Moderated Workshop"})
        |> json_response(200)

      group = User.get_cached_by_id(group_id)

      moderator_conn
      |> post("/api/v1/groups/#{group_id}/join")
      |> json_response(200)

      third_conn
      |> post("/api/v1/groups/#{group_id}/join")
      |> json_response(200)

      assert %{"role" => "moderator", "account" => %{"id" => moderator_id}} =
               owner_conn
               |> post("/api/v1/groups/#{group_id}/promote", %{
                 account_ids: [moderator.id],
                 role: "moderator"
               })
               |> json_response(200)

      assert moderator_id == to_string(moderator.id)

      assert %{"role" => "moderator", "account" => %{"id" => third_id}} =
               moderator_conn
               |> post("/api/v1/groups/#{group_id}/promote", %{
                 account_ids: [third.id],
                 role: "moderator"
               })
               |> json_response(200)

      assert third_id == to_string(third.id)

      assert %{"role" => "user"} =
               owner_conn
               |> post("/api/v1/groups/#{group_id}/demote", %{account_ids: [third.id]})
               |> json_response(200)

      assert %{} =
               moderator_conn
               |> post("/api/v1/groups/#{group_id}/blocks", %{account_ids: [third.id]})
               |> json_response(200)

      assert %GroupMembership{state: "banned"} = GroupMembership.get(group, third)
      assert %GroupMembership{role: "owner"} = GroupMembership.get(group, owner)

      assert %{"error" => "You are banned from this group"} =
               third_conn
               |> post("/api/v1/groups/#{group_id}/join")
               |> json_response(403)
    end
  end

  describe "GET /api/v1/timelines/group/:id" do
    setup do: oauth_access(["read:statuses"])

    test "returns root posts from followed groups", %{conn: conn, user: user} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "selfhosted@lemmy.example",
          ap_id: "https://lemmy.example/c/selfhosted",
          name: "Self Hosted"
        )

      unfollowed_group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "linux@lemmy.example",
          ap_id: "https://lemmy.example/c/linux"
        )

      author =
        insert(:user,
          local: false,
          nickname: "alice@lemmy.example",
          ap_id: "https://lemmy.example/u/alice"
        )

      {:ok, _, _} = Pleroma.FollowingRelationship.follow(user, group, :follow_accept)
      group_id = to_string(group.id)

      context = "https://lemmy.example/post/1"

      root =
        insert(:note,
          user: author,
          data: %{
            "content" => "<p>A followed group root.</p>",
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      followed_activity =
        insert(:note_activity,
          user: author,
          note: root,
          local: false,
          data_attrs: %{
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      reply =
        insert(:note,
          user: author,
          data: %{
            "content" => "<p>A followed group reply.</p>",
            "context" => context,
            "inReplyTo" => root.data["id"],
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      _reply_activity =
        insert(:note_activity,
          user: author,
          note: reply,
          local: false,
          data_attrs: %{
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      other_root =
        insert(:note,
          user: author,
          data: %{
            "content" => "<p>An unfollowed group root.</p>",
            "to" => [Pleroma.Constants.as_public(), unfollowed_group.ap_id]
          }
        )

      _unfollowed_activity =
        insert(:note_activity,
          user: author,
          note: other_root,
          local: false,
          data_attrs: %{"to" => [Pleroma.Constants.as_public(), unfollowed_group.ap_id]}
        )

      assert [
               %{
                 "id" => followed_activity_id,
                 "content" => content,
                 "group" => %{
                   "id" => ^group_id,
                   "display_name" => "Self Hosted",
                   "slug" => ^group_id
                 }
               }
             ] =
               conn
               |> get("/api/v1/timelines/groups")
               |> json_response(200)

      assert followed_activity_id == to_string(followed_activity.id)
      assert content =~ "A followed group root"
    end

    test "returns a timeline envelope for a known federated group", %{conn: conn, user: user} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "empty@lotide.example",
          ap_id: "https://lotide.example/c/empty"
        )

      {:ok, _activity} =
        CommonAPI.post(user, %{status: "This post is not addressed to the group."})

      assert [] =
               conn
               |> get("/api/v1/timelines/group/#{group.id}")
               |> json_response(200)
    end

    test "includes public activities authored by the group actor", %{conn: conn} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "root42@peertube.example",
          ap_id: "https://peertube.example/video-channels/root42",
          name: "root42"
        )

      note =
        insert(:note,
          user: group,
          data: %{
            "type" => "Video",
            "name" => "Repairing a Commodore drive",
            "content" => "<p>A channel video.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      activity = insert(:note_activity, user: group, note: note)
      group_id = to_string(group.id)

      assert [
               %{
                 "id" => activity_id,
                 "account" => %{"id" => ^group_id},
                 "content" => content,
                 "group" => %{
                   "id" => ^group_id,
                   "display_name" => "root42",
                   "slug" => ^group_id
                 }
               }
             ] =
               conn
               |> get("/api/v1/timelines/group/#{group.id}")
               |> json_response(200)

      assert activity_id == to_string(activity.id)
      assert content =~ "Repairing a Commodore drive"
    end

    test "does not use the normal group feed as the pinned group timeline", %{conn: conn} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "selfhosted@lemmy.example",
          ap_id: "https://lemmy.example/c/selfhosted"
        )

      note =
        insert(:note,
          user: group,
          data: %{
            "content" => "<p>A normal thread root.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      _activity = insert(:note_activity, user: group, note: note, local: false)

      assert [] =
               conn
               |> get("/api/v1/timelines/group/#{group.id}?pinned=true")
               |> json_response(200)
    end

    test "returns only actual pinned group activities for the pinned timeline", %{conn: conn} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "videos@peertube.example",
          ap_id: "https://peertube.example/video-channels/videos"
        )

      pinned =
        insert(:note,
          user: group,
          data: %{
            "type" => "Video",
            "name" => "Pinned channel video",
            "content" => "<p>This one is featured.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      unpinned =
        insert(:note,
          user: group,
          data: %{
            "type" => "Video",
            "name" => "Normal channel video",
            "content" => "<p>This one is not featured.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      pinned_activity = insert(:note_activity, user: group, note: pinned, local: false)
      _unpinned_activity = insert(:note_activity, user: group, note: unpinned, local: false)

      {:ok, _group} = User.add_pinned_object_id(group, pinned.data["id"])

      assert [
               %{
                 "id" => pinned_activity_id,
                 "content" => content
               }
             ] =
               conn
               |> get("/api/v1/timelines/group/#{group.id}?pinned=true")
               |> json_response(200)

      assert pinned_activity_id == to_string(pinned_activity.id)
      assert content =~ "Pinned channel video"
    end

    test "returns discussion roots instead of flat announced comments by default", %{conn: conn} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "selfhosted@lemmy.example",
          ap_id: "https://lemmy.example/c/selfhosted"
        )

      author =
        insert(:user,
          local: false,
          nickname: "alice@lemmy.example",
          ap_id: "https://lemmy.example/u/alice"
        )

      context = "https://lemmy.example/post/1"

      post =
        insert(:note,
          user: author,
          data: %{
            "content" => "<p>A thread root.</p>",
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      _post_activity =
        insert(:note_activity,
          user: author,
          note: post,
          local: false,
          data_attrs: %{
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      comment =
        insert(:note,
          user: author,
          data: %{
            "content" => "<p>A recent comment.</p>",
            "context" => context,
            "inReplyTo" => post.data["id"],
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      _comment_activity =
        insert(:note_activity,
          user: author,
          note: comment,
          local: false,
          data_attrs: %{
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      post_announce =
        Pleroma.Repo.insert!(%Pleroma.Activity{
          local: false,
          actor: group.ap_id,
          recipients: [Pleroma.Constants.as_public(), group.ap_id],
          data: %{
            "id" => Pleroma.Web.ActivityPub.Utils.generate_activity_id(),
            "type" => "Announce",
            "actor" => group.ap_id,
            "object" => post.data["id"],
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), group.ap_id],
            "cc" => []
          }
        })

      comment_announce =
        Pleroma.Repo.insert!(%Pleroma.Activity{
          local: false,
          actor: group.ap_id,
          recipients: [Pleroma.Constants.as_public(), group.ap_id],
          data: %{
            "id" => Pleroma.Web.ActivityPub.Utils.generate_activity_id(),
            "type" => "Announce",
            "actor" => group.ap_id,
            "object" => comment.data["id"],
            "context" => context,
            "to" => [Pleroma.Constants.as_public(), group.ap_id],
            "cc" => []
          }
        })

      assert [
               %{
                 "id" => post_announce_id,
                 "content" => post_content
               }
             ] =
               conn
               |> get("/api/v1/timelines/group/#{group.id}")
               |> json_response(200)

      assert post_announce_id == to_string(post_announce.id)
      assert post_content =~ "A thread root"

      flat_results =
        conn
        |> get("/api/v1/timelines/group/#{group.id}?with_replies=true")
        |> json_response(200)

      flat_ids = Enum.map(flat_results, & &1["id"])
      flat_contents = Enum.map(flat_results, & &1["content"])

      assert to_string(comment_announce.id) in flat_ids
      assert length(flat_contents) == 2
      assert Enum.any?(flat_contents, &(&1 =~ "A thread root"))
      assert Enum.any?(flat_contents, &(&1 =~ "A recent comment"))
    end

    test "refreshes a partially cached remote threadiverse group first page", %{conn: conn} do
      group_url = "https://lemmy.example/c/selfhosted"

      api_url =
        "https://lemmy.example/api/v3/post/list?community_name=selfhosted&sort=New&limit=20"

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "selfhosted@lemmy.example",
          ap_id: group_url
        )

      author =
        insert(:user,
          local: false,
          nickname: "alice@lemmy.example",
          ap_id: "https://lemmy.example/u/alice"
        )

      stale =
        insert(:note,
          user: group,
          data: %{
            "content" => "<p>A stale cached community item.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      _stale_activity = insert(:note_activity, user: group, note: stale, local: false)

      featured_url = "https://lemmy.example/post/featured"
      first_url = "https://lemmy.example/post/2"
      second_url = "https://lemmy.example/post/1"

      featured =
        insert(:note,
          user: author,
          data: %{
            "id" => featured_url,
            "content" => "<p>A featured remote root.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      first =
        insert(:note,
          user: author,
          data: %{
            "id" => first_url,
            "content" => "<p>The newest remote root.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      second =
        insert(:note,
          user: author,
          data: %{
            "id" => second_url,
            "content" => "<p>The next remote root.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      _featured_activity = insert(:note_activity, user: author, note: featured, local: false)
      first_activity = insert(:note_activity, user: author, note: first, local: false)
      second_activity = insert(:note_activity, user: author, note: second, local: false)

      Tesla.Mock.mock(fn
        %{method: :get, url: ^api_url} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "posts" => [
                  %{
                    "post" => %{
                      "ap_id" => featured_url,
                      "name" => "Featured remote root",
                      "published" => "2026-06-23T16:00:00Z",
                      "featured_community" => true
                    },
                    "creator" => %{"actor_id" => author.ap_id},
                    "counts" => %{"comments" => 6}
                  },
                  %{
                    "post" => %{
                      "ap_id" => first_url,
                      "name" => "Newest remote root",
                      "published" => "2026-06-23T15:00:00Z"
                    },
                    "creator" => %{"actor_id" => author.ap_id},
                    "counts" => %{"comments" => 4}
                  },
                  %{
                    "post" => %{
                      "ap_id" => second_url,
                      "name" => "Next remote root",
                      "published" => "2026-06-23T14:00:00Z"
                    },
                    "creator" => %{"actor_id" => author.ap_id},
                    "counts" => %{"comments" => 2}
                  }
                ]
              })
          }
      end)

      assert [
               %{"id" => first_activity_id, "content" => first_content},
               %{"id" => second_activity_id, "content" => second_content}
             ] =
               conn
               |> get("/api/v1/timelines/group/#{group.id}")
               |> json_response(200)

      assert first_activity_id == to_string(first_activity.id)
      assert second_activity_id == to_string(second_activity.id)
      assert first_content =~ "The newest remote root"
      assert second_content =~ "The next remote root"
    end

    test "returns preview item activities when a remote group has account-authored objects", %{
      conn: conn
    } do
      group_url = "https://peertube.example/video-channels/root42"
      outbox_url = "https://peertube.example/video-channels/root42/outbox"
      video_url = "https://peertube.example/videos/watch/1"

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
            "content" => "<p>This was imported before the channel timeline.</p>"
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
                "orderedItems" => [
                  %{
                    "id" => video_url,
                    "type" => "Video",
                    "name" => "A cached channel video",
                    "content" => "<p>This was imported before the channel timeline.</p>"
                  }
                ]
              })
          }
      end)

      assert [
               %{
                 "id" => activity_id,
                 "account" => %{"id" => author_id},
                 "content" => content
               }
             ] =
               conn
               |> get("/api/v1/timelines/group/#{group.id}")
               |> json_response(200)

      assert activity_id == to_string(activity.id)
      assert author_id == to_string(author.id)
      assert content =~ "A cached channel video"
    end

    test "refreshes a stale PeerTube channel first page from the channel outbox", %{
      conn: conn
    } do
      group_url = "https://peertube.example/video-channels/nephitejnf_channel"
      outbox_url = "https://peertube.example/video-channels/nephitejnf_channel/outbox"
      fresh_video_url = "https://peertube.example/videos/watch/fresh"

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "nephitejnf_channel@peertube.example",
          ap_id: group_url,
          name: "Main nephitejnf channel",
          outbox_address: outbox_url
        )

      author =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "nephitejnf@peertube.example",
          ap_id: "https://peertube.example/accounts/nephitejnf",
          name: "nephitejnf"
        )

      stale =
        insert(:note,
          user: group,
          data: %{
            "type" => "Video",
            "name" => "Older cached channel video",
            "content" => "<p>This should not lead the refreshed channel timeline.</p>",
            "to" => [Pleroma.Constants.as_public(), group.ap_id]
          }
        )

      _stale_activity = insert(:note_activity, user: group, note: stale, local: false)

      fresh_video =
        insert(:note,
          user: author,
          data: %{
            "id" => fresh_video_url,
            "type" => "Video",
            "actor" => author.ap_id,
            "attributedTo" => author.ap_id,
            "name" => "Fresh channel video",
            "content" => "<p>This came from the fresh PeerTube outbox.</p>"
          }
        )

      fresh_activity = insert(:note_activity, user: author, note: fresh_video, local: false)

      Tesla.Mock.mock(fn
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
                    "id" => fresh_video_url,
                    "type" => "Video",
                    "actor" => author.ap_id,
                    "attributedTo" => author.ap_id,
                    "name" => "Fresh channel video",
                    "content" => "<p>This came from the fresh PeerTube outbox.</p>"
                  }
                ]
              })
          }
      end)

      assert [
               %{
                 "id" => fresh_activity_id,
                 "account" => %{"id" => author_id},
                 "content" => content
               }
             ] =
               conn
               |> get("/api/v1/timelines/group/#{group.id}")
               |> json_response(200)

      assert fresh_activity_id == to_string(fresh_activity.id)
      assert author_id == to_string(author.id)
      assert content =~ "Fresh channel video"

      assert [
               %{
                 "id" => ^fresh_activity_id,
                 "content" => alias_content
               }
             ] =
               conn
               |> get("/api/v1/groups/#{group.id}/statuses")
               |> json_response(200)

      assert alias_content =~ "Fresh channel video"
    end
  end
end
