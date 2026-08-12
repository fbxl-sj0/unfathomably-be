# Unfathomably BE
# ----------------
#
# File: web/diaspora/receive_controller.ex
#
# Purpose:
#   Accept bounded signed diaspora* public federation deliveries.
#
# Responsibilities:
#   - extract the magic envelope from raw or form-encoded requests
#   - hand verification and relevance policy to the bridge
#   - return protocol-appropriate success or rejection responses
#
# This file intentionally does NOT parse entities or accept unsigned XML.

defmodule Pleroma.Web.Diaspora.ReceiveController do
  use Pleroma.Web, :controller

  alias Pleroma.Diaspora.Bridge
  alias Pleroma.Diaspora.Protocol
  alias Pleroma.User

  def public(conn, params), do: receive_envelope(conn, params)

  def private(conn, %{"guid" => guid} = params) do
    with %User{local: true} = recipient <- User.get_by_id(guid),
         true <- Pleroma.Diaspora.guid(recipient) == guid,
         {:ok, envelope} <- Protocol.decrypt_private_payload(params, recipient),
         :ok <- Bridge.receive_private(envelope, recipient) do
      send_resp(conn, 202, "Accepted")
    else
      {:error, :not_relevant} -> send_resp(conn, 202, "Ignored")
      _ -> send_resp(conn, 400, "Invalid encrypted diaspora* envelope")
    end
  end

  defp receive_envelope(conn, params) do
    {envelope, conn} = envelope_and_conn(conn, params)

    case Bridge.receive_public(envelope) do
      :ok -> send_resp(conn, 202, "Accepted")
      {:error, :not_relevant} -> send_resp(conn, 202, "Ignored")
      _ -> send_resp(conn, 400, "Invalid diaspora* envelope")
    end
  end

  defp envelope_and_conn(conn, %{"xml" => envelope}) when is_binary(envelope),
    do: {envelope, conn}

  defp envelope_and_conn(conn, %{"magic_envelope" => envelope}) when is_binary(envelope),
    do: {envelope, conn}

  defp envelope_and_conn(conn, %{"_json" => envelope}) when is_binary(envelope),
    do: {envelope, conn}

  defp envelope_and_conn(conn, _params) do
    case Plug.Conn.read_body(conn, length: 2_097_152) do
      {:ok, body, conn} -> {body, conn}
      {:more, _body, conn} -> {nil, conn}
      {:error, _reason} -> {nil, conn}
    end
  end
end

# end of web/diaspora/receive_controller.ex
