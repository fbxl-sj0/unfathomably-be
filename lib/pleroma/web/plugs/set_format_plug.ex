# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.SetFormatPlug do
  import Plug.Conn, only: [assign: 3, fetch_query_params: 1, get_req_header: 2, put_private: 3]

  @known_formats ["html", "xml", "rss", "atom", "activity+json", "json"]

  def init(_), do: nil

  def call(conn, _) do
    {conn, format} = normalize_remote_profile_format(conn, get_format(conn))

    case format do
      nil -> conn
      format -> assign(conn, :format, format)
    end
  end

  defp get_format(%{private: %{phoenix_format: "html"}} = conn) do
    activity_pub_accept_format(conn) || query_format(conn) || "html"
  end

  defp get_format(conn) do
    conn.private[:phoenix_format] || query_format(conn)
  end

  defp query_format(conn) do
    case fetch_query_params(conn) do
      %{query_params: %{"_format" => format}} -> format
      _ -> nil
    end
  end

  defp activity_pub_accept_format(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&activity_pub_accept?/1)
    |> case do
      true -> "activity+json"
      false -> nil
    end
  end

  defp activity_pub_accept?(accept) do
    accept = String.downcase(accept)

    String.contains?(accept, "application/activity+json") ||
      String.contains?(accept, "application/ld+json")
  end

  defp normalize_remote_profile_format(
         %{path_info: ["users", nickname]} = conn,
         format
       )
       when format not in @known_formats do
    if String.contains?(nickname, "@") and accepts_html?(conn) do
      conn =
        conn
        |> put_private(:phoenix_format, "html")
        |> then(&%{&1 | params: Map.put(&1.params, "_format", "html")})

      {conn, "html"}
    else
      {conn, format}
    end
  end

  defp normalize_remote_profile_format(conn, format), do: {conn, format}

  defp accepts_html?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(fn accept -> String.contains?(String.downcase(accept), "text/html") end)
  end
end
