# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.AuthController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.ControllerHelper
  alias Pleroma.Web.TwitterAPI.TwitterAPI

  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  plug(Pleroma.Web.Plugs.RateLimiter, [name: :password_reset] when action == :password_reset)

  defp json_response(conn, status, json), do: ControllerHelper.json_response(conn, status, json)

  @doc "POST /auth/password"
  def password_reset(conn, params) do
    nickname_or_email = params["email"] || params["nickname"]

    TwitterAPI.password_reset(nickname_or_email)

    json_response(conn, :no_content, "")
  end
end
