# Unfathomably BE
# ----------------
#
# File: signature_negotiation_plug_test.exs
#
# Purpose:
#   Cover RFC 9421 capability advertisement on inbox-style POST responses.
#
# This file intentionally does not authenticate or verify signatures.

defmodule Pleroma.Web.Plugs.SignatureNegotiationPlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Pleroma.HTTP.SignatureNegotiation
  alias Pleroma.Web.Plugs.SignatureNegotiationPlug

  test "advertises the supported request components to a legacy sender" do
    response =
      conn(:post, "/inbox")
      |> SignatureNegotiationPlug.call([])
      |> Plug.Conn.send_resp(401, "signature required")

    assert Plug.Conn.get_resp_header(response, "accept-signature") == [
             SignatureNegotiation.accept_signature_value()
           ]
  end

  test "does not renegotiate a request that already uses RFC 9421" do
    response =
      conn(:post, "/inbox")
      |> Plug.Conn.put_req_header(
        "signature-input",
        ~s|sig1=("@method" "@target-uri" "content-digest");created=1;keyid="key"|
      )
      |> SignatureNegotiationPlug.call([])
      |> Plug.Conn.send_resp(202, "accepted")

    assert Plug.Conn.get_resp_header(response, "accept-signature") == []
  end
end

# end of signature_negotiation_plug_test.exs
