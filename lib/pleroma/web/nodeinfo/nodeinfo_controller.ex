# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Nodeinfo.NodeinfoController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.Nodeinfo.Nodeinfo

  @nodeinfo_versions ["2.1", "2.0"]
  @schema_base "http://nodeinfo.diaspora.software/ns/schema"
  @schema_base_https "https://nodeinfo.diaspora.software/ns/schema"
  @application_actor_rel "https://www.w3.org/ns/activitystreams#Application"
  @cache_control "public, max-age=300, stale-while-revalidate=60"

  def schemas(conn, _params) do
    response = %{
      links:
        Enum.flat_map(@nodeinfo_versions, fn version ->
          href = Endpoint.url() <> "/nodeinfo/#{version}.json"

          [
            %{rel: schema_rel(version), href: href},
            %{rel: schema_rel_https(version), href: href}
          ]
        end) ++ application_actor_links()
    }

    conn
    |> put_nodeinfo_cache_header()
    |> json(response)
  end

  defp application_actor_links do
    case Marketplace.get_service_actor() do
      {:ok, _actor} ->
        [%{rel: @application_actor_rel, href: Endpoint.url() <> "/users/instance"}]

      {:error, :not_found} ->
        []
    end
  end

  # Schema definition: https://github.com/jhass/nodeinfo/blob/master/schemas/2.0/schema.json
  # and https://github.com/jhass/nodeinfo/blob/master/schemas/2.1/schema.json
  def nodeinfo(conn, %{"version" => raw_version}) do
    version = normalize_version(conn, raw_version)

    case Nodeinfo.get_nodeinfo(version) do
      {:error, :missing} ->
        render_error(conn, :not_found, "Nodeinfo schema version not handled")

      node_info ->
        conn
        |> put_nodeinfo_cache_header()
        |> put_resp_header(
          "content-type",
          "application/json; profile=#{schema_rel(version)}#; charset=utf-8"
        )
        |> json(node_info)
    end
  end

  defp normalize_version(conn, "2") do
    case conn.params["_format"] do
      format when format in ["0", "1"] -> "2.#{format}"
      _ -> "2"
    end
  end

  defp normalize_version(_conn, version), do: version

  defp schema_rel(version), do: "#{@schema_base}/#{version}"
  defp schema_rel_https(version), do: "#{@schema_base_https}/#{version}"
  defp put_nodeinfo_cache_header(conn), do: put_resp_header(conn, "cache-control", @cache_control)
end
