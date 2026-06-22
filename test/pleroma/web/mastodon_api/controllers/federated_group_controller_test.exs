# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedGroupControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.GroupMembership
  alias Pleroma.Notification
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

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
          name: "Coffee"
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
                 "target_profile" => "threadiverse_forum",
                 "relationship" => %{"member" => true}
               }
             ] =
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
          name: "Games"
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
          name: "Video Channel"
        )

      group_id = to_string(group.id)

      assert %{
               "id" => ^group_id,
               "owner" => %{"id" => ^group_id},
               "slug" => ^group_id,
               "target_profile" => "collection_channel"
             } =
               conn
               |> get("/api/v1/groups/#{group.id}")
               |> json_response(200)
    end
  end

  describe "GET /api/v1/groups/:id/preview" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "returns an empty successful preview for local groups", %{conn: conn, user: owner} do
      {:ok, group} =
        Pleroma.Web.FederatedTarget.create_local_group(owner, %{
          "display_name" => "Local Preview Group"
        })

      assert %{"items" => [], "next" => nil, "total_items" => nil} =
               conn
               |> get("/api/v1/groups/#{group.id}/preview")
               |> json_response(200)
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
  end
end
