# Unfathomably BE
# ----------------
#
# File: test/pleroma/nostr/protocol_test.exs
#
# Purpose:
#   Exercise the security boundary around untrusted Nostr protocol messages.
#
# Responsibilities:
#   - prove valid bridge signatures round-trip
#   - reject event tampering
#   - prove arbitrary tag names do not create VM atoms
#   - enforce bounded and dynamic relay filters
#
# This file intentionally does NOT exercise network relays or ActivityPub
# translation; those are covered by the federation smoke harness.

defmodule Pleroma.Nostr.ProtocolTest do
  use ExUnit.Case, async: true

  alias Pleroma.Nostr.Protocol

  @private_key String.duplicate("1", 64)

  test "signs and validates canonical NIP-01 events" do
    assert {:ok, event} =
             Protocol.sign_event(1, [["t", "unfathomably"]], "hello", @private_key,
               created_at: 1_700_000_000
             )

    assert {:ok, ^event} = Protocol.validate_event(event)
  end

  test "allows bounded NIP-02 contact lists larger than ordinary event tag lists" do
    tags = Enum.map(1..688, &["p", String.pad_leading(Integer.to_string(&1, 16), 64, "0")])

    assert {:ok, _event} =
             Protocol.sign_event(3, tags, "", @private_key, created_at: 1_700_000_000)

    assert {:error, :too_many_tags} =
             Protocol.sign_event(1, tags, "not a contact list", @private_key,
               created_at: 1_700_000_000
             )
  end

  test "allows bounded NIP-65 relay lists larger than ordinary event tag lists" do
    tags = Enum.map(1..256, &["r", "wss://relay-#{&1}.example"])

    assert {:ok, _event} =
             Protocol.sign_event(10_002, tags, "", @private_key, created_at: 1_700_000_000)
  end

  test "allows bounded NIP-29 group role lists larger than ordinary event tag lists" do
    tags = Enum.map(1..640, &["p", String.pad_leading(Integer.to_string(&1, 16), 64, "0")])

    for kind <- [39_001, 39_002] do
      assert {:ok, _event} =
               Protocol.sign_event(kind, tags, "", @private_key, created_at: 1_700_000_000)
    end
  end

  test "rejects NIP-29 group role lists above the explicit list bound" do
    tags =
      Enum.map(1..1_025, &["p", String.pad_leading(Integer.to_string(&1, 16), 64, "0")])

    assert {:error, :too_many_tags} =
             Protocol.sign_event(39_002, tags, "", @private_key, created_at: 1_700_000_000)
  end

  test "rejects content changed after signing" do
    assert {:ok, event} =
             Protocol.sign_event(1, [], "original", @private_key, created_at: 1_700_000_000)

    assert {:error, _reason} = event |> Map.put("content", "changed") |> Protocol.validate_event()
  end

  test "does not intern untrusted tag names" do
    tag_name = "untrusted_#{System.unique_integer([:positive])}"
    refute existing_atom?(tag_name)

    assert {:ok, event} =
             Protocol.sign_event(1, [[tag_name, "value"]], "hello", @private_key,
               created_at: 1_700_000_000
             )

    assert {:ok, _event} = Protocol.validate_event(event)
    refute existing_atom?(tag_name)
  end

  test "validates dynamic tag filters and matches without atom conversion" do
    assert {:ok, [filter]} =
             Protocol.validate_filters([
               %{"kinds" => [1], "#h" => ["unfathomably"], "limit" => 25}
             ])

    assert {:ok, event} =
             Protocol.sign_event(1, [["h", "unfathomably"]], "group post", @private_key,
               created_at: 1_700_000_000
             )

    assert Protocol.matches?(event, filter)
    refute Protocol.matches?(event, Map.put(filter, "#h", ["other-group"]))
  end

  test "rejects unbounded relay filters" do
    assert {:error, :invalid_filter} = Protocol.validate_filters([%{"limit" => 100_000_000}])
    assert {:error, :invalid_filter} = Protocol.validate_filters([%{"unknown" => ["value"]}])
  end

  test "validates and ranks NIP-50 searches by match quality" do
    assert {:ok, filter} = Protocol.validate_filter(%{"search" => "nostr bridge", "limit" => 5})

    exact = %{"content" => "A Nostr bridge for ActivityPub"}
    scattered = %{"content" => "Nostr can use a useful protocol bridge"}

    assert Protocol.matches?(exact, filter)
    assert Protocol.matches?(scattered, filter)

    assert Protocol.search_score(exact, filter["search"]) >
             Protocol.search_score(scattered, filter["search"])
  end

  test "classifies the NIP-01 replaceable event kinds exactly" do
    pubkey = String.duplicate("a", 64)

    assert Protocol.replace_key(%{"kind" => 0, "pubkey" => pubkey}) == "0:#{pubkey}"
    assert Protocol.replace_key(%{"kind" => 3, "pubkey" => pubkey}) == "3:#{pubkey}"
    assert Protocol.replace_key(%{"kind" => 10_000, "pubkey" => pubkey}) == "10000:#{pubkey}"
    assert Protocol.replace_key(%{"kind" => 19_999, "pubkey" => pubkey}) == "19999:#{pubkey}"

    assert is_nil(Protocol.replace_key(%{"kind" => 1, "pubkey" => pubkey}))
    assert is_nil(Protocol.replace_key(%{"kind" => 2, "pubkey" => pubkey}))
  end

  defp existing_atom?(value) do
    _atom = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end
end

# end of test/pleroma/nostr/protocol_test.exs
