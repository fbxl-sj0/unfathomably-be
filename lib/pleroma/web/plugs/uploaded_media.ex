# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.UploadedMedia do
  @moduledoc """
  """

  import Plug.Conn
  import Pleroma.Web.Gettext
  require Logger

  alias Pleroma.Web.MediaProxy
  alias Pleroma.Web.Plugs.Utils

  @behaviour Plug
  # no slashes
  @path "media"

  @default_cache_control_header "public, max-age=1209600, immutable"
  @content_type_sniff_bytes 8192

  def init(_opts) do
    static_plug_opts =
      [
        headers: %{"cache-control" => @default_cache_control_header},
        cache_control_for_etags: @default_cache_control_header
      ]
      |> Keyword.put(:from, "__unconfigured_media_plug")
      |> Keyword.put(:at, "/__unconfigured_media_plug")
      |> Plug.Static.init()

    allowed_mime_types = Pleroma.Config.get([Pleroma.Upload, :allowed_mime_types], [])

    %{static_plug_opts: static_plug_opts, allowed_mime_types: allowed_mime_types}
  end

  def call(%{request_path: <<"/", @path, "/", file::binary>>} = conn, opts) do
    conn =
      case fetch_query_params(conn) do
        %{query_params: %{"name" => name}} = conn ->
          name = String.replace(name, ~s["], ~s[\\"])

          put_resp_header(conn, "content-disposition", ~s[inline; filename="#{name}"])

        conn ->
          conn
      end
      |> merge_resp_headers([{"content-security-policy", "sandbox"}])

    config = Pleroma.Config.get(Pleroma.Upload)

    with {:ok, uploader} <- Keyword.fetch(config, :uploader),
         proxy_remote = Keyword.get(config, :proxy_remote, false),
         {:ok, get_method} <- uploader.get_file(file),
         false <- media_is_banned(conn, get_method) do
      get_media(conn, get_method, proxy_remote, opts, file)
    else
      :error ->
        media_storage_unavailable(conn)

      {:error, _reason} ->
        media_not_found(conn)

      true ->
        media_not_found(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp media_is_banned(%{request_path: path} = _conn, {:static_dir, _}) do
    MediaProxy.in_banned_urls(Pleroma.Upload.base_url() <> path)
  end

  defp media_is_banned(_, {:url, url}), do: MediaProxy.in_banned_urls(url)

  defp media_is_banned(_, _), do: false

  defp set_content_type(conn, opts, filepath, directory) do
    real_mime = local_content_type(directory, filepath)
    clean_mime = Utils.get_safe_mime_type(opts, real_mime)

    put_resp_header(conn, "content-type", clean_mime)
  end

  defp local_content_type(directory, filepath) do
    case MIME.from_path(filepath) do
      "application/octet-stream" -> sniff_local_content_type(directory, filepath)
      content_type -> content_type
    end
  end

  defp sniff_local_content_type(directory, filepath) do
    with {:ok, path} <- local_media_path(directory, filepath),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        with data when is_binary(data) and data != "" <-
               IO.binread(file, @content_type_sniff_bytes) do
          detected_content_type(data)
        else
          _ -> "application/octet-stream"
        end
      after
        File.close(file)
      end
    else
      _ -> "application/octet-stream"
    end
  rescue
    _ -> "application/octet-stream"
  catch
    _, _ -> "application/octet-stream"
  end

  defp detected_content_type(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: "image/png"
  defp detected_content_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp detected_content_type(<<"GIF87a", _::binary>>), do: "image/gif"
  defp detected_content_type(<<"GIF89a", _::binary>>), do: "image/gif"

  defp detected_content_type(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>),
    do: "image/webp"

  defp detected_content_type(data) do
    case Majic.perform({:bytes, data}, pool: Pleroma.MajicPool) do
      {:ok, %{mime_type: content_type}} when is_binary(content_type) -> content_type
      _ -> "application/octet-stream"
    end
  end

  defp local_media_path(directory, filepath) do
    root = Path.expand(directory)
    path = Path.expand(filepath, root)
    relative_path = Path.relative_to(path, root)

    cond do
      Path.type(relative_path) != :relative -> {:error, :unsafe_path}
      relative_path in ["", "."] -> {:error, :unsafe_path}
      ".." in Path.split(relative_path) -> {:error, :unsafe_path}
      true -> {:ok, path}
    end
  end

  defp get_media(conn, {:static_dir, directory}, _, opts, file) do
    static_opts =
      Map.get(opts, :static_plug_opts)
      |> Map.put(:at, [@path])
      |> Map.put(:from, directory)
      |> Map.put(:content_types, false)

    conn =
      conn
      |> set_content_type(opts, file, directory)
      |> Plug.Static.call(static_opts)

    if conn.halted do
      conn
    else
      conn
      |> send_resp(:not_found, dgettext("errors", "Not found"))
      |> halt()
    end
  end

  defp get_media(conn, {:url, url}, true, _, _) do
    proxy_opts = [
      http: [
        follow_redirect: true,
        pool: :upload
      ]
    ]

    conn
    |> Pleroma.ReverseProxy.call(url, proxy_opts)
  end

  defp get_media(conn, {:url, url}, _, _, _) do
    conn
    |> Phoenix.Controller.redirect(external: url)
    |> halt()
  end

  defp get_media(conn, unknown, _, _, _) do
    Logger.error("#{__MODULE__}: Unknown get strategy: #{inspect(unknown)}")

    conn
    |> send_resp(:internal_server_error, dgettext("errors", "Internal Error"))
    |> halt()
  end

  defp media_not_found(conn) do
    conn
    |> send_resp(:not_found, dgettext("errors", "Not found"))
    |> halt()
  end

  defp media_storage_unavailable(conn) do
    conn
    |> send_resp(:service_unavailable, dgettext("errors", "Media storage is not configured"))
    |> halt()
  end
end
