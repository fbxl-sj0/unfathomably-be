# Unfathomably BE
# ----------------
#
# File: nostr/events_test.exs
#
# Purpose:
#   Cover NIP-52 and NIP-53 validation and ActivityPub Event projection.
#
# Responsibilities:
#   - prove valid calendar events become native Event objects
#   - prove live announcements retain stream and presentation metadata
#   - reject malformed live-chat addresses
#
# This file intentionally does NOT connect to relays or mutate remote events.

defmodule Pleroma.Nostr.EventsTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Nostr.Events

  test "projects a NIP-52 time event into the native ActivityPub Event shape" do
    event = %{
      "kind" => 31_923,
      "tags" => [
        ["d", "summer-meetup"],
        ["title", "Summer meetup"],
        ["start", "1785600000"],
        ["end", "1785607200"],
        ["location", "Community hall"]
      ]
    }

    assert :ok = Events.validate(event)

    object = Events.put_object_metadata(%{"attachment" => []}, event)

    assert object["type"] == "Event"
    assert object["name"] == "Summer meetup"
    assert object["joinMode"] == "free"
    assert object["location"] == %{"type" => "Place", "name" => "Community hall"}
    assert is_binary(object["startTime"])
  end

  test "projects a NIP-53 live announcement with its stream link" do
    event = %{
      "kind" => 30_311,
      "tags" => [
        ["d", "weekly-stream"],
        ["title", "Weekly stream"],
        ["streaming", "https://video.example/live.m3u8"],
        ["status", "live"]
      ]
    }

    assert :ok = Events.validate(event)

    object = Events.put_object_metadata(%{"attachment" => []}, event)

    assert object["type"] == "Event"
    assert object["isLiveBroadcast"] == true
    assert object["url"] == "https://video.example/live.m3u8"
    assert object["https://unfathomably.social/ns#family"] == "video"
    assert Enum.any?(object["attachment"], &(&1["name"] == "Live stream"))
  end

  test "rejects live chat without a NIP-53 activity address" do
    assert {:error, "invalid", "live chat requires a valid live activity address"} =
             Events.validate_chat(%{"kind" => 1_311, "tags" => [["a", "not-an-address"]]})
  end
end

# end of nostr/events_test.exs
