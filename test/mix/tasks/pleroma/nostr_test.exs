# Unfathomably BE
# ----------------
#
# File: test/mix/tasks/pleroma/nostr_test.exs
#
# Purpose:
#   Verify bounded, resumable Nostr media maintenance.
#
# Responsibilities:
#   - prove the backfill scope contains only mapped content events
#   - prove event-id cursors advance deterministically
#   - prove task output provides an exact continuation cursor
#
# This file intentionally does NOT test Nostr media parsing or ActivityPub
# attachment rendering; those behaviors belong to their subsystem tests.

defmodule Mix.Tasks.Pleroma.NostrTest do
  use Pleroma.DataCase, async: true

  import ExUnit.CaptureIO, only: [capture_io: 1]
  import Pleroma.Factory

  alias Mix.Tasks.Pleroma.Nostr, as: NostrTask
  alias Pleroma.Nostr.Event
  alias Pleroma.Repo

  @first_id String.duplicate("1", 64)
  @second_id String.duplicate("2", 64)
  @third_id String.duplicate("3", 64)
  @fourth_id String.duplicate("4", 64)
  @pubkey String.duplicate("a", 64)

  test "media_backfill_query exposes only mapped content events after the cursor" do
    activity = insert(:note_activity)

    insert_event(@first_id, 1, activity.id)
    insert_event(@second_id, 7, activity.id)
    insert_event(@third_id, 1, nil)
    insert_event(@fourth_id, 30_023, activity.id)

    assert [event] = NostrTask.media_backfill_query(@first_id) |> Repo.all()
    assert event.id == @fourth_id
  end

  test "backfill_media reports a resumable cursor for a bounded batch" do
    activity = insert(:note_activity)
    insert_event(@first_id, 1, activity.id)
    insert_event(@second_id, 1, activity.id)

    output = capture_io(fn -> NostrTask.run(["backfill_media", "--limit", "1"]) end)

    assert output =~ "scanned=1"
    assert output =~ "complete=false"
    assert output =~ "next_after_id=#{@first_id}"
  end

  defp insert_event(id, kind, activity_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Event{}
    |> Event.changeset(%{
      id: id,
      pubkey: @pubkey,
      kind: kind,
      created_at: now,
      data: %{"id" => id, "pubkey" => @pubkey, "kind" => kind, "tags" => []},
      ap_activity_id: activity_id
    })
    |> Repo.insert!()
  end
end

# end of test/mix/tasks/pleroma/nostr_test.exs
