# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedGroupController do
  use Pleroma.Web, :controller

  alias Pleroma.GroupMembership
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.Web.MastodonAPI.FederatedTargetView
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:accounts", "read:follows"]}
    when action in [:index, :relationships, :search, :memberships, :membership_requests, :blocks]
  )

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:accounts", "read:follows"], fallback: :proceed_unauthenticated}
    when action in [:show, :lookup, :preview]
  )

  plug(
    OAuthScopesPlug,
    %{scopes: ["follow", "write:follows"]} when action in [:join, :leave, :follow, :unfollow]
  )

  plug(
    OAuthScopesPlug,
    %{scopes: ["write", "write:accounts"]}
    when action in [
           :create,
           :update,
           :delete,
           :authorize_membership_request,
           :reject_membership_request,
           :promote,
           :demote,
           :kick,
           :block,
           :unblock
         ]
  )

  @doc "POST /api/v1/groups"
  def create(%{assigns: %{user: user}} = conn, params) do
    case FederatedTarget.create_local_group(user, params) do
      {:ok, %User{} = group} ->
        conn
        |> put_view(FederatedTargetView)
        |> render("group.json", group: group, for: user)

      {:error, :nickname_taken} ->
        render_error(conn, :bad_request, "Group name is already taken")

      _ ->
        render_error(conn, :bad_request, "Could not create group")
    end
  end

  @doc "PUT /api/v1/groups/:id"
  def update(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, %User{} = group} <- FederatedTarget.update_local_group(group, user, params) do
      conn
      |> put_view(FederatedTargetView)
      |> render("group.json", group: group, for: user)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :not_local_group} ->
        render_error(conn, :bad_request, "Only local groups can be updated")

      {:error, :forbidden} ->
        render_error(conn, :forbidden, "You cannot update this group")

      _ ->
        render_error(conn, :bad_request, "Could not update group")
    end
  end

  @doc "DELETE /api/v1/groups/:id"
  def delete(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, _group} <- FederatedTarget.delete_local_group(group, user) do
      json(conn, %{})
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :not_local_group} ->
        render_error(conn, :bad_request, "Only local groups can be deleted")

      {:error, :forbidden} ->
        render_error(conn, :forbidden, "You cannot delete this group")

      _ ->
        render_error(conn, :bad_request, "Could not delete group")
    end
  end

  @doc "GET /api/v1/groups"
  def index(%{assigns: %{user: user}} = conn, params) do
    groups = FederatedTarget.list_groups(user, params)

    conn
    |> put_view(FederatedTargetView)
    |> render("groups.json",
      groups: groups,
      for: user,
      include_interaction_score: false,
      refresh_counts: false
    )
  end

  @doc "GET /api/v1/groups/search"
  def search(%{assigns: %{user: user}} = conn, params) do
    groups = FederatedTarget.search_groups(params)

    conn
    |> put_view(FederatedTargetView)
    |> render("groups.json",
      groups: groups,
      for: user,
      include_interaction_score: false,
      refresh_counts: false
    )
  end

  @doc "GET /api/v1/groups/lookup"
  def lookup(conn, params) do
    user = conn.assigns[:user]

    case FederatedTarget.resolve_group(group_lookup_identifier(params)) do
      {:ok, %User{} = group} ->
        conn
        |> put_view(FederatedTargetView)
        |> render("group.json",
          group: group,
          for: user,
          include_interaction_score: false,
          refresh_counts: false
        )

      _ ->
        render_error(conn, :not_found, "Record not found")
    end
  end

  defp group_lookup_identifier(params) do
    params["name"] || params[:name] || params["acct"] || params[:acct] || params["uri"] ||
      params[:uri]
  end

  @doc "GET /api/v1/groups/relationships"
  def relationships(%{assigns: %{user: user}} = conn, params) do
    groups =
      params
      |> relationship_ids()
      |> Enum.flat_map(fn id ->
        case FederatedTarget.resolve_group(id) do
          {:ok, %User{} = group} -> [group]
          _ -> []
        end
      end)

    conn
    |> put_view(FederatedTargetView)
    |> render("group_relationships.json", groups: groups, user: user)
  end

  @doc "GET /api/v1/groups/:id"
  def show(conn, %{"id" => id}) do
    user = conn.assigns[:user]

    case FederatedTarget.resolve_group(id) do
      {:ok, %User{} = group} ->
        conn
        |> put_view(FederatedTargetView)
        |> render("group.json",
          group: group,
          for: user,
          include_interaction_score: false,
          refresh_counts: false
        )

      _ ->
        render_error(conn, :not_found, "Record not found")
    end
  end

  @doc "GET /api/v1/groups/:id/memberships"
  def memberships(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id) do
      memberships = GroupMembership.members(group, params["role"] || params[:role] || "user")

      conn
      |> put_view(FederatedTargetView)
      |> render("group_memberships.json", memberships: memberships, for: user)
    else
      {:error, :not_found} -> render_error(conn, :not_found, "Record not found")
    end
  end

  @doc "GET /api/v1/groups/:id/membership_requests"
  def membership_requests(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         :ok <- GroupMembership.require_manager(user, group) do
      accounts = GroupMembership.membership_requests(group)

      conn
      |> put_view(AccountView)
      |> render("index.json", users: accounts, for: user, as: :user)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :not_local_group} ->
        render_error(conn, :bad_request, "Only local groups have join requests")

      {:error, :forbidden} ->
        render_error(conn, :forbidden, "You cannot manage this group")
    end
  end

  @doc "POST /api/v1/groups/:id/membership_requests/:account_id/authorize"
  def authorize_membership_request(
        %{assigns: %{user: user}} = conn,
        %{"id" => id, "account_id" => account_id}
      ) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, %User{} = account} <- account_from_id(account_id),
         {:ok, _follower, _membership} <- GroupMembership.approve(user, group, account) do
      conn
      |> put_view(FederatedTargetView)
      |> render("group_relationship.json", user: account, group: group)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :not_local_group} ->
        render_error(conn, :bad_request, "Only local groups have join requests")

      {:error, :forbidden} ->
        render_error(conn, :forbidden, "You cannot manage this group")

      _ ->
        render_error(conn, :bad_request, "Could not approve join request")
    end
  end

  @doc "POST /api/v1/groups/:id/membership_requests/:account_id/reject"
  def reject_membership_request(
        %{assigns: %{user: user}} = conn,
        %{"id" => id, "account_id" => account_id}
      ) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, %User{} = account} <- account_from_id(account_id),
         {:ok, _follower} <- GroupMembership.reject(user, group, account) do
      conn
      |> put_view(FederatedTargetView)
      |> render("group_relationship.json", user: account, group: group)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :not_local_group} ->
        render_error(conn, :bad_request, "Only local groups have join requests")

      {:error, :forbidden} ->
        render_error(conn, :forbidden, "You cannot manage this group")

      _ ->
        render_error(conn, :bad_request, "Could not reject join request")
    end
  end

  @doc "GET /api/v1/groups/:id/preview"
  def preview(conn, %{"id" => id} = params) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, group_items} <-
           FederatedTarget.group_items_result(group, params, conn.assigns[:user]) do
      json(conn, group_items)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, reason} ->
        group_preview_error(conn, reason)
    end
  end

  @doc "POST /api/v1/groups/:id/join"
  def join(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, followed} <- join_group(user, group) do
      conn
      |> put_view(FederatedTargetView)
      |> render("group_relationship.json", user: user, group: followed)
    else
      {:error, :not_found} -> render_error(conn, :not_found, "Record not found")
      {:error, :banned} -> render_error(conn, :forbidden, "You are banned from this group")
      _ -> render_error(conn, :forbidden, "Could not join group")
    end
  end

  @doc "POST /api/v1/groups/:id/leave"
  def leave(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, _follower} <- leave_group(user, group) do
      conn
      |> put_view(FederatedTargetView)
      |> render("group_relationship.json", user: user, group: group)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :owner} ->
        render_error(conn, :forbidden, "Group owners cannot leave their own groups")

      _ ->
        render_error(conn, :forbidden, "Could not leave group")
    end
  end

  def follow(conn, params), do: join(conn, params)
  def unfollow(conn, params), do: leave(conn, params)

  @doc "POST /api/v1/groups/:id/promote"
  def promote(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, %User{} = account} <- account_from_params(params),
         {:ok, [membership | _]} <-
           GroupMembership.promote(user, group, [account], Map.get(params, "role", "moderator")) do
      conn
      |> put_view(FederatedTargetView)
      |> render("group_membership.json", membership: membership, for: user)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :not_local_group} ->
        render_error(conn, :bad_request, "Only local groups have moderators")

      {:error, :forbidden} ->
        render_error(conn, :forbidden, "You cannot manage this group")

      _ ->
        render_error(conn, :bad_request, "Could not promote group member")
    end
  end

  @doc "POST /api/v1/groups/:id/demote"
  def demote(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, %User{} = account} <- account_from_params(params),
         {:ok, [membership | _]} <- GroupMembership.demote(user, group, [account], "user") do
      conn
      |> put_view(FederatedTargetView)
      |> render("group_membership.json", membership: membership, for: user)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :not_local_group} ->
        render_error(conn, :bad_request, "Only local groups have moderators")

      {:error, :forbidden} ->
        render_error(conn, :forbidden, "You cannot manage this group")

      _ ->
        render_error(conn, :bad_request, "Could not demote group moderator")
    end
  end

  @doc "POST /api/v1/groups/:id/kick"
  def kick(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, %User{} = account} <- account_from_params(params),
         :ok <- GroupMembership.kick(user, group, [account]) do
      json(conn, %{})
    else
      error -> group_management_error(conn, error, :kick)
    end
  end

  @doc "GET /api/v1/groups/:id/blocks"
  def blocks(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         :ok <- GroupMembership.require_manager(user, group) do
      accounts = GroupMembership.banned_accounts(group)

      conn
      |> put_view(AccountView)
      |> render("index.json", users: accounts, for: user, as: :user)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :not_local_group} ->
        render_error(conn, :bad_request, "Only local groups have bans")

      {:error, :forbidden} ->
        render_error(conn, :forbidden, "You cannot manage this group")
    end
  end

  @doc "POST /api/v1/groups/:id/blocks"
  def block(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, %User{} = account} <- account_from_params(params),
         {:ok, _memberships} <- GroupMembership.ban(user, group, [account]) do
      json(conn, %{})
    else
      error -> group_management_error(conn, error, :block)
    end
  end

  @doc "DELETE /api/v1/groups/:id/blocks"
  def unblock(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, %User{} = group} <- FederatedTarget.resolve_group(id),
         {:ok, %User{} = account} <- account_from_params(params),
         :ok <- GroupMembership.unban(user, group, [account]) do
      json(conn, %{})
    else
      error -> group_management_error(conn, error, :unblock)
    end
  end

  defp join_group(%User{} = user, %User{local: true, actor_type: "Group"} = group) do
    with {:ok, _follower, followed, _activity} <- GroupMembership.join(user, group) do
      {:ok, followed}
    end
  end

  defp join_group(%User{} = user, %User{} = group) do
    with {:ok, _follower, followed, _activity} <- CommonAPI.follow(user, group) do
      {:ok, followed}
    end
  end

  defp leave_group(%User{} = user, %User{local: true, actor_type: "Group"} = group) do
    GroupMembership.leave(user, group)
  end

  defp leave_group(%User{} = user, %User{} = group), do: CommonAPI.unfollow(user, group)

  defp account_from_params(params) do
    params
    |> Map.get("account_id", Map.get(params, :account_id))
    |> List.wrap()
    |> Enum.concat(List.wrap(Map.get(params, "account_ids", Map.get(params, :account_ids, []))))
    |> Enum.concat(List.wrap(Map.get(params, "account_ids[]", [])))
    |> List.first()
    |> account_from_id()
  end

  defp account_from_id(id) when is_binary(id) do
    case User.get_cached_by_id(id) do
      %User{} = user -> {:ok, user}
      _ -> {:error, :not_found}
    end
  end

  defp account_from_id(_), do: {:error, :not_found}

  defp group_management_error(conn, error, action) do
    case {error, action} do
      {{:error, :not_found}, _} ->
        render_error(conn, :not_found, "Record not found")

      {{:error, :not_local_group}, _} ->
        render_error(conn, :bad_request, "Only local groups can be managed")

      {{:error, :forbidden}, _} ->
        render_error(conn, :forbidden, "You cannot manage this group")

      {_, :kick} ->
        render_error(conn, :bad_request, "Could not remove group member")

      {_, :block} ->
        render_error(conn, :bad_request, "Could not ban group member")

      {_, :unblock} ->
        render_error(conn, :bad_request, "Could not unban group member")
    end
  end

  defp relationship_ids(params) do
    params
    |> Map.get("id", Map.get(params, :id, []))
    |> List.wrap()
  end

  defp group_preview_error(conn, reason) do
    case reason do
      :invalid_source ->
        render_error(conn, :unprocessable_entity, "Group is not a previewable ActivityPub actor")

      :invalid_body ->
        render_error(conn, :bad_gateway, "Remote group returned invalid ActivityPub JSON")

      :empty_collection ->
        render_error(conn, :bad_gateway, "Remote group did not expose preview items")

      _ ->
        render_error(conn, :bad_gateway, "Remote group preview is unavailable")
    end
  end
end
