# Unfathomably BE
# ----------------
#
# File: nostr/private_messages_test.exs
#
# Purpose:
#   Cover the cryptographic and structural boundary for native Nostr chats.
#
# Responsibilities:
#   - prove a NIP-17 gift wrap can be validated and decrypted
#   - prove malformed outer recipient tags are rejected
#   - keep strict group relays out of private-message relay metadata
#
# This file intentionally does NOT contact public relays or create remote
# accounts.

defmodule Pleroma.Nostr.PrivateMessagesTest do
  use Pleroma.DataCase

  alias Nostr.Event
  alias Nostr.NIP17
  alias Nostr.Tag
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.PrivateMessages
  alias Pleroma.User

  @sender_key String.duplicate("01", 32)
  @recipient_key String.duplicate("02", 32)

  test "validates and decrypts a NIP-17 gift wrap without parsing arbitrary tag atoms" do
    recipient_pubkey = Nostr.Crypto.pubkey(@recipient_key)
    sender_pubkey = Nostr.Crypto.pubkey(@sender_key)

    assert {:ok, gift_wraps} = NIP17.send_dm(@sender_key, [recipient_pubkey], "private hello")

    gift_wrap = Enum.find(gift_wraps, &(&1.recipient == recipient_pubkey))
    event = wire_event(gift_wrap.event)

    assert :ok = PrivateMessages.validate(event)

    assert {:ok, message} =
             PrivateMessages.decode_message(event, @recipient_key, recipient_pubkey)

    assert message.content == "private hello"
    assert message.sender_pubkey == sender_pubkey
    assert message.receivers == [recipient_pubkey]
  end

  test "rejects a gift wrap with additional outer tags" do
    recipient_pubkey = Nostr.Crypto.pubkey(@recipient_key)
    assert {:ok, gift_wraps} = NIP17.send_dm(@sender_key, [recipient_pubkey], "hello")

    event =
      gift_wraps
      |> Enum.find(&(&1.recipient == recipient_pubkey))
      |> Map.fetch!(:event)
      |> wire_event()
      |> Map.update!("tags", &(&1 ++ [["unexpected", "value"]]))

    assert {:error, "invalid", _message} = PrivateMessages.validate(event)
  end

  test "does not advertise or publish private-message metadata to group-only relays" do
    local_relay = "wss://local.example/relay"
    profile_relay = "wss://profiles.example"
    group_relay = "wss://groups.example"

    clear_config([Pleroma.Nostr, :relay_url], local_relay)
    clear_config([Pleroma.Nostr, :external_relays], [profile_relay])
    clear_config([Pleroma.Nostr, :profile_discovery_relays], [])
    clear_config([Pleroma.Nostr, :group_relays], [group_relay])

    test_pid = self()

    publisher = fn event, relays, _mapping ->
      send(test_pid, {:published, event, relays})
      :ok
    end

    assert :ok =
             PrivateMessages.publish_relay_list(
               %User{local: true},
               %Entity{},
               @sender_key,
               [local_relay, profile_relay],
               publisher
             )

    assert_receive {:published, event, relays}
    assert Enum.sort(relays) == Enum.sort([local_relay, profile_relay])
    refute group_relay in relays
    refute ["relay", group_relay] in event["tags"]
  end

  test "accepts bounded interoperable metadata on a NIP-17 relay list" do
    event = %{
      "kind" => 10_050,
      "content" => "",
      "tags" => [
        ["relay", "wss://inbox.example"],
        ["alt", "Relay list to receive private messages"],
        ["client", "31990:#{String.duplicate("a", 64)}:example", "wss://apps.example"]
      ]
    }

    assert :ok = PrivateMessages.validate(event)
  end

  test "keeps NIP-17 relay destinations and metadata bounded" do
    too_many_relays =
      for relay_number <- 1..17 do
        ["relay", "wss://relay#{relay_number}.example"]
      end

    assert {:error, "invalid", _message} =
             PrivateMessages.validate(%{
               "kind" => 10_050,
               "content" => "",
               "tags" => too_many_relays ++ [["alt", "Private-message inboxes"]]
             })

    assert {:error, "invalid", _message} =
             PrivateMessages.validate(%{
               "kind" => 10_050,
               "content" => "",
               "tags" => [["relay", "wss://inbox.example"], ["unexpected", "value"]]
             })
  end

  defp wire_event(%Event{} = event) do
    %{
      "id" => event.id,
      "pubkey" => event.pubkey,
      "kind" => event.kind,
      "tags" => Enum.map(event.tags, &wire_tag/1),
      "created_at" => DateTime.to_unix(event.created_at),
      "content" => event.content,
      "sig" => event.sig
    }
  end

  defp wire_tag(%Tag{type: type, data: nil}), do: [Atom.to_string(type)]
  defp wire_tag(%Tag{type: type, data: data, info: info}), do: [Atom.to_string(type), data | info]
end

# end of nostr/private_messages_test.exs
