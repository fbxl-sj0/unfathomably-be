# Pleroma: A lightweight social networking server
# Copyright © 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.RichMedia.CardTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase, async: false

  alias Pleroma.Object
  alias Pleroma.Tests.ObanHelpers
  alias Pleroma.UnstubbedConfigMock, as: ConfigMock
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.RichMedia.Card
  alias Pleroma.Workers.RichMediaWorker

  import Mox
  import Pleroma.Factory
  import Tesla.Mock

  setup do
    mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)

    Mox.stub_with(Pleroma.CachexMock, Pleroma.NullCache)

    ConfigMock
    |> stub_with(Pleroma.Test.StaticConfig)

    :ok
  end

  setup do: clear_config([:rich_media, :enabled], true)

  test "treats malformed urls as uncrawlable" do
    assert Card.get_by_url("https://%") == :error
    assert is_nil(Card.get_or_backfill_by_url("https://%"))
  end

  test "crawls URL in activity" do
    user = insert(:user)

    url = "https://example.com/ogp"
    url_hash = Card.url_to_hash(url)

    {:ok, activity} =
      CommonAPI.post(user, %{
        status: "[test](#{url})",
        content_type: "text/markdown"
      })

    Pleroma.Web.ActivityPub.ActivityPubMock
    |> expect(:stream_out, fn ^activity -> nil end)

    assert_enqueued(
      worker: RichMediaWorker,
      args: %{"op" => "backfill", "url" => url, "activity_id" => activity.id}
    )

    ObanHelpers.perform_all()

    assert %Card{url_hash: ^url_hash, fields: _} = Card.get_by_activity(activity)
  end

  test "deduplicates stream variants of the same activity backfill" do
    url = "https://example.com/ogp"
    activity_id = "rich-media-activity"

    assert is_nil(Card.get_or_backfill_by_url(url, activity_id: activity_id))

    assert is_nil(
             Card.get_or_backfill_by_url(url,
               activity_id: activity_id,
               opts: %{stream: false}
             )
           )

    assert [_job] = all_enqueued(worker: RichMediaWorker)
  end

  test "recrawls URLs on status edits/updates" do
    original_url = "https://google.com/"
    original_url_hash = Card.url_to_hash(original_url)
    updated_url = "https://yahoo.com/"
    updated_url_hash = Card.url_to_hash(updated_url)

    user = insert(:user)
    {:ok, activity} = CommonAPI.post(user, %{status: "I like this site #{original_url}"})

    # Force a backfill
    Card.get_by_activity(activity, %{stream: false})
    ObanHelpers.perform_all()

    assert match?(
             %Card{url_hash: ^original_url_hash, fields: _},
             Card.get_by_activity(activity)
           )

    activity = Pleroma.Activity.get_by_id(activity.id)

    {:ok, _} = CommonAPI.update(user, activity, %{status: "I like this site #{updated_url}"})

    activity = Pleroma.Activity.get_by_id(activity.id)

    # Force a backfill
    Card.get_by_activity(activity, %{stream: false})
    ObanHelpers.perform_all()

    assert match?(
             %Card{url_hash: ^updated_url_hash, fields: _},
             Card.get_by_activity(activity)
           )
  end

  test "refuses to crawl URL in activity from ignored host/domain" do
    clear_config([:rich_media, :ignore_hosts], ["example.com"])

    user = insert(:user)

    url = "https://example.com/ogp"

    {:ok, activity} =
      CommonAPI.post(user, %{
        status: "[test](#{url})",
        content_type: "text/markdown"
      })

    refute_enqueued(
      worker: RichMediaWorker,
      args: %{"op" => "backfill", "url" => url, "activity_id" => activity.id}
    )
  end

  test "refuses to crawl URL in sensitive activity" do
    user = insert(:user)

    url = "https://example.com/ogp"

    {:ok, activity} =
      CommonAPI.post(user, %{
        status: "[test](#{url})",
        content_type: "text/markdown",
        sensitive: true
      })

    assert %Object{data: %{"sensitive" => true}} = Object.normalize(activity, fetch: false)
    assert is_nil(Card.get_by_activity(activity))

    refute_enqueued(
      worker: RichMediaWorker,
      args: %{"op" => "backfill", "url" => url, "activity_id" => activity.id}
    )
  end

  test "marks nsfw tagged activity sensitive and refuses to crawl its URL" do
    user = insert(:user)

    url = "https://example.com/ogp"

    {:ok, activity} =
      CommonAPI.post(user, %{
        status: "#{url} #nsfw"
      })

    assert %Object{data: %{"sensitive" => true}} = Object.normalize(activity, fetch: false)
    assert is_nil(Card.get_by_activity(activity))

    refute_enqueued(
      worker: RichMediaWorker,
      args: %{"op" => "backfill", "url" => url, "activity_id" => activity.id}
    )
  end
end
