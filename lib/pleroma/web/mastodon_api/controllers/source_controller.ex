# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.SourceController do
  use Pleroma.Web, :controller

  alias Pleroma.FollowingRelationship
  alias Pleroma.RSSFeed
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.FederatedTargetView
  alias Pleroma.Web.Plugs.OAuthScopesPlug
  alias Pleroma.Workers.RSSFeedWorker

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:accounts", "read:follows"]}
    when action in [:index, :relationships, :show, :lookup, :search, :items]
  )

  plug(
    OAuthScopesPlug,
    %{scopes: ["follow", "write:follows"]} when action in [:follow, :unfollow]
  )

  @doc "GET /api/v1/sources"
  def index(%{assigns: %{user: user}} = conn, params) do
    sources = FederatedTarget.list_sources(user, params)

    conn
    |> put_view(FederatedTargetView)
    |> render("sources.json", sources: sources, for: user)
  end

  @doc "GET /api/v1/sources/search"
  def search(%{assigns: %{user: user}} = conn, params) do
    sources = FederatedTarget.search_sources(params)

    conn
    |> put_view(FederatedTargetView)
    |> render("sources.json", sources: sources, for: user)
  end

  @doc "GET /api/v1/sources/lookup"
  def lookup(%{assigns: %{user: user}} = conn, params) do
    case FederatedTarget.resolve_source(params["name"] || params[:name]) do
      {:ok, %User{} = source} ->
        conn
        |> put_view(FederatedTargetView)
        |> render("source.json", source: source, for: user)

      _ ->
        render_error(conn, :not_found, "Record not found")
    end
  end

  @doc "GET /api/v1/sources/relationships"
  def relationships(%{assigns: %{user: user}} = conn, params) do
    sources =
      params
      |> relationship_ids()
      |> Enum.flat_map(fn id ->
        case FederatedTarget.resolve_source(id) do
          {:ok, %User{} = source} -> [source]
          _ -> []
        end
      end)

    conn
    |> put_view(FederatedTargetView)
    |> render("source_relationships.json", sources: sources, user: user)
  end

  @doc "GET /api/v1/sources/:id"
  def show(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    case FederatedTarget.resolve_source(id) do
      {:ok, %User{} = source} ->
        conn
        |> put_view(FederatedTargetView)
        |> render("source.json", source: source, for: user)

      _ ->
        render_error(conn, :not_found, "Record not found")
    end
  end

  @doc "GET /api/v1/sources/:id/items"
  def items(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    with {:ok, %User{} = source} <- FederatedTarget.resolve_source(id),
         {:ok, source_items} <- FederatedTarget.source_items_result(source, params, user) do
      json(conn, source_items)
    else
      {:error, :not_found} ->
        render_error(conn, :not_found, "Record not found")

      {:error, reason} ->
        source_items_error(conn, reason)
    end
  end

  @doc "POST /api/v1/sources/:id/follow"
  def follow(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, %User{} = source} <- FederatedTarget.resolve_source(id),
         {:ok, followed} <- follow_source(user, source) do
      conn
      |> put_view(FederatedTargetView)
      |> render("source_relationship.json", user: user, source: followed)
    else
      {:error, :not_found} -> render_error(conn, :not_found, "Record not found")
      _ -> render_error(conn, :forbidden, "Could not follow source")
    end
  end

  @doc "POST /api/v1/sources/:id/unfollow"
  def unfollow(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, %User{} = source} <- FederatedTarget.resolve_source(id),
         {:ok, _follower} <- unfollow_source(user, source) do
      conn
      |> put_view(FederatedTargetView)
      |> render("source_relationship.json", user: user, source: source)
    else
      {:error, :not_found} -> render_error(conn, :not_found, "Record not found")
      _ -> render_error(conn, :forbidden, "Could not unfollow source")
    end
  end

  defp follow_source(%User{} = user, %User{} = source) do
    if RSSFeed.rss_source?(source) do
      with {:ok, _follower, followed} <-
             FollowingRelationship.follow(user, source, :follow_accept) do
        _ = RSSFeedWorker.enqueue(followed)
        {:ok, followed}
      end
    else
      with {:ok, _follower, followed, _activity} <- CommonAPI.follow(user, source) do
        {:ok, followed}
      end
    end
  end

  defp unfollow_source(%User{} = user, %User{} = source) do
    if RSSFeed.rss_source?(source) do
      case FollowingRelationship.unfollow(user, source) do
        {:ok, follower, _followed} -> {:ok, follower}
        {:ok, follower} -> {:ok, follower}
        error -> error
      end
    else
      CommonAPI.unfollow(user, source)
    end
  end

  defp relationship_ids(params) do
    params
    |> Map.get("id", Map.get(params, :id, []))
    |> List.wrap()
  end

  defp source_items_error(conn, reason) do
    case reason do
      :invalid_source ->
        render_error(
          conn,
          :unprocessable_entity,
          "Source is not a previewable ActivityPub collection"
        )

      :invalid_body ->
        render_error(conn, :bad_gateway, "Remote source returned invalid ActivityPub JSON")

      :empty_collection ->
        render_error(conn, :bad_gateway, "Remote source did not expose preview items")

      _ ->
        render_error(conn, :bad_gateway, "Remote source preview is unavailable")
    end
  end
end
