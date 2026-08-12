# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.AcceptedAnswerController do
  use Pleroma.Web, :controller

  alias Pleroma.Activity
  alias Pleroma.Web.ActivityPub.AcceptedAnswerPublisher
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["write:statuses"]})

  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  def accept(%{assigns: %{user: user}} = conn, params), do: set(conn, params, user, true)
  def unaccept(%{assigns: %{user: user}} = conn, params), do: set(conn, params, user, false)

  defp set(conn, params, user, selected) do
    with %Activity{} = activity <- activity(params),
         true <- Visibility.visible_for_user?(activity, user),
         {:ok, activity} <- AcceptedAnswerPublisher.set(user, activity, selected) do
      conn
      |> put_view(Pleroma.Web.MastodonAPI.StatusView)
      |> render("show.json", activity: activity, for: user)
    else
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, :not_authorized} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp activity(%{id: id}), do: Activity.get_by_id_with_object(id)
  defp activity(%{"id" => id}), do: Activity.get_by_id_with_object(id)
  defp activity(_params), do: nil
end

# end of accepted_answer_controller.ex
