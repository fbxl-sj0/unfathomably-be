# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.SourceController do
  use Pleroma.Web, :controller

  alias Pleroma.FollowingRelationship
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.FederatedTargetView
  alias Pleroma.Web.Plugs.OAuthScopesPlug
  alias Pleroma.Workers.Cron.RssSourceIngestWorker

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
    |> render("sources.json", sources: sources, for: user, include_interaction_score: false)
  end

  @doc "GET /api/v1/sources/search"
  def search(%{assigns: %{user: user}} = conn, params) do
    sources = FederatedTarget.search_sources(params)

    conn
    |> put_view(FederatedTargetView)
    |> render("sources.json", sources: sources, for: user, include_interaction_score: false)
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
    case FederatedTarget.resolve_source(id) do
      {:ok, %User{} = source} -> follow_source(conn, user, source)
      {:error, :not_found} -> render_error(conn, :not_found, "Record not found")
    end
  end

  @doc "POST /api/v1/sources/:id/unfollow"
  def unfollow(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    case FederatedTarget.resolve_source(id) do
      {:ok, %User{} = source} -> unfollow_source(conn, user, source)
      {:error, :not_found} -> render_error(conn, :not_found, "Record not found")
    end
  end

  defp follow_source(conn, user, source) do
    if FederatedTarget.rss_source?(source) do
      case follow_rss_source(user, source) do
        {:ok, _user} ->
          schedule_rss_source_ingest(source)
          render_source_relationship(conn, user, source)

        _ ->
          render_error(conn, :forbidden, "Could not follow source")
      end
    else
      case CommonAPI.follow(user, source) do
        {:ok, _follower, followed, _activity} ->
          render_source_relationship(conn, user, followed)

        _ ->
          render_error(conn, :forbidden, "Could not follow source")
      end
    end
  end

  defp unfollow_source(conn, user, source) do
    if FederatedTarget.rss_source?(source) do
      case unfollow_rss_source(user, source) do
        {:ok, _user} ->
          render_source_relationship(conn, user, source)

        _ ->
          render_error(conn, :forbidden, "Could not unfollow source")
      end
    else
      case CommonAPI.unfollow(user, source) do
        {:ok, _follower} ->
          render_source_relationship(conn, user, source)

        _ ->
          render_error(conn, :forbidden, "Could not unfollow source")
      end
    end
  end

  defp follow_rss_source(user, source) do
    with {:ok, _relationship} <-
           %FollowingRelationship{}
           |> FollowingRelationship.changeset(%{
             follower: user,
             following: source,
             state: :follow_accept
           })
           |> Repo.insert(on_conflict: :nothing) do
      User.update_following_count(user)
    end
  end

  defp unfollow_rss_source(user, source) do
    case FollowingRelationship.get(user, source) do
      %FollowingRelationship{} = relationship ->
        with {:ok, _relationship} <- Repo.delete(relationship) do
          User.update_following_count(user)
        end

      nil ->
        User.update_following_count(user)
    end
  end

  defp render_source_relationship(conn, user, source) do
    conn
    |> put_view(FederatedTargetView)
    |> render("source_relationship.json", user: user, source: source)
  end

  defp schedule_rss_source_ingest(source) do
    RssSourceIngestWorker.schedule_source(source)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
