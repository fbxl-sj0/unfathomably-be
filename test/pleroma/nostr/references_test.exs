# Unfathomably Nostr bridge tests
#
# File: references_test.exs
# Purpose: Guard NIP-21 and NIP-27 reference translation boundaries.
# Responsibilities: Verify private-key exclusion and conservative fallbacks.
# This file intentionally does not exercise relay networking.

defmodule Pleroma.Nostr.ReferencesTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.References
  alias Pleroma.Repo

  describe "inbound/2" do
    test "never interprets Nostr private-key identifiers" do
      content =
        "Keep nostr:nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqlmqqc4 private"

      assert References.inbound(content, %{"tags" => []}) == content
    end

    test "preserves unknown portable event references" do
      {:ok, uri} = Nostr.NIP21.encode_note(String.duplicate("a", 64))
      content = "Unknown event #{uri}"

      assert References.inbound(content, %{"tags" => []}) == content
    end

    test "appends a known signed p-tag account as an ActivityPub mention" do
      user = insert(:user)
      pubkey = String.duplicate("a", 64)

      %Entity{}
      |> Entity.changeset(%{
        user_id: user.id,
        kind: "mirror_profile",
        pubkey: pubkey,
        relay_url: "wss://nostr.example"
      })
      |> Repo.insert!()

      event = %{"pubkey" => String.duplicate("b", 64), "tags" => [["p", pubkey]]}

      assert References.inbound("hello", event) == "hello\n\n@#{user.nickname}"

      object = References.put_inbound_mentions(%{"content" => "hello", "to" => []}, event)
      assert object["content"] =~ ~s(href="#{user.ap_id}")
      assert user.ap_id in object["to"]
      ap_id = user.ap_id

      assert [%{"type" => "Mention", "href" => ^ap_id}] =
               Enum.map(object["tag"], &Map.take(&1, ["type", "href"]))
    end
  end

  describe "outbound/2" do
    test "does not add notification tags to ordinary text" do
      assert {"ordinary text", []} = References.outbound("ordinary text", %{})
    end
  end
end

# end of references_test.exs
