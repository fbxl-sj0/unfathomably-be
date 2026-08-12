# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/dpop_test.exs
#
# Purpose:
#   Verify AT Protocol OAuth DPoP proof generation.
#
# Responsibilities:
#   - validate ES256 proof headers and request binding claims
#   - validate access-token hash binding for PDS resource requests
#   - prove generated compact JWT signatures against their public key
#
# This file intentionally does NOT contact an authorization server or persist
# private key material.

defmodule Pleroma.ATProto.DPoPTest do
  use ExUnit.Case, async: true

  alias Pleroma.ATProto.DPoP

  test "signs a unique resource proof bound to method, URL, nonce, and token" do
    {:ok, key_json} = DPoP.generate_key()

    {:ok, proof} =
      DPoP.proof(
        :post,
        "https://pds.example/xrpc/com.atproto.repo.putRecord?ignored=true",
        key_json,
        "server-nonce",
        "access-token"
      )

    [encoded_header, encoded_claims, _signature] = String.split(proof, ".")
    header = decode_segment(encoded_header)
    claims = decode_segment(encoded_claims)

    assert header["alg"] == "ES256"
    assert header["typ"] == "dpop+jwt"
    assert header["jwk"]["crv"] == "P-256"
    refute Map.has_key?(header["jwk"], "d")

    assert claims["htm"] == "POST"
    assert claims["htu"] == "https://pds.example/xrpc/com.atproto.repo.putRecord"
    assert claims["nonce"] == "server-nonce"

    assert claims["ath"] ==
             "access-token"
             |> then(&:crypto.hash(:sha256, &1))
             |> Base.url_encode64(padding: false)

    assert is_integer(claims["iat"])
    assert is_binary(claims["jti"])

    assert {true, _jwt, _jws} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_map(header["jwk"]), ["ES256"], proof)
  end

  defp decode_segment(segment) do
    {:ok, json} = Base.url_decode64(segment, padding: false)
    Jason.decode!(json)
  end
end

# end of test/pleroma/atproto/dpop_test.exs
