# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ActorCollectionRefreshWorkerTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Workers.ActorCollectionRefreshWorker

  import Pleroma.Factory

  test "keeps optional remote collection work bounded" do
    assert ActorCollectionRefreshWorker.timeout(%Oban.Job{}) == :timer.seconds(35)
  end

  test "rejects malformed jobs without retrying them" do
    assert ActorCollectionRefreshWorker.perform(%Oban.Job{args: %{}}) ==
             {:cancel, :bad_request}
  end

  test "rejects a stale aggregate Feed collection before fetching it" do
    feed =
      insert(:user,
        local: false,
        actor_type: "Feed",
        ap_id: "https://feeds.example/feeds/technology",
        following_address: "https://feeds.example/feeds/technology/following"
      )

    assert ActorCollectionRefreshWorker.perform(%Oban.Job{
             args: %{
               "ap_id" => feed.ap_id,
               "kind" => "aggregate_feed",
               "collection" => "https://attacker.example/feeds/technology/following"
             }
           }) == {:cancel, :stale_collection}
  end

  test "cancels a featured collection refresh while its failure cooldown is active" do
    collection = "https://collection-cooldown.example/users/alice/collections/featured"

    user =
      insert(:user,
        local: false,
        ap_id: "https://collection-cooldown.example/users/alice",
        featured_address: collection
      )

    Cachex.put(:failed_featured_collection_cache, collection, true)
    on_exit(fn -> Cachex.del(:failed_featured_collection_cache, collection) end)

    assert ActorCollectionRefreshWorker.perform(%Oban.Job{
             args: %{
               "ap_id" => user.ap_id,
               "kind" => "featured",
               "collection" => collection
             }
           }) == {:cancel, :cooldown}
  end
end

# end of test/pleroma/workers/actor_collection_refresh_worker_test.exs
