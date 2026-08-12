# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.SetFormatPlug do
  alias Pleroma.Web.MediaType

  import Plug.Conn,
    only: [
      assign: 3,
      fetch_query_params: 1,
      get_req_header: 2,
      get_resp_header: 2,
      put_private: 3,
      put_resp_header: 3,
      register_before_send: 2
    ]

  @known_formats ["html", "xml", "rss", "atom", "activity+json", "json"]
  @activity_pub_media_types [{"application", "activity+json"}, {"application", "ld+json"}]
  @html_media_types [{"text", "html"}]

  def init(_), do: nil

  def call(conn, _) do
    conn = register_before_send(conn, &vary_on_accept/1)
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
    case MediaType.match(get_req_header(conn, "accept"), @activity_pub_media_types) do
      nil -> nil
      _match -> "activity+json"
    end
  end

  # The same profile and object URLs can render HTML or ActivityPub JSON.
  # Preserve variation added by authorized fetch while preventing an
  # intermediary from serving one representation for a different Accept value.
  defp vary_on_accept(conn) do
    vary =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    vary =
      if Enum.any?(vary, &(String.downcase(&1) == "accept")) do
        vary
      else
        vary ++ ["Accept"]
      end

    put_resp_header(conn, "vary", Enum.join(vary, ", "))
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
    MediaType.match(get_req_header(conn, "accept"), @html_media_types) != nil
  end
end
