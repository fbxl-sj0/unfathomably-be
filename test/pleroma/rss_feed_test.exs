# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.RSSFeedTest do
  use Pleroma.DataCase

  alias Pleroma.Activity
  alias Pleroma.FollowingRelationship
  alias Pleroma.RSSFeed
  alias Pleroma.Web.FederatedTarget

  import Pleroma.Factory

  @feed_url "https://feeds.example.test/feed.xml"
  @post_url "https://feeds.example.test/posts/1"
  @feed_body """
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0">
    <channel>
      <title>Example Feed</title>
      <description>Useful things from elsewhere.</description>
      <link>https://feeds.example.test/</link>
      <item>
        <title>First feed item</title>
        <link>#{@post_url}</link>
        <guid>first-feed-item</guid>
        <pubDate>Tue, 23 Jun 2026 10:00:00 GMT</pubDate>
        <description><![CDATA[<p>Hello from the feed.</p>]]></description>
      </item>
    </channel>
  </rss>
  """

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)

    Tesla.Mock.mock(fn
      %{method: :get, url: @feed_url} ->
        %Tesla.Env{
          status: 200,
          body: @feed_body,
          headers: [{"content-type", "application/rss+xml"}]
        }
    end)

    :ok
  end

  test "resolves a feed URL as a read-only source actor" do
    assert {:ok, source} = FederatedTarget.resolve_source(@feed_url)

    assert RSSFeed.rss_source?(source)
    assert source.ap_id == @feed_url
    assert source.actor_type == "Service"
    assert source.name == "Example Feed"
    assert source.inbox == nil
    assert FederatedTarget.source_profile(source) == "rss_feed"
    assert FederatedTarget.source_kind(source) == "rss_feed"
  end

  test "imports feed entries as deduplicated Article activities" do
    assert {:ok, source} = RSSFeed.resolve(@feed_url)

    assert {:ok, %{checked: 1, imported: 1}} = RSSFeed.import_source(source)
    assert {:ok, %{checked: 1, imported: 0}} = RSSFeed.import_source(source)

    activity =
      Activity
      |> where([a], a.actor == ^source.ap_id)
      |> where([a], fragment("?->>'type' = 'Create'", a.data))
      |> Activity.with_preloaded_object()
      |> Repo.one()

    assert activity.object.data["type"] == "Article"
    assert activity.object.data["name"] == "First feed item"
    assert activity.object.data["url"] == @post_url
    assert activity.object.data["attributedTo"] == source.ap_id
  end

  test "renders imported feed entries through the source item status path" do
    reader = insert(:user)

    assert {:ok, source} = RSSFeed.resolve(@feed_url)
    assert {:ok, _reader, source} = FollowingRelationship.follow(reader, source)

    assert {:ok, %{items: [item], next: nil, total_items: 1}} =
             FederatedTarget.source_items_result(source, %{"limit" => "4"}, reader)

    assert item.type == "Article"
    assert item.title == "First feed item"
    assert item.url == @post_url
    assert item.source_kind == "rss_feed"
    assert is_map(item.status)
    assert item.status.id
  end
end
