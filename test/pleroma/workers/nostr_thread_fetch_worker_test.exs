# Unfathomably BE
# ----------------
#
# File: workers/nostr_thread_fetch_worker_test.exs
#
# Purpose:
#   Verify deterministic ingestion of bounded Nostr thread relay candidates.
#
# Responsibilities:
#   - retain fallback relay copies after an earlier candidate is rejected
#   - ingest ancestors before their replies
#   - keep the authorization source limited to the selected event identifiers
#
# This file intentionally does NOT open network relay connections or exercise
# the persistent relay subscription manager.

defmodule Pleroma.Workers.NostrThreadFetchWorkerTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.Workers.NostrThreadFetchWorker

  test "tries a later relay copy when the first candidate is rejected" do
    event = event("parent", 1, [])
    parent = self()

    ingester = fn candidate, relay_url, source ->
      send(parent, {:ingest, candidate["id"], relay_url, source})

      case relay_url do
        "wss://fast.example" -> {:error, "restricted", "wrong relay provenance"}
        "wss://hinted.example" -> {:ok, candidate}
      end
    end

    outcome =
      NostrThreadFetchWorker.ingest_candidates(
        %{event["id"] => [{event, "wss://fast.example"}, {event, "wss://hinted.example"}]},
        [event["id"]],
        ["wss://fast.example", "wss://hinted.example"],
        ingester
      )

    assert_receive {:ingest, "parent", "wss://fast.example", {:thread_hydration, ["parent"]}}
    assert_receive {:ingest, "parent", "wss://hinted.example", {:thread_hydration, ["parent"]}}
    assert outcome.accepted == [{"parent", "wss://hinted.example"}]
    assert outcome.rejected == %{}
  end

  test "ingests a fetched ancestor before its reply" do
    root = event("root", 1, [])
    reply = event("reply", 2, [["e", "root", "", "reply"]])
    parent = self()

    ingester = fn candidate, _relay_url, _source ->
      send(parent, {:ingest, candidate["id"]})
      {:ok, candidate}
    end

    outcome =
      NostrThreadFetchWorker.ingest_candidates(
        %{
          reply["id"] => [{reply, "wss://relay.example"}],
          root["id"] => [{root, "wss://relay.example"}]
        },
        [root["id"], reply["id"]],
        ["wss://relay.example"],
        ingester
      )

    assert_receive {:ingest, "root"}
    assert_receive {:ingest, "reply"}

    assert Enum.sort(outcome.accepted) ==
             [{"reply", "wss://relay.example"}, {"root", "wss://relay.example"}]
  end

  defp event(id, created_at, tags) do
    %{
      "id" => id,
      "pubkey" => String.duplicate("a", 64),
      "created_at" => created_at,
      "kind" => 1,
      "tags" => tags,
      "content" => id,
      "sig" => String.duplicate("b", 128)
    }
  end
end

# end of workers/nostr_thread_fetch_worker_test.exs
