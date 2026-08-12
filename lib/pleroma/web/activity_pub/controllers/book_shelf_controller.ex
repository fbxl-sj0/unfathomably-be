# Unfathomably BookWyrm shelf federation
# --------------------------------------
#
# File: book_shelf_controller.ex
#
# Purpose:
#
#   Serve local reading shelves as BookWyrm-compatible ActivityPub collections.
#
# Responsibilities:
#
#   * resolve local shelf owners safely
#   * render Shelf roots and paginated ShelfItem members
#   * preserve owner-relative stable collection identifiers
#
# This file intentionally does NOT mutate shelf membership.

defmodule Pleroma.Web.ActivityPub.BookShelfController do
  use Pleroma.Web, :controller

  alias Pleroma.BookShelfEntry
  alias Pleroma.User

  require Pleroma.Constants

  @page_size 20

  def show(conn, %{"nickname" => nickname, "shelf" => shelf} = params) do
    with true <- shelf in BookShelfEntry.shelves(),
         %User{local: true} = user <- User.get_cached_by_nickname(nickname) do
      entries = BookShelfEntry.list(user, shelf)
      uri = BookShelfEntry.collection_uri(user, shelf)

      body =
        if Map.has_key?(params, "page") do
          page = positive_page(params["page"])
          page_entries = Enum.slice(entries, (page - 1) * @page_size, @page_size)

          %{
            "@context" => "https://www.w3.org/ns/activitystreams",
            "id" => "#{uri}?page=#{page}",
            "type" => "OrderedCollectionPage",
            "partOf" => uri,
            "orderedItems" => Enum.map(page_entries, &BookShelfEntry.shelf_item(user, &1))
          }
          |> put_page_links(uri, page, length(entries))
        else
          %{
            "@context" => "https://www.w3.org/ns/activitystreams",
            "id" => uri,
            "type" => "Shelf",
            "name" => shelf_name(shelf),
            "owner" => user.ap_id,
            "totalItems" => length(entries),
            "first" => "#{uri}?page=1",
            "to" => [Pleroma.Constants.as_public()],
            "cc" => [user.follower_address]
          }
        end

      conn
      |> put_resp_content_type("application/activity+json")
      |> json(body)
    else
      _ -> render_error(conn, :not_found, "Shelf not found")
    end
  end

  defp positive_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp positive_page(_), do: 1

  defp put_page_links(body, uri, page, total) do
    body = if page > 1, do: Map.put(body, "prev", "#{uri}?page=#{page - 1}"), else: body

    if page * @page_size < total,
      do: Map.put(body, "next", "#{uri}?page=#{page + 1}"),
      else: body
  end

  defp shelf_name("to-read"), do: "Want to read"
  defp shelf_name("reading"), do: "Reading"
  defp shelf_name("read"), do: "Read"
  defp shelf_name("stopped-reading"), do: "Stopped reading"
end

# end of book_shelf_controller.ex
