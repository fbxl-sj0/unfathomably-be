# Unfathomably BE
# ----------------
#
# File: mastodon_api/controllers/atproto_controller.ex
#
# Purpose:
#   Manage the current user's optional Bluesky account link.
#
# Responsibilities:
#   - publish AT Protocol OAuth client metadata
#   - start and complete PAR/PKCE/DPoP OAuth authorization
#   - exchange a one-time app password for encrypted PDS session credentials
#   - create a managed identity on the configured local PDS
#   - report public link state without returning tokens
#   - remove stored authorization on request
#
# This file intentionally does NOT retain passwords, expose PDS tokens, process
# a firehose, or host AT Protocol repositories itself.

defmodule Pleroma.Web.MastodonAPI.ATProtoController do
  use Pleroma.Web, :controller

  alias Pleroma.ATProto.Links
  alias Pleroma.ATProto.OAuth
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["read:accounts"]} when action == :show)

  plug(
    OAuthScopesPlug,
    %{scopes: ["write:accounts"]}
    when action in [:create, :oauth_start, :provision, :delete]
  )

  def show(%{assigns: %{user: user}} = conn, _params), do: json(conn, Links.state(user))

  def oauth_metadata(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(OAuth.client_metadata())
  end

  def oauth_start(%{assigns: %{user: user}} = conn, params) do
    case Links.start_oauth(user, params["identifier"]) do
      {:ok, response} ->
        json(conn, response)

      {:error, :identity_not_found} ->
        error(conn, :not_found, "The AT Protocol identity could not be verified")

      {:error, :managed_identity} ->
        error(conn, :conflict, "A locally managed AT Protocol identity is already connected")

      {:error, _reason} ->
        error(conn, :unprocessable_entity, "OAuth authorization could not be started safely")
    end
  end

  def oauth_callback(conn, params) do
    case Links.finish_oauth(params) do
      {:ok, _state} ->
        redirect(conn, to: "/settings/atproto?oauth=connected")

      {:error, _reason} ->
        redirect(conn, to: "/settings/atproto?oauth=failed")
    end
  end

  def create(%{assigns: %{user: user}} = conn, params) do
    case Links.connect(user, params["identifier"], params["app_password"]) do
      {:ok, state} ->
        json(conn, state)

      {:error, :invalid_credentials} ->
        error(conn, :unauthorized, "AT Protocol credentials were rejected")

      {:error, _reason} ->
        error(conn, :unprocessable_entity, "The AT Protocol account could not be linked safely")
    end
  end

  def provision(%{assigns: %{user: user}} = conn, _params) do
    case Links.provision_local(user) do
      {:ok, state} ->
        json(conn, state)

      {:error, :provisioning_unavailable} ->
        error(conn, :service_unavailable, "Local AT Protocol provisioning is not ready")

      {:error, :email_required} ->
        error(conn, :unprocessable_entity, "A confirmed local email address is required")

      {:error, :invalid_local_nickname} ->
        error(conn, :unprocessable_entity, "The local username cannot form a valid handle")

      {:error, {:http, 400, response}} ->
        error(conn, :conflict, account_creation_error(response))

      {:error, _reason} ->
        error(conn, :unprocessable_entity, "The AT Protocol account could not be created safely")
    end
  end

  def delete(%{assigns: %{user: user}} = conn, _params) do
    case Links.disconnect(user) do
      :ok ->
        json(conn, %{connected: false})

      {:error, :managed_identity} ->
        error(conn, :conflict, "A locally managed AT Protocol identity cannot be disconnected")
    end
  end

  defp account_creation_error(%{"message" => message}) when is_binary(message), do: message
  defp account_creation_error(_response), do: "The requested AT Protocol handle is unavailable"

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end

# end of mastodon_api/controllers/atproto_controller.ex
