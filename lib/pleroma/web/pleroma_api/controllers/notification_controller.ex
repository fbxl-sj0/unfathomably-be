# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.NotificationController do
  use Pleroma.Web, :controller

  alias Pleroma.Notification

  plug(Pleroma.Web.ApiSpec.CastAndValidate)

  plug(
    Pleroma.Web.Plugs.OAuthScopesPlug,
    %{scopes: ["write:notifications"]} when action == :mark_as_read
  )

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.PleromaNotificationOperation

  def mark_as_read(%{assigns: %{user: user}} = conn, params) do
    params = request_params(conn, params)

    cond do
      notification_id = get_param(params, "id") ->
        with {:ok, _} <- Notification.read_one(user, notification_id) do
          json(conn, "ok")
        else
          {:error, message} ->
            conn
            |> put_status(:bad_request)
            |> json(%{"error" => message})
        end

      max_id = get_param(params, "max_id") ->
        with {:ok, _} <- Notification.set_read_up_to(user, max_id) do
          json(conn, "ok")
        else
          {:error, message} ->
            conn
            |> put_status(:bad_request)
            |> json(%{"error" => message})
        end

      true ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => "Notification id is required"})
    end
  end

  defp request_params(%{body_params: body_params}, params) do
    Map.merge(params || %{}, body_params || %{})
  end

  defp get_param(params, key), do: Map.get(params, key) || Map.get(params, String.to_atom(key))
end
