# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/bridgy_compat_test.exs
#
# Purpose:
#   Verify that Bluesky ActivityPub proxies reconcile to native AT records.
#
# Responsibilities:
#   - recognize configured bridge actors without matching unrelated hosts
#   - extract stable DIDs and native handles from actor identifiers
#   - parse Bridgy and FEP-fffd canonical at:// post references
#   - reuse mapped native activities and retarget interactions to native objects
#
# This file intentionally does NOT contact Bridgy Fed or a public AppView.

defmodule Pleroma.ATProto.BridgyCompatTest do
  use Pleroma.DataCase, async: false

  import Pleroma.Factory

  alias Pleroma.ATProto.BridgyCompat
  alias Pleroma.ATProto.Store
  alias Pleroma.Object
  alias Pleroma.User

  @did "did:plc:s6j27rxb3ic2rxw73ixgqv2p"
  @rkey "3lexample"
  @uri "at://#{@did}/app.bsky.feed.post/#{@rkey}"
  @proxy "https://bsky.brid.gy/convert/ap/#{@uri}"

  setup do
    clear_config([Pleroma.ATProto, :bridge_hosts], ["bsky.brid.gy"])
    :ok
  end

  test "recognizes bridge actors and extracts their native identifiers" do
    actor = %User{
      ap_id: "https://bsky.brid.gy/ap/#{@did}",
      nickname: "kenwhite.bsky.social@bsky.brid.gy",
      also_known_as: [@did]
    }

    assert BridgyCompat.legacy_actor?(actor)
    assert BridgyCompat.native_identifier(actor) == @did

    assert BridgyCompat.native_identifier("kenwhite.bsky.social@bsky.brid.gy") ==
             "kenwhite.bsky.social"

    refute BridgyCompat.legacy_actor?("kenwhite.bsky.social@not-bridgy.example")
    refute BridgyCompat.legacy_reference?("https://not-bsky.brid.gy/ap/#{@did}")
  end

  test "extracts canonical post URIs from Bridgy and FEP-fffd references" do
    assert BridgyCompat.canonical_uri(@proxy) == @uri

    reference = %{
      "id" => @proxy,
      "url" => [
        "https://bsky.app/profile/kenwhite.bsky.social/post/#{@rkey}",
        %{"type" => "Link", "rel" => "canonical", "href" => @uri}
      ]
    }

    assert BridgyCompat.canonical_uri(reference) == @uri
  end

  test "reuses native activities and retargets interactions", %{test: test_name} do
    activity = insert(:note_activity)
    object = Object.normalize(activity, fetch: false)

    {:ok, stored} =
      Store.put(
        %{
          "uri" => @uri,
          "cid" => "bafyreitest#{test_name}",
          "indexedAt" => "2026-08-07T12:00:00Z"
        },
        "explicit"
      )

    assert {:ok, :claimed} = Store.claim_activity(stored.uri, activity.id, object.data["id"])

    create = %{
      "id" => @proxy <> "#create",
      "type" => "Create",
      "actor" => "https://bsky.brid.gy/ap/#{@did}",
      "object" => %{"id" => @proxy, "url" => [%{"rel" => "canonical", "href" => @uri}]}
    }

    assert {:ok, ^activity} =
             BridgyCompat.handle_incoming(create, fn _data ->
               flunk("mapped Bridgy creates must not reach ActivityPub ingestion")
             end)

    like = %{
      "id" => "https://remote.example/activities/like",
      "type" => "Like",
      "actor" => "https://remote.example/users/alice",
      "object" => @proxy
    }

    assert {:fallback, rewritten} =
             BridgyCompat.handle_incoming(like, &{:fallback, &1})

    assert rewritten["object"] == object.data["id"]
  end

  test "rejects bridge envelopes without native record evidence" do
    params = %{
      "id" => "https://bsky.brid.gy/activities/unknown",
      "type" => "Create",
      "actor" => "https://bsky.brid.gy/ap/#{@did}",
      "object" => %{"id" => "https://bsky.brid.gy/objects/unknown", "type" => "Note"}
    }

    assert {:reject, :native_atproto_required} =
             BridgyCompat.handle_incoming(params, fn _data ->
               flunk("unproven bridge objects must not reach ActivityPub ingestion")
             end)
  end
end

# end of test/pleroma/atproto/bridgy_compat_test.exs
