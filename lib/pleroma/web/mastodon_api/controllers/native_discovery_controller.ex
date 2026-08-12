# Unfathomably native federation discovery API
# ------------------------------------------------
#
# File: native_discovery_controller.ex
#
# Purpose:
#   Expose specialized federation workflows and bounded object discovery.
#
# Responsibilities:
#   - publish a remote-free workflow manifest to all clients
#   - require the normal search OAuth scope
#   - share the explicit remote-discovery rate limit
#   - reject unscoped requests before they fan out across every provider
#   - return the provider-neutral discovery envelope
#
# This file intentionally does not implement provider protocols or persist
# objects returned by a discovery index.

defmodule Pleroma.Web.MastodonAPI.NativeDiscoveryController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.ActivityPub.NativeDiscovery
  alias Pleroma.Web.ActivityPub.NativeWorkflowCatalog
  alias Pleroma.Web.Plugs.OAuthScopesPlug
  alias Pleroma.Web.Plugs.RateLimiter

  plug(OAuthScopesPlug, %{scopes: ["read:search"]} when action in [:index])
  plug(RateLimiter, [name: :federated_target_search] when action in [:index])

  # Family names are short internal identifiers. Bounding the parameter before
  # trimming it avoids allocating or dispatching work for hostile query input.
  @max_family_bytes 64

  @doc "GET /api/v1/discovery/native"
  def index(conn, %{"family" => family} = params)
      when is_binary(family) and byte_size(family) <= @max_family_bytes do
    family = String.trim(family)

    if family == "" do
      invalid_family(conn)
    else
      render_discovery(conn, Map.put(params, "family", family))
    end
  end

  def index(conn, _params), do: invalid_family(conn)

  defp render_discovery(conn, params) do
    result = NativeDiscovery.search(params)

    json(conn, NativeDiscovery.attach_local_status_ids(result, conn.assigns[:user]))
  end

  defp invalid_family(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "The family query parameter is required."})
  end

  @doc "GET /api/v1/discovery/native/workflows"
  def workflows(conn, _params) do
    json(conn, NativeWorkflowCatalog.render())
  end
end

# end of native_discovery_controller.ex
