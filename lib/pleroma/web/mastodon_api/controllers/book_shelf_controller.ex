# Unfathomably native book library
# ---------------------------------
#
# File: book_shelf_controller.ex
#
# Purpose:
#
#   Expose a small authenticated API for a user's federated book library.
#
# Responsibilities:
#
#   * list entries grouped into familiar reading shelves
#   * add or move a book and update optional progress
#   * remove a book from the local library
#
# This file intentionally does NOT implement ActivityPub serialization.

defmodule Pleroma.Web.MastodonAPI.BookShelfController do
  use Pleroma.Web, :controller

  alias Pleroma.BookShelfEntry
  alias Pleroma.User
  alias Pleroma.WorldParticipation
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["read:statuses"]} when action == :index)
  plug(OAuthScopesPlug, %{scopes: ["write:statuses"]} when action in [:put, :delete])

  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  def index(%{assigns: %{user: user}} = conn, params) do
    entries = BookShelfEntry.list(user, params["shelf"])

    render_library(conn, user, entries)
  end

  def account_index(conn, params) do
    with {:ok, user} <- visible_user(conn, params["id"] || params[:id]) do
      entries = BookShelfEntry.list(user, params["shelf"] || params[:shelf])
      render_library(conn, user, entries)
    end
  end

  def worlds(conn, params) do
    with {:ok, user} <- visible_user(conn, params["id"] || params[:id]) do
      json(conn, %{
        account_id: to_string(user.id),
        families: WorldParticipation.list(user)
      })
    end
  end

  defp render_library(conn, user, entries) do
    json(conn, %{
      shelves:
        Enum.map(BookShelfEntry.shelves(), fn shelf ->
          %{
            id: shelf,
            name: shelf_name(shelf),
            items:
              entries |> Enum.filter(&(&1.shelf == shelf)) |> Enum.map(&render_entry(user, &1))
          }
        end),
      total: length(entries)
    })
  end

  def put(%{assigns: %{user: user}, body_params: params} = conn, _) do
    with {:ok, entry} <- BookShelfEntry.put(user, params) do
      json(conn, render_entry(user, entry))
    end
  end

  def delete(%{assigns: %{user: user}} = conn, params) do
    book_uri = params["book_uri"] || conn.body_params["book_uri"] || conn.body_params[:book_uri]

    with {:ok, _entry} <- BookShelfEntry.remove(user, book_uri) do
      json(conn, %{})
    end
  end

  defp render_entry(user, entry) do
    %{
      id: to_string(entry.id),
      book_uri: entry.book_uri,
      shelf: entry.shelf,
      progress: entry.progress,
      progress_mode: entry.progress_mode,
      presentation: entry.presentation,
      collection_url: BookShelfEntry.collection_uri(user, entry.shelf),
      started_at: entry.started_at,
      finished_at: entry.finished_at,
      updated_at: entry.updated_at
    }
  end

  defp visible_user(conn, id) when is_binary(id) do
    reading_user = conn.assigns[:user]

    with %User{} = user <- User.get_cached_by_nickname_or_id(id, for: reading_user),
         :visible <- User.visible_for(user, reading_user) do
      {:ok, user}
    else
      _error -> {:error, :not_found}
    end
  end

  defp visible_user(_conn, _id), do: {:error, :not_found}

  defp shelf_name("to-read"), do: "Want to read"
  defp shelf_name("reading"), do: "Reading"
  defp shelf_name("read"), do: "Read"
  defp shelf_name("stopped-reading"), do: "Stopped reading"
end

# end of book_shelf_controller.ex
