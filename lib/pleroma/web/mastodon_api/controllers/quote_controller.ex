# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.QuoteController do
  use Pleroma.Web, :controller

  alias Pleroma.Activity
  alias Pleroma.QuoteAuthorization
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["write:statuses"]})

  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  def approve(%{assigns: %{user: user}} = conn, params) do
    with %Activity{} = activity <- activity(params),
         {:ok, activity} <- QuoteAuthorization.approve(activity, user) do
      conn
      |> put_view(Pleroma.Web.MastodonAPI.StatusView)
      |> render("show.json", activity: activity, for: user)
    else
      _ -> {:error, :not_found}
    end
  end

  def reject(%{assigns: %{user: user}} = conn, params) do
    with %Activity{} = activity <- activity(params),
         {:ok, activity} <- QuoteAuthorization.reject(activity, user) do
      conn
      |> put_view(Pleroma.Web.MastodonAPI.StatusView)
      |> render("show.json", activity: activity, for: user)
    else
      _ -> {:error, :not_found}
    end
  end

  defp activity(%{id: id}), do: Activity.get_by_id_with_object(id)
  defp activity(%{"id" => id}), do: Activity.get_by_id_with_object(id)
  defp activity(_), do: nil
end

# end of quote_controller.ex
