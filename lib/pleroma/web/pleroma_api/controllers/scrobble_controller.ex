# Pleroma: A lightweight social networking server
# Copyright Ã‚Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.ScrobbleController do
  use Pleroma.Web, :controller

  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.ControllerHelper
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(Pleroma.Web.ApiSpec.CastAndValidate)

  plug(
    OAuthScopesPlug,
    %{scopes: ["read", "read:scrobbles"], fallback: :proceed_unauthenticated}
    when action == :index
  )

  plug(OAuthScopesPlug, %{scopes: ["write", "write:scrobbles"]} when action == :create)

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.PleromaScrobbleOperation
  defp add_link_headers(conn, entries), do: ControllerHelper.add_link_headers(conn, entries)

  def create(%{assigns: %{user: user}, body_params: params} = conn, _) do
    with {:ok, activity} <- CommonAPI.listen(user, params) do
      render(conn, "show.json", activity: activity, for: user)
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => message})
    end
  end

  def index(%{assigns: %{user: reading_user}} = conn, %{id: id} = params) do
    with %User{} = user <- User.get_cached_by_nickname_or_id(id, for: reading_user) do
      params = Map.put(params, :type, ["Listen"])

      activities = ActivityPub.fetch_user_abstract_activities(user, reading_user, params)

      conn
      |> add_link_headers(activities)
      |> render("index.json", %{
        activities: activities,
        for: reading_user,
        as: :activity
      })
    end
  end
end
