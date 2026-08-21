# Unfathomably BE
# ----------------
#
# File: workers/nostr_profile_backfill_worker_test.exs
#
# Purpose:
#   Prove that native Nostr profile hydration survives event ordering and relay
#   propagation delays.
#
# Responsibilities:
#   - recover profile metadata stored before its mirror User exists
#   - preserve useful Nostr names when display_name is blank
#   - exercise the periodic unhydrated-profile recovery path without networking
#
# This file intentionally does NOT connect to public relays or test WebSocket
# transport behavior.

defmodule Pleroma.Workers.NostrProfileBackfillWorkerTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Workers.NostrNIP05VerificationWorker
  alias Pleroma.Workers.NostrProfileBackfillWorker
  alias Pleroma.Workers.NostrProfileSweepWorker

  @relay_url "wss://nostr.example"

  setup do
    clear_config([Pleroma.Nostr],
      enabled: true,
      bridge_secret: String.duplicate("bridge-secret-", 3),
      relay_url: "wss://local.example/relay",
      external_relays: [@relay_url],
      discovery_relays: [],
      response_relays: [],
      allow_user_relays: true
    )
  end

  test "reprojects stored kind-0 metadata after its mirror is created" do
    private_key = String.duplicate("7", 64)

    content =
      Jason.encode!(%{
        "display_name" => "",
        "name" => "Recovered contact",
        "about" => "Metadata arrived before the contact list.",
        "nip05" => "contact@example.com"
      })

    assert {:ok, event} = Protocol.sign_event(0, [], content, private_key)
    assert {:ok, _stored, true} = Store.put(event, relay_url: @relay_url)

    assert {:ok, user} =
             Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [@relay_url]})

    assert user.name == "Nostr #{String.slice(event["pubkey"], 0, 12)}"

    assert :ok =
             NostrProfileBackfillWorker.perform(%Oban.Job{
               args: %{"pubkey" => event["pubkey"]}
             })

    hydrated = Repo.get!(User, user.id)
    assert hydrated.name == "Recovered contact"
    assert hydrated.raw_bio == "Metadata arrived before the contact list."

    entity = Identity.get_profile(event["pubkey"])
    assert entity.metadata["profile_event_id"] == event["id"]
    assert entity.metadata["nip05"] == nil
    assert entity.metadata["nip05_claim"] == "contact@example.com"

    assert_enqueued(
      worker: NostrNIP05VerificationWorker,
      args: %{
        "entity_id" => entity.id,
        "event_id" => event["id"],
        "claim" => "contact@example.com"
      }
    )
  end

  test "periodic recovery batches stored metadata without a relay request" do
    private_keys = [String.duplicate("8", 64), String.duplicate("9", 64)]

    users =
      Enum.map(private_keys, fn private_key ->
        expected_name = "Stored #{String.first(private_key)}"

        assert {:ok, event} =
                 Protocol.sign_event(
                   0,
                   [],
                   Jason.encode!(%{"name" => expected_name}),
                   private_key
                 )

        assert {:ok, _stored, true} = Store.put(event, relay_url: @relay_url)

        assert {:ok, user} =
                 Identity.resolve(%{
                   type: :profile,
                   pubkey: event["pubkey"],
                   relays: [@relay_url]
                 })

        {user, event, expected_name}
      end)

    assert :ok = NostrProfileSweepWorker.perform(%Oban.Job{args: %{}})

    Enum.each(users, fn {user, event, expected_name} ->
      assert Repo.get!(User, user.id).name == expected_name
      assert Identity.get_profile(event["pubkey"]).metadata["profile_event_id"] == event["id"]
    end)
  end
end

# end of workers/nostr_profile_backfill_worker_test.exs
