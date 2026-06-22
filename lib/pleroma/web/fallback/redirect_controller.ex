# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Fallback.RedirectController do
  use Pleroma.Web, :controller

  require Logger

  alias Pleroma.User
  alias Pleroma.Web.Metadata
  alias Pleroma.Web.Preload

  @fallback_index """
  <!DOCTYPE html>
  <html>
    <head><!--server-generated-meta--></head>
    <body><div id="soapbox"></div></body>
  </html>
  """

  @static_fallback_roots ~w(doc emoji finmoji images instance packs schemas sounds static static-fe)
  @static_fallback_files ~w(embed.css embed.js favicon.png manifest.json manifest.webmanifest robots.txt sw.js sw.mjs sw-pleroma.js)

  def api_not_implemented(conn, _params) do
    conn
    |> put_status(404)
    |> json(%{error: "Not implemented"})
  end

  def redirector(conn, params, code \\ 200) do
    redirector_with_ssr(conn, params, [:title, :favicon], code)
  end

  def redirector_with_meta(conn, %{"maybe_nickname_or_id" => maybe_nickname_or_id} = params) do
    with %User{} = user <- User.get_cached_by_nickname_or_id(maybe_nickname_or_id) do
      redirector_with_meta(conn, %{user: user})
    else
      nil ->
        redirector(conn, params)
    end
  end

  def redirector_with_meta(conn, params) do
    redirector_with_ssr(conn, params, [:tags, :preload, :title, :favicon])
  end

  def redirector_with_preload(conn, %{"path" => ["pleroma", "admin"]}) do
    redirect(conn, to: "/pleroma/admin/")
  end

  def redirector_with_preload(conn, params) do
    redirector_with_ssr(conn, params, [:preload, :title, :favicon])
  end

  defp redirector_with_ssr(conn, params, keys, code \\ 200) do
    if static_fallback_miss?(conn) do
      static_not_found(conn)
    else
      index_content = read_index_content()

      meta = compose_meta(conn, params, keys)

      response =
        index_content
        |> String.replace("<!--server-generated-meta-->", Enum.join(meta))

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(code, response)
    end
  end

  def registration_page(conn, params) do
    redirector(conn, params)
  end

  def empty(conn, _params) do
    conn
    |> put_status(204)
    |> text("")
  end

  defp index_file_path do
    Pleroma.Web.Plugs.InstanceStatic.file_path("index.html")
  end

  defp static_fallback_miss?(%{path_info: [root | _], request_path: "/" <> path}) do
    root in @static_fallback_roots or path in @static_fallback_files
  end

  defp static_fallback_miss?(_), do: false

  defp static_not_found(conn) do
    if String.ends_with?(String.downcase(conn.request_path), [".json", ".webmanifest"]) do
      conn
      |> put_status(:not_found)
      |> json(%{error: "not found"})
    else
      conn
      |> put_status(:not_found)
      |> put_resp_content_type("text/plain")
      |> text("Not found")
    end
  end

  defp read_index_content do
    index_path = index_file_path()

    case File.read(index_path) do
      {:ok, index_content} ->
        index_content

      {:error, reason} ->
        Logger.warning("Could not read frontend index at #{index_path}: #{inspect(reason)}")
        @fallback_index
    end
  end

  defp compose_meta(conn, params, attrs) when is_list(attrs) do
    Enum.map(attrs, fn attr ->
      build_meta(attr, {conn, params})
    end)
  end

  defp build_meta(:tags, {conn, params}) do
    try do
      Metadata.build_tags(params)
    rescue
      e ->
        Logger.error(
          "Metadata rendering for #{conn.request_path} failed.\n" <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        ""
    end
  end

  defp build_meta(:preload, {conn, params}) do
    try do
      Preload.build_tags(conn, params)
    rescue
      e ->
        Logger.error(
          "Preloading for #{conn.request_path} failed.\n" <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        ""
    end
  end

  defp build_meta(:title, _) do
    "<title>#{Pleroma.Config.get([:instance, :name])}</title>"
  end

  defp build_meta(:favicon, _) do
    "<link rel=\"icon\" href=\"#{Pleroma.Config.get([:instance, :favicon])}\">"
  end
end
