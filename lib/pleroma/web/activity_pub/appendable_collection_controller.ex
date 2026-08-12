# Unfathomably appendable collection HTTP endpoint
#
# File: appendable_collection_controller.ex
#
# Purpose:
#   Render confirmed public members of a local actor wall.

defmodule Pleroma.Web.ActivityPub.AppendableCollectionController do
  use Pleroma.Web, :controller

  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.AppendableCollection
  alias Pleroma.Web.ActivityPub.Utils

  def show(conn, %{"nickname" => nickname}) do
    with true <- AppendableCollection.enabled?(),
         %User{local: true} = owner <- User.get_cached_by_nickname(nickname) do
      items = AppendableCollection.items(owner)

      json(
        conn,
        Utils.make_json_ld_header()
        |> Map.merge(%{
          "id" => AppendableCollection.collection_id(owner),
          "type" => "OrderedCollection",
          "attributedTo" => owner.ap_id,
          "totalItems" => length(items),
          "orderedItems" => items
        })
      )
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Not found"})
    end
  end
end

# end of appendable_collection_controller.ex
