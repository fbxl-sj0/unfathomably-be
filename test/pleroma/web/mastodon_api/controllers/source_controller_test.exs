# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.SourceControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Repo
  alias Pleroma.User

  import Pleroma.Factory

  require Pleroma.Constants

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "GET /api/v1/sources" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "lists followed non-group ActivityPub actors", %{conn: conn, user: user} do
      source =
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
      {:ok, _, _} = User.follow(user, group)

      source_id = to_string(source.id)

      assert [
               %{
                 "id" => ^source_id,
                 "display_name" => "Writer",
                 "source_profile" => "activitypub_profile",
                 "relationship" => %{"following" => true}
               }
             ] =
               conn
               |> get("/api/v1/sources")
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
               |> get("/api/v1/sources?q=blog")
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
               |> get("/api/v1/sources/search?q=library")
               |> json_response(200)
    end

    test "classifies common source software from stable ActivityPub URL shapes", %{conn: conn} do
      cases = [
        {"https://longform.example.org/api/collections/notes", "Person", "writefreely",
         "WriteFreely"},
        {"https://gts.example.org/users/alice", "Person", "gotosocial", "GoToSocial"},
        {"https://snac.example.org/alice", "Person", "snac", "snac"},
        {"https://torsi.ca/users/9g05u6rvhh", "Person", "iceshrimp", "Iceshrimp"},
        {"https://video.example.org/federation/user/streamer", "Service", "owncast", "Owncast"},
        {"https://calckey.example.org/users/9i20j8bbu5dipj8c", "Person", "misskey", "Misskey"}
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

  describe "POST /api/v1/sources/:id/follow" do
    setup do: oauth_access(["follow", "write:follows", "read:follows"])

    test "follows and unfollows a source through CommonAPI follow state", %{conn: conn} do
      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "local-source",
          ap_id: "http://mastodon.example.org/users/local-source",
          inbox: "http://mastodon.example.org/inbox"
        )

      source_id = to_string(source.id)

      assert %{"id" => ^source_id, "following" => false, "requested" => true} =
               conn
               |> post("/api/v1/sources/#{source.id}/follow")
               |> json_response(200)

      assert %{"id" => ^source_id, "following" => false, "requested" => false} =
               conn
               |> post("/api/v1/sources/#{source.id}/unfollow")
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

  describe "GET /api/v1/timelines/sources" do
    setup do: oauth_access(["read:statuses"])

    test "returns root posts from followed sources", %{conn: conn, user: user} do
      source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "writer@example.org",
          ap_id: "https://example.org/users/writer"
        )

      unfollowed_source =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "other@example.org",
          ap_id: "https://example.org/users/other"
        )

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "videos@example.org",
          ap_id: "https://example.org/c/videos"
        )

      {:ok, _, _} = Pleroma.FollowingRelationship.follow(user, source, :follow_accept)
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
               |> get("/api/v1/timelines/sources")
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
end
