# Unfathomably BE
# ----------------
#
# File: test/pleroma/nostr/mostr_compat_test.exs
#
# Purpose:
#   Prove that Mostr projections reconcile with signed native Nostr records.
#
# Responsibilities:
#   - deduplicate direct Mostr posts against native ActivityPub projections
#   - retarget ActivityPub replies and reposts from Mostr URLs
#   - reject unvalidated or ActivityPub-proxy Nostr mappings
#
# This file intentionally does NOT open relay connections or trust Mostr as a
# Nostr signing authority.

defmodule Pleroma.Nostr.MostrCompatTest do
  use Pleroma.DataCase, async: false

  import Pleroma.Factory

  alias Pleroma.Nostr.MostrCompat
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store
  alias Pleroma.Object

  @relay_url "wss://nostr.example"
  @private_key String.duplicate("1", 64)

  setup do
    clear_config([Pleroma.Nostr, :mostr_hosts], ["mostr.pub"])

    activity = insert(:note_activity)
    object = Object.normalize(activity, fetch: false)
    {:ok, event} = Protocol.sign_event(1, [], "native event", @private_key)
    {:ok, stored, true} = Store.put(event, relay_url: @relay_url)
    :ok = Store.map_activity(stored.id, activity.id, object.data["id"])

    %{activity: activity, event: event, object: object}
  end

  test "uses the native projection for a direct Mostr Create", %{
    activity: activity,
    event: event
  } do
    mostr_url = "https://mostr.pub/objects/#{event["id"]}"

    params = %{
      "id" => mostr_url <> "#create",
      "type" => "Create",
      "object" => %{"id" => mostr_url, "type" => "Note"}
    }

    assert {:ok, ^activity} =
             MostrCompat.handle_incoming(params, fn _params ->
               flunk("the Mostr fallback must not run for a validated native event")
             end)
  end

  test "recognizes Mostr's authoritative FEP-fffd note proxy", %{
    event: event,
    object: object
  } do
    {:ok, event_binary} = Base.decode16(event["id"], case: :lower)
    note = Bechamel.encode("note", event_binary)

    reference = %{
      "proxyOf" => [
        %{
          "authoritative" => true,
          "protocol" => "https://github.com/nostr-protocol/nostr",
          "proxied" => note
        }
      ]
    }

    assert MostrCompat.canonical_object_id(reference) == object.data["id"]
  end

  test "retargets replies and reposts to the native object", %{
    event: event,
    object: object
  } do
    mostr_url = "https://mostr.pub/objects/#{event["id"]}"

    reply = %{
      "id" => "https://remote.example/activities/reply",
      "type" => "Create",
      "object" => %{
        "id" => "https://remote.example/objects/reply",
        "type" => "Note",
        "inReplyTo" => mostr_url
      }
    }

    announce = %{
      "id" => "https://remote.example/activities/repost",
      "type" => "Announce",
      "object" => mostr_url
    }

    like = %{
      "id" => "https://remote.example/activities/like",
      "type" => "Like",
      "object" => mostr_url
    }

    assert {:fallback, rewritten_reply} =
             MostrCompat.handle_incoming(reply, &{:fallback, &1})

    assert get_in(rewritten_reply, ["object", "inReplyTo"]) == object.data["id"]

    assert {:fallback, rewritten_announce} =
             MostrCompat.handle_incoming(announce, &{:fallback, &1})

    assert rewritten_announce["object"] == object.data["id"]

    assert {:fallback, rewritten_like} =
             MostrCompat.handle_incoming(like, &{:fallback, &1})

    assert rewritten_like["object"] == object.data["id"]
  end

  test "rejects unknown Mostr events instead of restoring the AP bridge dependency" do
    unknown_id = String.duplicate("f", 64)
    mostr_url = "https://mostr.pub/objects/#{unknown_id}"

    params = %{
      "id" => mostr_url <> "#create",
      "type" => "Create",
      "object" => %{"id" => mostr_url, "type" => "Note"}
    }

    assert {:reject, :native_nostr_required} =
             MostrCompat.handle_incoming(params, fn _params ->
               flunk("unknown Mostr events must not reach the ActivityPub fallback")
             end)
  end

  test "recognizes legacy actor references without matching unrelated hosts" do
    pubkey = String.duplicate("a", 64)

    assert MostrCompat.legacy_reference?("https://mostr.pub/users/#{pubkey}")
    assert MostrCompat.legacy_reference?("#{pubkey}@mostr.pub")
    refute MostrCompat.legacy_reference?("https://notmostr.example/users/#{pubkey}")
  end
end

# end of test/pleroma/nostr/mostr_compat_test.exs
