# Unfathomably BE
# ----------------
#
# File: nostr/protocol_extensions_test.exs
#
# Purpose:
#   Cover bounded validation for the NIP-56 and NIP-88 bridge extensions.
#
# Responsibilities:
#   - prove valid poll options become CommonAPI poll parameters
#   - reject malformed poll responses before storage or projection
#   - require report targets and recognized report types
#
# This file intentionally does NOT contact relays or mutate remote accounts.

defmodule Pleroma.Nostr.ProtocolExtensionsTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Nostr.Moderation
  alias Pleroma.Nostr.Poll

  test "converts a bounded NIP-88 poll into CommonAPI parameters" do
    event = %{
      "kind" => 1_068,
      "tags" => [
        ["option", "yes", "Yes"],
        ["option", "no", "No"],
        ["polltype", "singlechoice"],
        ["endsAt", to_string(System.system_time(:second) + 600)]
      ]
    }

    assert {:ok, %{options: ["Yes", "No"], expires_in: expires_in, multiple: false}} =
             Poll.inbound_params(event)

    assert expires_in in 590..600
  end

  test "rejects poll responses without a valid referenced poll" do
    assert {:error, "invalid", "poll response requires a valid poll id"} =
             Poll.validate_response(%{
               "kind" => 1_018,
               "tags" => [["e", "not-an-event"], ["response", "yes"]]
             })
  end

  test "requires a NIP-56 target and recognized report type" do
    pubkey = String.duplicate("a", 64)

    assert :ok =
             Moderation.validate(%{
               "kind" => 1_984,
               "content" => "Repeated unsolicited posts",
               "tags" => [["p", pubkey, "spam"]]
             })

    assert {:error, "invalid", "reports require a supported report type"} =
             Moderation.validate(%{
               "kind" => 1_984,
               "content" => "",
               "tags" => [["p", pubkey, "surprising"]]
             })
  end
end

# end of nostr/protocol_extensions_test.exs
