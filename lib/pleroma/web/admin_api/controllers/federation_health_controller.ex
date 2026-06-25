# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.AdminAPI.FederationHealthController do
  use Pleroma.Web, :controller

  alias Pleroma.Instances.Health
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["admin:read"]} when action in [:show])

  def show(conn, _params) do
    json(conn, Health.snapshot())
  end
end
