# Unfathomably BE
# ----------------
#
# File: signature_negotiation_test.exs
#
# Purpose:
#   Cover bounded RFC 9421 peer preference negotiation.
#
# This file intentionally does not perform HTTP requests or signature checks.

defmodule Pleroma.HTTP.SignatureNegotiationTest do
  use ExUnit.Case, async: false

  alias Pleroma.HTTP.SignatureNegotiation

  setup do
    Cachex.clear(:http_signature_format_cache)
    :ok
  end

  test "remembers a compatible successful response by authority" do
    response = %{
      status: 202,
      headers: [{"Accept-Signature", SignatureNegotiation.accept_signature_value()}]
    }

    refute SignatureNegotiation.prefers_rfc9421?("https://peer.example/inbox")
    assert :ok = SignatureNegotiation.observe_response("https://peer.example/inbox", response)
    assert SignatureNegotiation.prefers_rfc9421?("https://peer.example/users/alice/inbox")
  end

  test "ignores unsupported component requests and unsuccessful responses" do
    unsupported = %{status: 202, headers: [{"accept-signature", "sig1=(\"@method\")"}]}

    failed = %{
      status: 503,
      headers: [{"accept-signature", SignatureNegotiation.accept_signature_value()}]
    }

    assert :ok =
             SignatureNegotiation.observe_response(
               "https://unsupported.example/inbox",
               unsupported
             )

    assert :ok = SignatureNegotiation.observe_response("https://failed.example/inbox", failed)
    refute SignatureNegotiation.prefers_rfc9421?("https://unsupported.example/inbox")
    refute SignatureNegotiation.prefers_rfc9421?("https://failed.example/inbox")
  end
end

# end of signature_negotiation_test.exs
