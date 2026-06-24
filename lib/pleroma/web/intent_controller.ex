# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.IntentController do
  use Pleroma.Web, :controller

  @expected_scheme "web+mastodon"

  def show(conn, %{"uri" => uri}) when is_binary(uri) do
    with %URI{scheme: @expected_scheme, host: host} = parsed <- URI.parse(uri),
         query when is_binary(query) <- parsed.query,
         params <- URI.decode_query(query) do
      redirect_intent(conn, host, params)
    else
      _ -> not_found(conn)
    end
  end

  def show(conn, _params), do: not_found(conn)

  defp redirect_intent(conn, "follow", %{"uri" => uri}) when is_binary(uri) and uri != "" do
    uri = String.replace_prefix(uri, "acct:", "")

    redirect(conn, to: Routes.remote_follow_path(conn, :authorize_interaction, %{uri: uri}))
  end

  defp redirect_intent(conn, "share", params) do
    share_params =
      params
      |> Map.take(["title", "text", "url"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    case share_params do
      "" -> redirect(conn, to: "/share")
      query -> redirect(conn, to: "/share?#{query}")
    end
  end

  defp redirect_intent(conn, _host, _params), do: not_found(conn)

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> text("Not Found")
  end
end
