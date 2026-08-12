# Unfathomably BE
# ----------------
#
# File: federation_connector_controller.ex
#
# Purpose:
#   Provide administrator-only configuration for explicit federation peers.
#
# Responsibilities:
#   - list marketplace connector peers
#   - verify and connect a remote marketplace instance actor
#   - remove a connector without altering ordinary account follows
#
# This file intentionally does not expose connector controls to ordinary users.

defmodule Pleroma.Web.AdminAPI.FederationConnectorController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["admin:read"]} when action in [:index])
  plug(OAuthScopesPlug, %{scopes: ["admin:write"]} when action in [:connect, :delete])

  def index(conn, _params) do
    json(conn, %{
      service_actor: Marketplace.service_actor_ap_id(),
      peers: Enum.map(Marketplace.peers(), &Marketplace.peer_json/1)
    })
  end

  def connect(conn, %{"actor" => actor_ap_id}) do
    case Marketplace.connect(actor_ap_id) do
      {:ok, peer} -> conn |> put_status(:created) |> json(Marketplace.peer_json(peer))
      {:error, reason} -> connector_error(conn, reason)
    end
  end

  def connect(conn, _params), do: connector_error(conn, :invalid_actor_url)

  def delete(conn, %{"id" => id}) do
    case Marketplace.disconnect(id) do
      {:ok, _peer} -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> connector_error(conn, :not_found)
    end
  end

  defp connector_error(conn, :not_found) do
    conn |> put_status(:not_found) |> json(%{error: "Marketplace connector peer was not found"})
  end

  defp connector_error(conn, reason) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: connector_error_message(reason)})
  end

  defp connector_error_message(:invalid_actor_url),
    do: "Use an HTTPS Flohmarkt instance URL or its /users/instance actor URL"

  defp connector_error_message(:not_instance_actor),
    do: "The remote actor is not a Flohmarkt-compatible instance actor"

  defp connector_error_message(:local_actor),
    do: "A marketplace connector cannot target this instance"

  defp connector_error_message(_reason), do: "The marketplace connector could not be established"
end

# end of lib/pleroma/web/admin_api/controllers/federation_connector_controller.ex
