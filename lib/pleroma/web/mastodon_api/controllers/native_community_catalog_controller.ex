# Unfathomably native community catalog API
# ------------------------------------------
#
# File: native_community_catalog_controller.ex
#
# Purpose:
#   Serve the local, operator-approved native community catalog to Worlds.
#
# Responsibilities:
#   - render configured community origins by native-object family
#   - keep the catalog read-only and free of remote fetches
#
# This file intentionally does not resolve actors, load remote content, or
# change follow relationships.

defmodule Pleroma.Web.MastodonAPI.NativeCommunityCatalogController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.ActivityPub.NativeCommunityCatalog

  @doc "GET /api/v1/discovery/native-communities"
  def index(conn, params) do
    catalog = NativeCommunityCatalog.list(params)

    conn
    # The catalog is public, contains no viewer-specific fields, and refreshes
    # its locally-known actor projection on the same five-minute cadence. A
    # warming response is deliberately short-lived so clients can pick up the
    # background-built local actor cards without waiting for the normal cache.
    |> put_resp_header(
      "cache-control",
      if(catalog.refreshing, do: "public, max-age=10", else: "public, max-age=300")
    )
    |> json(catalog)
  end
end

# end of native_community_catalog_controller.ex
