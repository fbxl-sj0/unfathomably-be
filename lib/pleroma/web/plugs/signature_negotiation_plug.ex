# Unfathomably BE
# ----------------
#
# File: signature_negotiation_plug.ex
#
# Purpose:
#   Advertise RFC 9421 request requirements to ActivityPub inbox senders.
#
# Responsibilities:
#   - add Accept-Signature to responses for legacy or unsigned POST requests
#   - run before authentication so rejected requests can discover the format
#
# This file intentionally does not authenticate, parse, or sign requests.

defmodule Pleroma.Web.Plugs.SignatureNegotiationPlug do
  @moduledoc false

  alias Pleroma.HTTP.MessageSignatures
  alias Pleroma.HTTP.SignatureNegotiation
  alias Plug.Conn

  def init(options), do: options

  def call(%Conn{method: "POST"} = conn, _options) do
    if MessageSignatures.present?(conn) do
      conn
    else
      Conn.register_before_send(conn, fn response ->
        Conn.put_resp_header(
          response,
          "accept-signature",
          SignatureNegotiation.accept_signature_value()
        )
      end)
    end
  end

  def call(conn, _options), do: conn
end

# end of signature_negotiation_plug.ex
