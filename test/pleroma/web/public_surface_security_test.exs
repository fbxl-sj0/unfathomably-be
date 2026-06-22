# Pleroma: A lightweight social networking server
# Copyright 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PublicSurfaceSecurityTest do
  use Pleroma.Web.ConnCase

  import Pleroma.Factory

  alias Pleroma.Activity.Ir.Topics
  alias Pleroma.Web.Streamer

  @public "https://www.w3.org/ns/activitystreams#Public"
  @oversized_identifier String.duplicate("a", 2049)
  @hostile_query "https://attacker.example/" <>
                   String.duplicate("../", 64) <> "<script>alert(1)</script>"
  @bad_target_identifiers [
    "",
    "   ",
    "group" <> <<0>> <> "target",
    @oversized_identifier
  ]

  describe "stream topic validation" do
    test "rejects hostile group and source identifiers before subscription" do
      for id <- @bad_target_identifiers do
        assert {:error, :bad_topic} = Streamer.get_topic("group", nil, nil, %{"group" => id})
        assert {:error, :bad_topic} = Streamer.get_topic("group:#{id}", nil, nil, %{})
        assert {:error, :bad_topic} = Streamer.get_topic("source", nil, nil, %{"source" => id})
        assert {:error, :bad_topic} = Streamer.get_topic("source:#{id}", nil, nil, %{})
      end
    end

    test "honors unauthenticated federated timeline restrictions for group and source streams" do
      group = remote_group()
      source = remote_source()

      assert {:ok, "group:" <> _} =
               Streamer.get_topic("group", nil, nil, %{"group" => group.ap_id})

      assert {:ok, "source:" <> _} =
               Streamer.get_topic("source", nil, nil, %{"source" => source.ap_id})

      clear_config([:restrict_unauthenticated, :timelines, :federated], true)

      assert {:error, :unauthorized} =
               Streamer.get_topic("group", nil, nil, %{"group" => group.ap_id})

      assert {:error, :unauthorized} =
               Streamer.get_topic("source", nil, nil, %{"source" => source.ap_id})

      %{user: user, token: token} = oauth_access(["read"])

      assert {:ok, "group:" <> _} =
               Streamer.get_topic("group", user, token, %{"group" => group.ap_id})

      assert {:ok, "source:" <> _} =
               Streamer.get_topic("source", user, token, %{"source" => source.ap_id})
    end

    test "does not fan out private group or source activity to public target streams" do
      group = remote_group("private@groups.example", "https://groups.example/c/private")

      source =
        remote_source("private-library@audio.example", "https://audio.example/channels/private")

      note =
        insert(:note,
          user: source,
          data: %{
            "actor" => source.ap_id,
            "attributedTo" => source.ap_id,
            "to" => [group.ap_id],
            "cc" => []
          }
        )

      activity =
        insert(:note_activity,
          user: source,
          note: note,
          recipients: [group.ap_id]
        )

      topics = Topics.get_activity_topics(activity)

      refute "group:#{group.id}" in topics
      refute "source:#{source.id}" in topics
    end
  end

  describe "group and source public API boundaries" do
    test "known groups and sources are readable through their public surfaces", %{conn: conn} do
      group = remote_group()
      source = remote_source()
      %{conn: authed_conn} = oauth_access(["read"])

      group_conn = get(conn, "/api/v1/groups/#{group.id}")
      source_conn = get(authed_conn, "/api/v1/sources/#{source.id}")

      assert group_conn.status == 200
      assert source_conn.status == 200
    end

    test "discovery endpoints do not leak hostile query text or return server errors", %{
      conn: conn
    } do
      endpoints = [
        {"/api/v1/groups/search", %{q: @hostile_query}},
        {"/api/v1/groups/lookup", %{acct: @hostile_query}},
        {"/api/v1/sources/search", %{q: @hostile_query}},
        {"/api/v1/sources/lookup", %{acct: @hostile_query}}
      ]

      for {path, params} <- endpoints do
        response_conn =
          conn
          |> recycle()
          |> get(path, params)

        assert_client_response(response_conn)
        refute response_conn.resp_body =~ "<script>"
      end
    end

    test "mutating endpoints require authentication before they can change state", %{conn: conn} do
      group = remote_group()
      source = remote_source()

      endpoints = [
        {:post, "/api/v1/groups/#{group.id}/join", %{}},
        {:post, "/api/v1/groups/#{group.id}/follow", %{}},
        {:post, "/api/v1/groups/#{group.id}/promote", %{account_id: "missing"}},
        {:post, "/api/v1/groups/#{group.id}/blocks", %{account_id: "missing"}},
        {:post, "/api/v1/sources/#{source.id}/follow", %{}},
        {:post, "/api/v1/sources/#{source.id}/unfollow", %{}}
      ]

      for {method, path, params} <- endpoints do
        response_conn =
          conn
          |> recycle()
          |> request(method, path, params)

        assert response_conn.status in [401, 403]
      end
    end

    test "group endpoints reject sources and source endpoints reject groups", %{conn: _conn} do
      group = remote_group()
      source = remote_source()
      %{conn: conn} = oauth_access(["read", "write", "follow"])

      source_follow_conn =
        conn
        |> post("/api/v1/sources/#{group.id}/follow")

      group_join_conn =
        conn
        |> recycle()
        |> post("/api/v1/groups/#{source.id}/join")

      assert source_follow_conn.status in 400..499
      assert group_join_conn.status in 400..499
      refute source_follow_conn.status in 200..299
      refute group_join_conn.status in 200..299
    end

    test "oversized path identifiers fail as client errors, not server errors", %{conn: conn} do
      endpoints = [
        "/api/v1/groups/#{@oversized_identifier}/preview",
        "/api/v1/groups/#{@oversized_identifier}",
        "/api/v1/sources/#{@oversized_identifier}",
        "/api/v1/sources/#{@oversized_identifier}/items"
      ]

      for path <- endpoints do
        response_conn =
          conn
          |> recycle()
          |> get(path)

        assert_client_response(response_conn)
      end
    end
  end

  describe "first-time interoperability shapes" do
    test "public target streams are derived for public source posts into groups" do
      group = remote_group()
      source = remote_source()

      note =
        insert(:note,
          user: source,
          data: %{
            "actor" => source.ap_id,
            "attributedTo" => source.ap_id,
            "to" => [@public, group.ap_id],
            "cc" => []
          }
        )

      activity =
        insert(:note_activity,
          user: source,
          note: note,
          recipients: [@public, group.ap_id]
        )

      topics = Topics.get_activity_topics(activity)

      assert "group:#{group.id}" in topics
      assert "source:#{source.id}" in topics
      assert "public" in topics
    end
  end

  defp remote_group(
         nickname \\ "general@groups.example",
         ap_id \\ "https://groups.example/c/general"
       ) do
    insert(:user,
      local: false,
      actor_type: "Group",
      ap_id: ap_id,
      nickname: nickname,
      name: "General"
    )
  end

  defp remote_source(
         nickname \\ "library@audio.example",
         ap_id \\ "https://audio.example/channels/library"
       ) do
    insert(:user,
      local: false,
      actor_type: "Service",
      ap_id: ap_id,
      nickname: nickname,
      name: "Library"
    )
  end

  defp request(conn, :post, path, params), do: post(conn, path, params)

  defp assert_client_response(conn) do
    assert conn.status in 200..499
    refute conn.status in 500..599
  end
end
