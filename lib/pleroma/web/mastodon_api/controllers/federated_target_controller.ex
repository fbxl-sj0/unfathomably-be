# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedTargetController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.FederatedTargetView
  alias Pleroma.Web.Plugs.OAuthScopesPlug
  alias Pleroma.Web.Plugs.RateLimiter

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:accounts", "read:follows"]} when action in [:search]
  )

  plug(RateLimiter, [name: :federated_target_search] when action in [:search])

  @doc "GET /api/v1/discovery/targets"
  def search(%{assigns: %{user: user}} = conn, params) do
    targets = FederatedTarget.search_catalog(params)

    conn
    |> put_view(FederatedTargetView)
    |> render("targets.json",
      targets: targets,
      for: user,
      include_interaction_score: false,
      refresh_counts: false
    )
  end
end
