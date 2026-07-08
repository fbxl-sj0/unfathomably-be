# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedSourceTimelineController do
  use Pleroma.Web, :controller

  import Ecto.Query, only: [where: 3]

  alias Pleroma.Activity
  alias Pleroma.Pagination
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ControllerHelper
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.StatusView
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["read:statuses"], fallback: :proceed_unauthenticated})

  defp add_link_headers(conn, entries), do: ControllerHelper.add_link_headers(conn, entries)

  @doc "GET /api/v1/timelines/sources"
  def index(%{assigns: %{user: %User{} = user}} = conn, params) do
    activity_params =
      params
      |> pagination_params()
      |> maybe_put_source_roots_only()
      |> Map.put(:type, ["Create", "Announce"])
      |> Map.put(:blocking_user, user)
      |> Map.put(:muting_user, user)
      |> Map.put(:reply_filtering_user, user)
      |> Map.put(:announce_filtering_user, user)

    source_ap_ids = FederatedTarget.followed_source_ap_ids(user)

    activities =
      []
      |> ActivityPub.fetch_activities_query(activity_params)
      |> where([activity], activity.actor in ^source_ap_ids)
      |> Pagination.fetch_paginated(activity_params)
      |> unique_source_activities()

    conn
    |> put_view(StatusView)
    |> add_link_headers(activities)
    |> render("index.json",
      activities: activities,
      for: user,
      as: :activity,
      with_muted: Map.get(activity_params, :with_muted, false)
    )
  end

  def index(conn, _params), do: render_error(conn, :unauthorized, "authorization required")

  defp pagination_params(params) do
    [:limit, :max_id, :min_id, :since_id, :only_media, :with_muted, :with_replies]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(params, to_string(key)) do
        nil -> acc
        value -> Map.put(acc, key, normalize_pagination_param(key, value))
      end
    end)
  end

  defp normalize_pagination_param(key, value)
       when key in [:only_media, :with_muted] do
    truthy_param?(value)
  end

  defp normalize_pagination_param(_key, value), do: value

  defp truthy_param?(value), do: value in [true, "true", "1", 1]

  defp maybe_put_source_roots_only(%{with_replies: with_replies} = params)
       when with_replies in [true, "true", "1", 1] do
    Map.delete(params, :with_replies)
  end

  defp maybe_put_source_roots_only(params) do
    params
    |> Map.delete(:with_replies)
    |> Map.put(:discussion_roots_only, true)
  end

  defp unique_source_activities(activities) when is_list(activities) do
    Enum.uniq_by(activities, &source_activity_object_id/1)
  end

  defp unique_source_activities(activities), do: activities

  defp source_activity_object_id(%Activity{object: %{data: %{"id" => id}}}) when is_binary(id),
    do: id

  defp source_activity_object_id(%Activity{data: %{"object" => id}}) when is_binary(id), do: id
  defp source_activity_object_id(%Activity{id: id}), do: id
  defp source_activity_object_id(activity), do: activity
end
