# Pleroma: Mastodon API federation status controller
# --------------------------------------------------
#
# File: federation_status_controller.ex
#
# Purpose:
#
#     Expose local federation-policy awareness to clients before they try to
#     search, follow, or post to a remote host that local policy blocks.
#
# Responsibilities:
#
#     * accept host, acct, URL, or q query parameters
#     * return the normalized local federation status object
#
# This file intentionally does NOT contain:
#
#     * ActivityPub fetching
#     * admin federation-policy mutation
#     * frontend-specific message formatting

defmodule Pleroma.Web.MastodonAPI.FederationStatusController do
  use Pleroma.Web, :controller

  alias Pleroma.FederationStatus
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:accounts"], fallback: :proceed_unauthenticated} when action in [:show]
  )

  @doc "GET /api/v1/federation/status"
  def show(conn, params) do
    identifier =
      params["host"] ||
        params[:host] ||
        params["acct"] ||
        params[:acct] ||
        params["uri"] ||
        params[:uri] ||
        params["q"] ||
        params[:q] ||
        ""

    json(conn, FederationStatus.for_identifier(identifier))
  end
end

# end of lib/pleroma/web/mastodon_api/controllers/federation_status_controller.ex
