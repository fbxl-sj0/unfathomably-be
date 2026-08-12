# Unfathomably: bounded post-follow ActivityPub backfill tests
#
# File: actor_outbox_backfill_worker_test.exs
#
# Purpose:
#   Verify that outbox item selection is bounded, canonical, and same-origin
#   before any durable remote-fetch jobs are scheduled.
#
# This file intentionally does not contact a remote ActivityPub server.

defmodule Pleroma.Workers.ActorOutboxBackfillWorkerTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Workers.ActorOutboxBackfillWorker

  test "selects bounded same-origin canonical identifiers" do
    actor = "https://social.example/users/alice"

    collection = %{
      "orderedItems" => [
        %{"id" => "https://social.example/activities/1"},
        "https://social.example/activities/2",
        %{"href" => "https://social.example/activities/3"},
        "https://other.example/activities/4",
        "javascript:alert(1)",
        nil
      ]
    }

    assert ActorOutboxBackfillWorker.collection_item_ids(collection, actor, 2) == [
             "https://social.example/activities/1",
             "https://social.example/activities/2"
           ]
  end

  test "does not collapse scheme or port when checking actor authority" do
    actor = "https://social.example/users/alice"

    collection = %{
      "items" => [
        "http://social.example/activities/http",
        "https://social.example:8443/activities/alternate-port",
        "https://social.example/activities/valid"
      ]
    }

    assert ActorOutboxBackfillWorker.collection_item_ids(collection, actor, 20) == [
             "https://social.example/activities/valid"
           ]
  end

  test "rejects local recursive references and credential-bearing URLs" do
    collection = %{
      "items" => [
        "https://user:password@remote.example/activities/1",
        "https://local.example/activities/2"
      ]
    }

    assert ActorOutboxBackfillWorker.collection_item_ids(
             collection,
             "https://remote.example/users/alice",
             20
           ) == []
  end
end

# end of actor_outbox_backfill_worker_test.exs
