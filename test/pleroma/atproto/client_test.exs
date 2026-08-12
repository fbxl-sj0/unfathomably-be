# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/client_test.exs
#
# Purpose:
#   Verify DID-document and PDS trust checks used by AT Protocol sessions.
#
# Responsibilities:
#   - bind a resolved document to the requested DID
#   - require the standard PDS service type and an origin-only HTTPS endpoint
#   - reject path-based did:web identifiers before any request is attempted
#
# This file intentionally does NOT contact a public PLC directory or PDS.

defmodule Pleroma.ATProto.ClientTest do
  use Pleroma.DataCase, async: false

  import Tesla.Mock

  alias Pleroma.ATProto.Client

  @did "did:plc:alice"

  setup do
    mock(fn env ->
      cond do
        String.starts_with?(env.url, "https://plc.directory/") ->
          json(%{
            "id" => @did,
            "alsoKnownAs" => ["at://alice.example.com"],
            "service" => [
              %{
                "id" => "#{@did}#atproto_pds",
                "type" => "AtprotoPersonalDataServer",
                "serviceEndpoint" => "https://pds.example.com"
              }
            ]
          })

        env.url == "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle" ->
          json(%{"did" => @did})

        true ->
          %Tesla.Env{status: 404, body: Jason.encode!(%{"error" => "NotFound"})}
      end
    end)

    :ok
  end

  test "verifies the DID document, handle backlink, and typed PDS service" do
    assert {:ok, "alice.example.com"} = Client.verified_handle(@did, "alice.example.com")
    assert {:ok, "https://pds.example.com"} = Client.pds_url(@did)
  end

  test "rejects path-based did:web identifiers" do
    assert {:error, :invalid_did_web} =
             Client.did_document("did:web:pds.example.com:user")
  end
end

# end of test/pleroma/atproto/client_test.exs
