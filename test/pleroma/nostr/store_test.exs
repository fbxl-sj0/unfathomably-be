# Unfathomably BE
# ----------------
#
# File: test/pleroma/nostr/store_test.exs
#
# Purpose:
#   Exercise persistent Nostr event replacement semantics.
#
# Responsibilities:
#   - prove replaceable event selection is independent of relay arrival order
#   - preserve the NIP-01 lowest-identifier rule for timestamp ties
#
# This file intentionally does NOT exercise relay sockets, bridge translation,
# or ActivityPub projection behavior.

defmodule Pleroma.Nostr.StoreTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store

  @private_key String.duplicate("1", 64)
  @created_at 1_700_000_000

  test "keeps the lowest event id when replaceable timestamps tie" do
    {winner_last, loser_first} = replacement_pair("winner-last")

    assert {:ok, %Event{id: loser_id}, true} = Store.put(loser_first)
    assert loser_id == loser_first["id"]
    assert {:ok, %Event{id: winner_id}, true} = Store.put(winner_last)
    assert winner_id == winner_last["id"]
    assert %Event{id: ^winner_id} = Store.get(winner_id)
    refute Store.get(loser_id)

    {winner_first, loser_last} = replacement_pair("winner-first")

    assert {:ok, %Event{id: second_winner_id}, true} = Store.put(winner_first)
    assert second_winner_id == winner_first["id"]

    assert {:ok, %Event{id: ^second_winner_id}, false} = Store.put(loser_last)
    assert %Event{id: ^second_winner_id} = Store.get(second_winner_id)
    refute Store.get(loser_last["id"])
  end

  defp replacement_pair(group_id) do
    events =
      for marker <- ["1", "2"] do
        {:ok, event} =
          Protocol.sign_event(
            39_002,
            [["d", group_id], ["p", String.duplicate(marker, 64)]],
            "",
            @private_key,
            created_at: @created_at
          )

        event
      end

    [winner, loser] = Enum.sort_by(events, & &1["id"])
    {winner, loser}
  end
end

# end of test/pleroma/nostr/store_test.exs
