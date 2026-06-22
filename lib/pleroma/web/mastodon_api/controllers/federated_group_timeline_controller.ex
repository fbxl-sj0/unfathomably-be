# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedGroupTimelineController do
  use Pleroma.Web, :controller

  import Pleroma.Web.ControllerHelper, only: [add_link_headers: 2]

  alias Pleroma.Pagination
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.StatusView
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["read:statuses"], fallback: :proceed_unauthenticated})

  @doc "GET /api/v1/timelines/group/:id"
  def show(conn, %{"id" => id} = params) do
    user = conn.assigns[:user]

    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id) do
      activity_params =
        params
        |> pagination_params()
        |> Map.put(:type, ["Create", "Announce"])
        |> Map.put(:blocking_user, user)
        |> Map.put(:muting_user, user)
        |> Map.put(:reply_filtering_user, user)
        |> Map.put(:announce_filtering_user, user)

      activities =
        [group.ap_id]
        |> ActivityPub.fetch_activities_query(activity_params)
        |> Pagination.fetch_paginated(activity_params)

      conn
      |> put_view(StatusView)
      |> add_link_headers(activities)
      |> render("index.json",
        activities: activities,
        for: user,
        as: :activity,
        with_muted: Map.get(activity_params, :with_muted, false)
      )
    else
      _ -> render_error(conn, :not_found, "Record not found")
    end
  end

  defp pagination_params(params) do
    [:limit, :max_id, :min_id, :since_id, :only_media, :pinned, :with_muted]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(params, to_string(key)) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end
end
