# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedGroupTimelineController do
  use Pleroma.Web, :controller

  import Pleroma.Web.ControllerHelper, only: [add_link_headers: 2]

  alias Pleroma.Activity
  alias Pleroma.Object.Fetcher
  alias Pleroma.Pagination
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.StatusView
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  require Logger

  @default_remote_group_backfill_limit 20
  @remote_group_backfill_limit 40

  plug(OAuthScopesPlug, %{scopes: ["read:statuses"], fallback: :proceed_unauthenticated})

  @doc "GET /api/v1/timelines/groups"
  def index(%{assigns: %{user: %User{} = user}} = conn, params) do
    activity_params =
      params
      |> pagination_params()
      |> maybe_put_discussion_roots_only()
      |> Map.put(:type, ["Create", "Announce"])
      |> Map.put(:blocking_user, user)
      |> Map.put(:muting_user, user)
      |> Map.put(:reply_filtering_user, user)
      |> Map.put(:announce_filtering_user, user)

    activities =
      user
      |> FederatedTarget.followed_group_ap_ids()
      |> ActivityPub.fetch_activities_query(activity_params)
      |> Pagination.fetch_paginated(activity_params)
      |> unique_group_activities()

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

  @doc "GET /api/v1/timelines/group/:id"
  def show(conn, %{"id" => id} = params) do
    user = conn.assigns[:user]

    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id) do
      activity_params =
        params
        |> pagination_params()
        |> maybe_put_discussion_roots_only()
        |> Map.put(:type, ["Create", "Announce"])
        |> group_activity_params(group)
        |> Map.put(:blocking_user, user)
        |> Map.put(:muting_user, user)
        |> Map.put(:reply_filtering_user, user)
        |> Map.put(:announce_filtering_user, user)

      activities =
        case remote_group_first_page_activities(group, activity_params) do
          [_ | _] = activities ->
            activities

          _ ->
            group
            |> fetch_group_activities(activity_params)
            |> maybe_backfill_remote_group(group, activity_params)
        end
        |> unique_group_activities()

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
    [:limit, :max_id, :min_id, :since_id, :only_media, :pinned, :with_muted, :with_replies]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(params, to_string(key)) do
        nil -> acc
        value -> Map.put(acc, key, normalize_pagination_param(key, value))
      end
    end)
  end

  defp normalize_pagination_param(key, value)
       when key in [:only_media, :pinned, :with_muted] do
    truthy_param?(value)
  end

  defp normalize_pagination_param(_key, value), do: value

  defp truthy_param?(value), do: value in [true, "true", "1", 1]

  defp maybe_put_discussion_roots_only(%{with_replies: with_replies} = params)
       when with_replies in [true, "true", "1", 1] do
    Map.delete(params, :with_replies)
  end

  defp maybe_put_discussion_roots_only(params) do
    params
    |> Map.delete(:with_replies)
    |> Map.put(:discussion_roots_only, true)
  end

  defp group_activity_params(params, %User{local: false} = group) do
    Map.put(params, :pinned_object_ids, pinned_object_ids(params, group))
  end

  defp group_activity_params(params, %User{ap_id: ap_id} = group) when is_binary(ap_id) do
    Map.put(params, :pinned_object_ids, pinned_object_ids(params, group))
  end

  defp group_activity_params(params, _group), do: params

  defp pinned_object_ids(%{pinned: true}, %User{pinned_objects: pinned_objects})
       when is_map(pinned_objects) do
    Map.keys(pinned_objects)
  end

  defp pinned_object_ids(_params, _group), do: []

  defp group_activity_recipients(%User{ap_id: ap_id}) when is_binary(ap_id), do: [ap_id]
  defp group_activity_recipients(_group), do: []

  defp fetch_group_activities(%User{} = group, activity_params) do
    group
    |> group_activity_recipients()
    |> ActivityPub.fetch_activities_query(activity_params)
    |> Pagination.fetch_paginated(activity_params)
  end

  defp unique_group_activities(activities) when is_list(activities) do
    Enum.uniq_by(activities, &group_activity_object_id/1)
  end

  defp unique_group_activities(activities), do: activities

  defp group_activity_object_id(%Activity{object: %{data: %{"id" => id}}}) when is_binary(id),
    do: id

  defp group_activity_object_id(%Activity{data: %{"object" => id}}) when is_binary(id), do: id
  defp group_activity_object_id(%Activity{id: id}), do: id
  defp group_activity_object_id(activity), do: activity

  defp maybe_backfill_remote_group([], %User{local: false} = group, activity_params) do
    if pinned_timeline?(activity_params) do
      []
    else
      maybe_backfill_first_remote_group_page(group, activity_params)
    end
  end

  defp maybe_backfill_remote_group(activities, _group, _activity_params), do: activities

  defp remote_group_first_page_activities(%User{local: false} = group, activity_params) do
    if refreshable_remote_group_first_page?(activity_params) do
      group
      |> backfill_remote_group(activity_params)
      |> fallback_group_activities(activity_params)
    else
      []
    end
  end

  defp remote_group_first_page_activities(_group, _activity_params), do: []

  defp refreshable_remote_group_first_page?(activity_params) do
    first_timeline_page?(activity_params) and
      not pinned_timeline?(activity_params) and
      Map.get(activity_params, :discussion_roots_only) == true
  end

  defp maybe_backfill_first_remote_group_page(%User{} = group, activity_params) do
    if first_timeline_page?(activity_params) do
      item_ids = backfill_remote_group(group, activity_params)

      case fetch_group_activities(group, activity_params) do
        [] -> fallback_group_activities(item_ids, activity_params)
        activities -> activities
      end
    else
      []
    end
  end

  defp pinned_timeline?(%{pinned: true}), do: true
  defp pinned_timeline?(_params), do: false

  defp first_timeline_page?(params) do
    not Enum.any?([:max_id, :min_id, :since_id], &Map.has_key?(params, &1))
  end

  defp backfill_remote_group(%User{} = group, activity_params) do
    limit = remote_group_backfill_limit(activity_params)

    case FederatedTarget.group_items_result(group, %{"limit" => limit}) do
      {:ok, %{items: items}} when is_list(items) ->
        item_ids =
          items
          |> Enum.map(&Map.get(&1, :id))
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        Enum.each(item_ids, &fetch_remote_group_item/1)
        item_ids

      _ ->
        []
    end
  end

  defp fallback_group_activities([], _activity_params), do: []

  defp fallback_group_activities(item_ids, activity_params) do
    item_ids
    |> Activity.create_by_object_ap_id_with_object()
    |> Repo.all()
    |> Enum.sort_by(&preview_item_index(&1, item_ids))
    |> Enum.take(remote_group_backfill_limit(activity_params))
  end

  defp preview_item_index(%Activity{object: %{data: %{"id" => id}}}, item_ids) do
    Enum.find_index(item_ids, &(&1 == id)) || length(item_ids)
  end

  defp preview_item_index(_activity, item_ids), do: length(item_ids)

  defp remote_group_backfill_limit(%{limit: limit}) when is_integer(limit),
    do: max(1, min(limit, @remote_group_backfill_limit))

  defp remote_group_backfill_limit(%{limit: limit}) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, _} -> remote_group_backfill_limit(%{limit: limit})
      _ -> @remote_group_backfill_limit
    end
  end

  defp remote_group_backfill_limit(_activity_params), do: @default_remote_group_backfill_limit

  defp fetch_remote_group_item(id) do
    match?({:ok, _object}, Fetcher.fetch_object_from_id(id, depth: 0))
  rescue
    error ->
      Logger.debug("Could not backfill remote group item #{id}: #{inspect(error)}")
      false
  catch
    _kind, error ->
      Logger.debug("Could not backfill remote group item #{id}: #{inspect(error)}")
      false
  end
end
