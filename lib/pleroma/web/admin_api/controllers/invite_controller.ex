# Pleroma: A lightweight social networking server
# Copyright Ã‚Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.AdminAPI.InviteController do
  use Pleroma.Web, :controller

  alias Pleroma.Config
  alias Pleroma.UserInviteToken
  alias Pleroma.Web.ControllerHelper
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  require Logger

  plug(Pleroma.Web.ApiSpec.CastAndValidate)
  plug(OAuthScopesPlug, %{scopes: ["admin:read:invites"]} when action == :index)

  plug(
    OAuthScopesPlug,
    %{scopes: ["admin:write:invites"]} when action in [:create, :revoke, :email]
  )

  action_fallback(Pleroma.Web.AdminAPI.FallbackController)

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.Admin.InviteOperation
  defp json_response(conn, status, json), do: ControllerHelper.json_response(conn, status, json)

  @doc "Get list of created invites"
  def index(conn, _params) do
    invites = UserInviteToken.list_invites()

    render(conn, "index.json", invites: invites)
  end

  @doc "Create an account registration invite token"
  def create(%{body_params: params} = conn, _) do
    {:ok, invite} = UserInviteToken.create_invite(params)

    render(conn, "show.json", invite: invite)
  end

  @doc "Revokes invite by token"
  def revoke(%{body_params: body_params} = conn, params) do
    token = get_param(Map.merge(params || %{}, body_params || %{}), "token")

    with {:ok, invite} <- UserInviteToken.find_by_token(token),
         {:ok, updated_invite} = UserInviteToken.update_invite(invite, %{used: true}) do
      render(conn, "show.json", invite: updated_invite)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Sends registration invite via email"
  def email(%{assigns: %{user: user}, body_params: body_params} = conn, params) do
    params = Map.merge(params || %{}, body_params || %{})
    email = get_param(params, "email")
    name = get_param(params, "name")

    with {_, false} <- {:registrations_open, Config.get([:instance, :registrations_open])},
         {_, true} <- {:invites_enabled, Config.get([:instance, :invites_enabled])},
         true <- is_binary(email) and email != "",
         {:ok, invite_token} <- UserInviteToken.create_invite(),
         {:ok, _} <-
           user
           |> Pleroma.Emails.UserEmail.user_invitation_email(
             invite_token,
             email,
             name
           )
           |> Pleroma.Emails.Mailer.deliver() do
      json_response(conn, :no_content, "")
    else
      {:registrations_open, _} ->
        {:error, "To send invites you need to set the `registrations_open` option to false."}

      {:invites_enabled, _} ->
        {:error, "To send invites you need to set the `invites_enabled` option to true."}

      false ->
        {:error, "Email is required."}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_param(params, key), do: Map.get(params, key) || Map.get(params, String.to_atom(key))
end
