# Unfathomably BE
# ----------------
#
# File: workers/nostr_thread_repair_worker_test.exs
#
# Purpose:
#   Verify repair of a locally projected Nostr reply after its parent arrives.
#
# Responsibilities:
#   - attach a Nostr reply object to the projected parent object
#   - copy the parent's ActivityPub context to the reply activity and object
#   - replace a stale object-cache entry as part of the repair
#
# This file intentionally does NOT contact public Nostr relays or test the
# bounded relay-fetch stage that obtains missing ancestors.

defmodule Pleroma.Workers.NostrThreadRepairWorkerTest do
  use Pleroma.DataCase, async: false

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Nostr.Store
  alias Pleroma.Object
  alias Pleroma.Workers.NostrThreadRepairWorker

  test "refreshes the cached reply projection after attaching its parent" do
    parent_event_id = String.duplicate("a", 64)
    reply_event_id = String.duplicate("b", 64)
    parent_context = "https://social.example/contexts/nostr-thread"
    stale_context = "https://social.example/contexts/orphaned-reply"

    parent_object = insert(:note, data: %{"context" => parent_context})

    parent_activity =
      insert(:note_activity,
        note: parent_object,
        data_attrs: %{"context" => parent_context}
      )

    reply_object =
      insert(:note,
        data: %{
          "context" => stale_context,
          "inReplyTo" => nil
        }
      )

    reply_activity =
      insert(:note_activity,
        note: reply_object,
        data_attrs: %{"context" => stale_context}
      )

    {:ok, _parent_event, true} =
      Store.put(nostr_event(parent_event_id, []),
        ap_activity_id: parent_activity.id,
        ap_object_id: parent_object.data["id"]
      )

    {:ok, _reply_event, true} =
      Store.put(
        nostr_event(reply_event_id, [["e", parent_event_id, "", "reply"]]),
        ap_activity_id: reply_activity.id,
        ap_object_id: reply_object.data["id"]
      )

    # Warm the cache with the orphaned form to reproduce the live failure.
    assert %Object{data: %{"inReplyTo" => nil}} = Object.normalize(reply_activity, fetch: false)

    assert :ok =
             NostrThreadRepairWorker.perform(%Oban.Job{
               args: %{"event_id" => reply_event_id},
               attempt: 1
             })

    repaired_activity = Activity.get_by_id(reply_activity.id)
    repaired_object = Object.normalize(repaired_activity, fetch: false)

    assert repaired_activity.data["context"] == parent_context
    assert repaired_object.data["context"] == parent_context
    assert repaired_object.data["inReplyTo"] == parent_object.data["id"]
    assert NostrThreadRepairWorker.enqueue_for_activity(repaired_activity) == :complete
  end

  defp nostr_event(id, tags) do
    %{
      "id" => id,
      "pubkey" => String.duplicate("c", 64),
      "created_at" => DateTime.utc_now() |> DateTime.to_unix(),
      "kind" => 1,
      "tags" => tags,
      "content" => id,
      "sig" => String.duplicate("d", 128)
    }
  end
end

# end of workers/nostr_thread_repair_worker_test.exs
