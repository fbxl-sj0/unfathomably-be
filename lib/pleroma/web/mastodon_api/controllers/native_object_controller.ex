# Unfathomably BE
# ----------------
#
# File: native_object_controller.ex
#
# Purpose:
#   Expose authenticated Worlds object authoring through the Mastodon API.
#
# Responsibilities:
#   - require the normal write:statuses OAuth scope
#   - share the ordinary status-post rate limit
#   - render successful objects with the existing status view
#
# This file intentionally does not define ActivityPub vocabularies or accept
# arbitrary object maps.

defmodule Pleroma.Web.MastodonAPI.NativeObjectController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.ActivityPub.NativeObject
  alias Pleroma.Web.MastodonAPI.StatusView
  alias Pleroma.Web.Plugs.OAuthScopesPlug
  alias Pleroma.Web.Plugs.RateLimiter

  plug(OAuthScopesPlug, %{scopes: ["write:statuses"]} when action in [:create])
  plug(RateLimiter, [name: :statuses_post] when action in [:create])

  @doc "POST /api/v1/discovery/native-objects"
  def create(%{assigns: %{user: user}} = conn, params) do
    with {:ok, activity} <- NativeObject.create(user, params) do
      conn
      |> put_view(StatusView)
      |> render("show.json",
        activity: activity,
        for: user,
        as: :activity,
        with_direct_conversation_id: true
      )
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: public_error(reason)})
    end
  end

  defp public_error(reason) when is_binary(reason), do: reason
  defp public_error(_reason), do: "The native object could not be created"
end

# end of lib/pleroma/web/mastodon_api/controllers/native_object_controller.ex
