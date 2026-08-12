# Unfathomably Nostr bridge tests
#
# File: profile_extensions_test.exs
# Purpose: Guard NIP-38 and NIP-58 validation and presentation boundaries.
# Responsibilities: Test status clearing, expiry, and badge-reference limits.
# This file intentionally does not contact external relays.

defmodule Pleroma.Nostr.ProfileExtensionsTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Nostr.ProfileExtensions

  @pubkey String.duplicate("a", 64)
  @event_id String.duplicate("b", 64)

  test "parses a bounded live status" do
    event = %{
      "id" => @event_id,
      "pubkey" => @pubkey,
      "kind" => 30_315,
      "created_at" => 1_700_000_000,
      "content" => "Building",
      "tags" => [["d", "general"], ["r", "https://example.com/work"]]
    }

    assert :ok = ProfileExtensions.validate(event)

    assert {:set, %{"type" => "general", "content" => "Building"}} =
             ProfileExtensions.status_payload(event)
  end

  test "clears expired live status instead of presenting stale data" do
    event = %{
      "id" => @event_id,
      "pubkey" => @pubkey,
      "kind" => 30_315,
      "created_at" => 1,
      "content" => "Old song",
      "tags" => [["d", "music"], ["expiration", "2"]]
    }

    assert {:clear, "music"} = ProfileExtensions.status_payload(event)
  end

  test "rejects a badge award without recipients" do
    event = %{
      "kind" => 8,
      "tags" => [["a", "30009:#{@pubkey}:helper"]]
    }

    assert {:error, "invalid", _reason} = ProfileExtensions.validate(event)
  end

  test "accepts bounded NIP-58 badge identifiers with spaces" do
    badge_identifier = "AskNostr Contributor "
    coordinate = "30009:#{@pubkey}:#{badge_identifier}"

    assert :ok =
             ProfileExtensions.validate(%{
               "kind" => 30_009,
               "tags" => [["d", badge_identifier]]
             })

    assert :ok =
             ProfileExtensions.validate(%{
               "kind" => 10_008,
               "tags" => [["a", coordinate], ["e", @event_id]]
             })
  end

  test "accepts a valid selection larger than the local display limit" do
    tags =
      1..12
      |> Enum.flat_map(fn index ->
        coordinate = "30009:#{@pubkey}:badge-#{index}"
        [["a", coordinate], ["e", @event_id]]
      end)

    assert :ok =
             ProfileExtensions.validate(%{
               "kind" => 10_008,
               "tags" => tags
             })
  end

  test "rejects malformed references in a large badge selection" do
    valid_pairs =
      1..8
      |> Enum.flat_map(fn index ->
        coordinate = "30009:#{@pubkey}:badge-#{index}"
        [["a", coordinate], ["e", @event_id]]
      end)

    assert {:error, "invalid", _reason} =
             ProfileExtensions.validate(%{
               "kind" => 10_008,
               "tags" => valid_pairs ++ [["a", "not-a-coordinate"], ["e", @event_id]]
             })
  end

  test "rejects control characters in remote badge identifiers" do
    assert {:error, "invalid", _reason} =
             ProfileExtensions.validate(%{
               "kind" => 30_009,
               "tags" => [["d", "badge\nidentifier"]]
             })
  end
end

# end of profile_extensions_test.exs
