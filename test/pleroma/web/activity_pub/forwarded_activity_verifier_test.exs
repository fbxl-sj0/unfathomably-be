# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ForwardedActivityVerifierTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.ActivityPub.ForwardedActivityVerifier

  @actor "https://origin.example/users/alice"
  @activity_id "https://origin.example/users/alice/statuses/1/activity"
  @object_id "https://origin.example/users/alice/statuses/1"
  @forwarder "https://forwarder.example/users/bob"
  @public "https://www.w3.org/ns/activitystreams#Public"

  test "returns the canonical origin document for a public forwarded Create" do
    forwarded = forwarded_activity()
    canonical = canonical_activity()
    fetcher = fn @activity_id -> {:ok, canonical} end

    assert {:ok, ^canonical} =
             ForwardedActivityVerifier.verify_and_fetch(forwarded, @forwarder, fetcher)
  end

  test "does not authorize a private activity" do
    canonical =
      canonical_activity()
      |> put_in(["cc"], [@forwarder])
      |> put_in(["object", "cc"], [@forwarder])

    fetcher = fn @activity_id -> {:ok, canonical} end

    assert {:error, :non_public_activity} =
             ForwardedActivityVerifier.verify_and_fetch(
               forwarded_activity(),
               @forwarder,
               fetcher
             )
  end

  test "accepts a canonical public activity when its forwarder is not explicitly addressed" do
    canonical =
      canonical_activity()
      |> put_in(["cc"], [@public])
      |> put_in(["object", "cc"], [@public])

    fetcher = fn @activity_id -> {:ok, canonical} end

    assert {:ok, ^canonical} =
             ForwardedActivityVerifier.verify_and_fetch(
               forwarded_activity(),
               @forwarder,
               fetcher
             )
  end

  test "returns a canonical public actor Update" do
    actor_update = %{
      "id" => @actor <> "#updates/1",
      "type" => "Update",
      "actor" => @actor,
      "to" => [@public],
      "object" => %{"id" => @actor, "type" => "Person", "name" => "Alice"}
    }

    forwarded = Map.put(actor_update, "signature", legacy_signature())
    fetcher = fn _activity_id -> {:ok, actor_update} end

    assert {:ok, ^actor_update} =
             ForwardedActivityVerifier.verify_and_fetch(forwarded, @forwarder, fetcher)
  end

  test "returns a canonical public Delete without trusting the embedded proof alone" do
    delete = %{
      "id" => @activity_id <> "#delete",
      "type" => "Delete",
      "actor" => @actor,
      "to" => [@public],
      "object" => %{"id" => @object_id, "type" => "Tombstone"}
    }

    forwarded = Map.put(delete, "signature", legacy_signature())
    fetcher = fn _activity_id -> {:ok, delete} end

    assert {:ok, ^delete} =
             ForwardedActivityVerifier.verify_and_fetch(forwarded, @forwarder, fetcher)
  end

  test "rejects a relay body that names a different canonical object" do
    forwarded = put_in(forwarded_activity()["object"]["id"], @object_id <> "-other")
    fetcher = fn @activity_id -> {:ok, canonical_activity()} end

    assert {:error, :origin_mismatch} =
             ForwardedActivityVerifier.verify_and_fetch(forwarded, @forwarder, fetcher)
  end

  test "rejects destructive activity types" do
    forwarded = Map.put(forwarded_activity(), "type", "Delete")

    assert {:error, :invalid_forwarded_activity} =
             ForwardedActivityVerifier.verify_and_fetch(forwarded, @forwarder, fn _ ->
               flunk("the origin must not be fetched for a rejected activity type")
             end)
  end

  test "rejects a legacy signature whose creator is not the payload actor" do
    forwarded =
      put_in(forwarded_activity()["signature"]["creator"], @forwarder <> "#main-key")

    assert {:error, :invalid_legacy_signature} =
             ForwardedActivityVerifier.verify_and_fetch(forwarded, @forwarder, fn _ ->
               flunk("the origin must not be fetched for an invalid signature envelope")
             end)
  end

  test "rejects a legacy signature with a conflicting verification method" do
    forwarded =
      put_in(
        forwarded_activity()["signature"]["verificationMethod"],
        @forwarder <> "#main-key"
      )

    assert {:error, :invalid_legacy_signature} =
             ForwardedActivityVerifier.verify_and_fetch(forwarded, @forwarder, fn _ ->
               flunk("the origin must not be fetched for an ambiguous signature envelope")
             end)
  end

  test "accepts a matching creator and verification method" do
    forwarded =
      put_in(
        forwarded_activity()["signature"]["verificationMethod"],
        @actor <> "#main-key"
      )

    canonical = canonical_activity()

    assert {:ok, ^canonical} =
             ForwardedActivityVerifier.verify_and_fetch(forwarded, @forwarder, fn @activity_id ->
               {:ok, canonical}
             end)
  end

  defp forwarded_activity do
    canonical_activity()
    |> Map.put("signature", legacy_signature())
  end

  defp legacy_signature do
    %{
      "type" => "RsaSignature2017",
      "creator" => @actor <> "#main-key",
      "created" => DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601(),
      "signatureValue" => Base.encode64(:crypto.strong_rand_bytes(256))
    }
  end

  defp canonical_activity do
    %{
      "id" => @activity_id,
      "type" => "Create",
      "actor" => @actor,
      "to" => [@actor <> "/followers"],
      "cc" => [@public, @forwarder],
      "object" => %{
        "id" => @object_id,
        "type" => "Note",
        "attributedTo" => @actor,
        "to" => [@actor <> "/followers"],
        "cc" => [@public, @forwarder],
        "content" => "Origin-authenticated content"
      }
    }
  end
end
