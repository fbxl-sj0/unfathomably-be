# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.NotificationController do
  use Pleroma.Web, :controller

  alias Pleroma.Notification
  alias Pleroma.User
  alias Pleroma.Web.ControllerHelper
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.Web.MastodonAPI.MastodonAPI
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  # Mastodon's docs currently list write:notifications for group accounts, but the endpoint is
  # read-only and Mastodon's implementation accepts read:notifications. Prefer least privilege.
  @oauth_read_actions [:show, :index, :grouped_index, :show_group, :group_accounts, :unread_count]

  plug(Pleroma.Web.ApiSpec.CastAndValidate)

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:notifications"]} when action in @oauth_read_actions
  )

  plug(OAuthScopesPlug, %{scopes: ["write:notifications"]} when action not in @oauth_read_actions)

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.NotificationOperation
  defp add_link_headers(conn, entries), do: ControllerHelper.add_link_headers(conn, entries)

  defp add_link_headers(conn, entries, extra_params),
    do: ControllerHelper.add_link_headers(conn, entries, extra_params)

  @default_notification_types ~w{
    mention
    follow
    follow_request
    reblog
    favourite
    move
    pleroma:emoji_reaction
    poll
    status
    update
    pleroma:participation_request
    pleroma:participation_accepted
    pleroma:event_reminder
    pleroma:event_update
  }

  # GET /api/v1/notifications
  def index(conn, %{account_id: account_id} = params) do
    case User.get_cached_by_id(account_id) do
      %{ap_id: account_ap_id} ->
        params =
          params
          |> Map.delete(:account_id)
          |> Map.put(:account_ap_id, account_ap_id)

        do_get_notifications(conn, params)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Account is not found"})
    end
  end

  def index(conn, %{"account_id" => account_id} = params) do
    case User.get_cached_by_id(account_id) do
      %{ap_id: account_ap_id} ->
        params =
          params
          |> Map.delete("account_id")
          |> Map.put(:account_ap_id, account_ap_id)

        do_get_notifications(conn, params)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Account is not found"})
    end
  end

  def index(%{assigns: %{user: _user}} = conn, params) do
    do_get_notifications(conn, params)
  end

  # GET /api/v2/notifications
  def grouped_index(conn, %{account_id: account_id} = params) do
    case User.get_cached_by_id(account_id) do
      %{ap_id: account_ap_id} ->
        params =
          params
          |> Map.delete(:account_id)
          |> Map.put(:account_ap_id, account_ap_id)

        do_get_grouped_notifications(conn, params)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Account is not found"})
    end
  end

  def grouped_index(conn, %{"account_id" => account_id} = params) do
    case User.get_cached_by_id(account_id) do
      %{ap_id: account_ap_id} ->
        params =
          params
          |> Map.delete("account_id")
          |> Map.put(:account_ap_id, account_ap_id)

        do_get_grouped_notifications(conn, params)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Account is not found"})
    end
  end

  def grouped_index(%{assigns: %{user: _user}} = conn, params) do
    do_get_grouped_notifications(conn, params)
  end

  # GET /api/v2/notifications/:group_key
  def show_group(%{assigns: %{user: user}} = conn, %{group_key: group_key}) do
    do_show_group(conn, user, group_key)
  end

  def show_group(%{assigns: %{user: user}} = conn, %{"group_key" => group_key}) do
    do_show_group(conn, user, group_key)
  end

  # GET /api/v2/notifications/:group_key/accounts
  def group_accounts(%{assigns: %{user: user}} = conn, %{group_key: group_key}) do
    do_group_accounts(conn, user, group_key)
  end

  def group_accounts(%{assigns: %{user: user}} = conn, %{"group_key" => group_key}) do
    do_group_accounts(conn, user, group_key)
  end

  # GET /api/v2/notifications/unread_count
  def unread_count(conn, %{account_id: account_id} = params) do
    case User.get_cached_by_id(account_id) do
      %{ap_id: account_ap_id} ->
        params =
          params
          |> Map.delete(:account_id)
          |> Map.put(:account_ap_id, account_ap_id)

        do_get_unread_group_count(conn, params)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Account is not found"})
    end
  end

  def unread_count(conn, %{"account_id" => account_id} = params) do
    case User.get_cached_by_id(account_id) do
      %{ap_id: account_ap_id} ->
        params =
          params
          |> Map.delete("account_id")
          |> Map.put(:account_ap_id, account_ap_id)

        do_get_unread_group_count(conn, params)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Account is not found"})
    end
  end

  def unread_count(%{assigns: %{user: _user}} = conn, params) do
    do_get_unread_group_count(conn, params)
  end

  # POST /api/v2/notifications/:group_key/dismiss
  def dismiss_group(%{assigns: %{user: user}} = conn, %{group_key: group_key}) do
    MastodonAPI.dismiss_notification_group(user, group_key)
    json(conn, %{})
  end

  def dismiss_group(%{assigns: %{user: user}} = conn, %{"group_key" => group_key}) do
    MastodonAPI.dismiss_notification_group(user, group_key)
    json(conn, %{})
  end

  # GET /api/v1/notifications/:id
  def show(%{assigns: %{user: user}} = conn, %{id: id}) do
    with {:ok, notification} <- Notification.get(user, id) do
      render(conn, "show.json", notification: notification, for: user)
    else
      {:error, reason} ->
        conn
        |> put_status(:forbidden)
        |> json(%{"error" => reason})
    end
  end

  # POST /api/v1/notifications/clear
  def clear(%{assigns: %{user: user}} = conn, _params) do
    Notification.clear(user)
    json(conn, %{})
  end

  # POST /api/v1/notifications/:id/dismiss
  def dismiss(%{assigns: %{user: user}} = conn, %{id: id} = _params) do
    with {:ok, _notif} <- Notification.dismiss(user, id) do
      json(conn, %{})
    else
      {:error, reason} ->
        conn
        |> put_status(:forbidden)
        |> json(%{"error" => reason})
    end
  end

  # POST /api/v1/notifications/dismiss (deprecated)
  def dismiss_via_body(%{body_params: params} = conn, _) do
    dismiss(conn, params)
  end

  # DELETE /api/v1/notifications/destroy_multiple
  def destroy_multiple(%{assigns: %{user: user}} = conn, %{ids: ids} = _params) do
    Notification.destroy_multiple(user, ids)
    json(conn, %{})
  end

  defp do_get_notifications(%{assigns: %{user: user}} = conn, params) do
    params = normalize_notification_params(params)
    notifications = MastodonAPI.get_notifications(user, params)

    conn
    |> add_link_headers(notifications)
    |> render("index.json",
      notifications: notifications,
      for: user
    )
  end

  defp do_get_grouped_notifications(%{assigns: %{user: user}} = conn, params) do
    params = normalize_notification_params(params)

    {notification_groups, page_notifications, notification_group_counts,
     notification_group_bounds} =
      MastodonAPI.get_grouped_notification_page(user, params)

    conn
    |> add_link_headers(page_notifications, %{drop_id_params: true})
    |> render("grouped_index.json",
      notification_groups: notification_groups,
      notification_group_counts: notification_group_counts,
      notification_group_bounds: notification_group_bounds,
      for: user,
      grouped_types: params["grouped_types"]
    )
  end

  defp do_show_group(conn, user, group_key) do
    {notifications, notification_group_counts, notification_group_bounds} =
      MastodonAPI.get_notification_group_result(user, group_key, %{})

    if Enum.empty?(notifications) do
      conn
      |> put_status(:not_found)
      |> json(%{"error" => "Notification group is not found"})
    else
      grouped_types = if String.starts_with?(group_key, "ungrouped-"), do: [], else: nil

      render(conn, "grouped_index.json",
        notification_groups: [notifications],
        notification_group_counts: notification_group_counts,
        notification_group_bounds: notification_group_bounds,
        for: user,
        grouped_types: grouped_types,
        include_page_metadata: false
      )
    end
  end

  defp do_group_accounts(conn, user, group_key) do
    # Mastodon paginates this endpoint in code, but the public docs say it returns accounts of all
    # notifications in the group and do not document cursor params here. Follow the documented API.
    users = MastodonAPI.get_notification_group_accounts(user, group_key)

    json(conn, AccountView.render("index.json", %{users: users, for: user}))
  end

  defp do_get_unread_group_count(%{assigns: %{user: user}} = conn, params) do
    params = normalize_notification_params(params)
    json(conn, %{count: MastodonAPI.unread_notification_group_count(user, params)})
  end

  defp normalize_notification_params(params) do
    params
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("types", Map.get(params, :include_types, @default_notification_types))
  end
end
