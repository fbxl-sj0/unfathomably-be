# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.FeatureAuthorizationController do
  use Pleroma.Web, :controller

  alias Pleroma.FeatureAuthorization

  def show(conn, %{"id" => id}) do
    with {:ok, document} <- FeatureAuthorization.authorization_document(id) do
      conn
      |> put_resp_header("cache-control", "public, max-age=30")
      |> put_resp_content_type("application/activity+json")
      |> json(document)
    else
      _other -> send_resp(conn, :not_found, "Not found")
    end
  end
end

# end of feature_authorization_controller.ex
