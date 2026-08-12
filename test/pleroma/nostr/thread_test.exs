# Unfathomably BE
# ----------------
#
# File: test/pleroma/nostr/thread_test.exs
#
# Purpose:
#   Verify Nostr reply ancestry parsing across NIP-10 and NIP-22.
#
# Responsibilities:
#   - retain marked NIP-10 reply behavior
#   - recognize NIP-22's lowercase immediate-parent event tag
#   - include the NIP-22 parent in bounded ancestor hydration
#
# This file intentionally does NOT contact relays or project ActivityPub data.

defmodule Pleroma.Nostr.ThreadTest do
  use ExUnit.Case, async: true

  alias Pleroma.Nostr.Thread

  test "uses the NIP-22 lowercase event tag as the immediate parent" do
    root_id = String.duplicate("a", 64)
    parent_id = String.duplicate("b", 64)
    root_pubkey = String.duplicate("c", 64)
    parent_pubkey = String.duplicate("d", 64)

    event = %{
      "kind" => 1_111,
      "tags" => [
        ["E", root_id, "wss://relay.example", root_pubkey],
        ["K", "1"],
        ["P", root_pubkey],
        ["e", parent_id, "wss://relay.example", parent_pubkey],
        ["k", "1"],
        ["p", parent_pubkey]
      ]
    }

    assert Thread.reply_id(event) == parent_id
    assert parent_id in Thread.reference_ids(event)
    assert root_id in Thread.reference_ids(event)
  end

  test "keeps marked NIP-10 reply tags authoritative" do
    root_id = String.duplicate("e", 64)
    parent_id = String.duplicate("f", 64)

    event = %{
      "kind" => 1,
      "tags" => [
        ["e", root_id, "wss://relay.example", "root"],
        ["e", parent_id, "wss://relay.example", "reply"]
      ]
    }

    assert Thread.reply_id(event) == parent_id
  end
end

# end of test/pleroma/nostr/thread_test.exs
