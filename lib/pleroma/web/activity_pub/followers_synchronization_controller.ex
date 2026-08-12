# Unfathomably follower synchronization endpoint
#
# File: followers_synchronization_controller.ex
#
# Purpose:
#   Return the FEP-8fcf partial follower collection for a signed requester.

defmodule Pleroma.Web.ActivityPub.FollowersSynchronizationController do
  use Pleroma.Web, :controller

  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.FollowersSynchronization
  alias Pleroma.Web.ActivityPub.Utils

  def show(conn, %{"nickname" => nickname}) do
    with true <- FollowersSynchronization.enabled?(),
         true <- conn.assigns[:valid_signature] == true,
         %User{local: false} = requester <- conn.assigns[:user],
         %User{local: true} = actor <- User.get_cached_by_nickname(nickname) do
      json(
        conn,
        Utils.make_json_ld_header()
        |> Map.merge(FollowersSynchronization.partial_collection(actor, requester))
      )
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Not found"})
    end
  end
end

# end of followers_synchronization_controller.ex
