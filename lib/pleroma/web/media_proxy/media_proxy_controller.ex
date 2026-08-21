# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MediaProxy.MediaProxyController do
  use Pleroma.Web, :controller

  alias Pleroma.Config
  alias Pleroma.Helpers.MediaHelper
  alias Pleroma.Helpers.UriHelper
  alias Pleroma.ReverseProxy
  alias Pleroma.Web.MediaProxy
  alias Plug.Conn

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @preview_cache :media_preview_cache

  # The cache is limited to 500 entries by the application supervisor. Keeping
  # each generated body below 256 KiB bounds its worst-case binary memory use.
  @max_cached_preview_bytes 256 * 1024

  plug(:sandbox)

  def remote(conn, %{"sig" => sig64, "url" => url64}) do
    with {_, true} <- {:enabled, MediaProxy.enabled?()},
         {:ok, url} <- MediaProxy.decode_url(sig64, url64),
         :ok <- MediaProxy.verify_remote_http_url(url),
         {_, false} <- {:in_banned_urls, MediaProxy.in_banned_urls(url)},
         :ok <- MediaProxy.verify_request_path_and_url(conn, url) do
      ReverseProxy.media_call(conn, url, media_proxy_opts())
    else
      {:enabled, false} ->
        send_resp(conn, 404, Conn.Status.reason_phrase(404))

      {:in_banned_urls, true} ->
        send_resp(conn, 404, Conn.Status.reason_phrase(404))

      {:error, :unsupported_remote_url} ->
        send_resp(conn, 404, Conn.Status.reason_phrase(404))

      {:error, :invalid_signature} ->
        send_resp(conn, 403, Conn.Status.reason_phrase(403))

      {:wrong_filename, filename} ->
        redirect(conn, external: MediaProxy.build_url(sig64, url64, filename))
    end
  end

  def preview(%Conn{} = conn, %{"sig" => sig64, "url" => url64}) do
    with {_, true} <- {:enabled, MediaProxy.preview_enabled?()},
         {:ok, url} <- MediaProxy.decode_url(sig64, url64),
         :ok <- MediaProxy.verify_remote_http_url(url),
         :ok <- MediaProxy.verify_request_path_and_url(conn, url) do
      handle_preview(conn, url)
    else
      {:enabled, false} ->
        send_resp(conn, 404, Conn.Status.reason_phrase(404))

      {:error, :unsupported_remote_url} ->
        send_resp(conn, 404, Conn.Status.reason_phrase(404))

      {:error, :invalid_signature} ->
        send_resp(conn, 403, Conn.Status.reason_phrase(403))

      {:wrong_filename, filename} ->
        redirect(conn, external: MediaProxy.build_preview_url(sig64, url64, filename))
    end
  end

  defp handle_preview(conn, url) do
    media_proxy_url = MediaProxy.url(url)
    internal_media_proxy_url = MediaProxy.internal_url(url)
    static = conn.params["static"] in ["true", true]

    media_proxy_url
    |> cached_preview_decision(internal_media_proxy_url, static)
    |> render_preview_decision(conn, media_proxy_url)
  end

  defp cached_preview_decision(media_proxy_url, internal_media_proxy_url, static) do
    cache_key = {media_proxy_url, static}

    case @cachex.get(@preview_cache, cache_key) do
      {:ok, nil} ->
        fetch_preview_decision(cache_key, media_proxy_url, internal_media_proxy_url, static)

      {:ok, decision} ->
        decision

      _ ->
        build_preview_decision(media_proxy_url, internal_media_proxy_url, static)
    end
  rescue
    _ -> build_preview_decision(media_proxy_url, internal_media_proxy_url, static)
  catch
    _, _ -> build_preview_decision(media_proxy_url, internal_media_proxy_url, static)
  end

  defp fetch_preview_decision(cache_key, media_proxy_url, internal_media_proxy_url, static) do
    @cachex.fetch!(@preview_cache, cache_key, fn _cache_key ->
      decision = build_preview_decision(media_proxy_url, internal_media_proxy_url, static)

      if cacheable_preview_decision?(decision) do
        {:commit, decision}
      else
        {:ignore, decision}
      end
    end)
  rescue
    _ -> build_preview_decision(media_proxy_url, internal_media_proxy_url, static)
  catch
    _, _ -> build_preview_decision(media_proxy_url, internal_media_proxy_url, static)
  end

  defp build_preview_decision(media_proxy_url, internal_media_proxy_url, static) do
    with false <- MediaHelper.preview_failed?(media_proxy_url),
         {:ok, %{status: status} = head_response} when status in 200..299 <-
           Pleroma.HTTP.request(
             "HEAD",
             internal_media_proxy_url,
             [],
             [],
             preview_http_client_opts()
           ) do
      content_type = Tesla.get_header(head_response, "content-type")
      content_length = parse_content_length(Tesla.get_header(head_response, "content-length"))

      cond do
        static and content_type == "image/gif" ->
          build_jpeg_preview(internal_media_proxy_url)

        static ->
          {:redirect, :drop_static}

        content_type == "image/gif" ->
          {:redirect, :media_proxy}

        min_content_length_for_preview() > 0 and content_length > 0 and
            content_length < min_content_length_for_preview() ->
          {:redirect, :media_proxy}

        true ->
          build_preview(content_type, internal_media_proxy_url)
      end
    else
      true ->
        {:error, :cached_failure}

      {_, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_head_response}
    end
  end

  defp build_preview("image/png" <> _ = _content_type, media_proxy_url) do
    build_png_preview(media_proxy_url)
  end

  defp build_preview("image/" <> _ = _content_type, media_proxy_url) do
    build_jpeg_preview(media_proxy_url)
  end

  defp build_preview("video/" <> _ = _content_type, media_proxy_url) do
    build_video_preview(media_proxy_url)
  end

  defp build_preview(unsupported_content_type, _media_proxy_url) do
    {:error, {:unsupported_content_type, unsupported_content_type}}
  end

  defp build_png_preview(media_proxy_url) do
    quality = Config.get!([:media_preview_proxy, :image_quality])
    {thumbnail_max_width, thumbnail_max_height} = thumbnail_max_dimensions()

    with {:ok, thumbnail_binary} <-
           MediaHelper.image_resize(
             media_proxy_url,
             %{
               max_width: thumbnail_max_width,
               max_height: thumbnail_max_height,
               quality: quality,
               format: "png"
             }
           ) do
      {:body, ["image/png", "preview.png"], thumbnail_binary}
    else
      _ -> {:error, :image_resize_failed}
    end
  end

  defp build_jpeg_preview(media_proxy_url) do
    quality = Config.get!([:media_preview_proxy, :image_quality])
    {thumbnail_max_width, thumbnail_max_height} = thumbnail_max_dimensions()

    with {:ok, thumbnail_binary} <-
           MediaHelper.image_resize(
             media_proxy_url,
             %{max_width: thumbnail_max_width, max_height: thumbnail_max_height, quality: quality}
           ) do
      {:body, ["image/jpeg", "preview.jpg"], thumbnail_binary}
    else
      _ -> {:error, :image_resize_failed}
    end
  end

  defp build_video_preview(media_proxy_url) do
    with {:ok, thumbnail_binary} <-
           MediaHelper.video_framegrab(media_proxy_url) do
      {:body, ["image/jpeg", "preview.jpg"], thumbnail_binary}
    else
      _ -> {:error, :video_framegrab_failed}
    end
  end

  defp cacheable_preview_decision?({:body, _content_info, body}) when is_binary(body),
    do: byte_size(body) <= @max_cached_preview_bytes

  defp cacheable_preview_decision?({:redirect, _target}), do: true
  defp cacheable_preview_decision?(_decision), do: false

  defp render_preview_decision(
         {:body, content_info, thumbnail_binary},
         conn,
         _media_proxy_url
       ) do
    conn
    |> put_preview_response_headers(content_info)
    |> send_resp(200, thumbnail_binary)
  end

  defp render_preview_decision({:redirect, :media_proxy}, conn, media_proxy_url) do
    conn
    |> put_status(301)
    |> redirect(external: media_proxy_url)
  end

  defp render_preview_decision({:redirect, :drop_static}, conn, _media_proxy_url) do
    drop_static_param_and_redirect(conn)
  end

  defp render_preview_decision({:error, :cached_failure}, conn, media_proxy_url) do
    render_preview_decision({:redirect, :media_proxy}, conn, media_proxy_url)
  end

  defp render_preview_decision({:error, reason}, conn, media_proxy_url) do
    cache_preview_failure(conn, media_proxy_url, reason)
  end

  defp drop_static_param_and_redirect(conn) do
    uri_without_static_param =
      conn
      |> current_url()
      |> UriHelper.modify_uri_params(%{}, ["static"])

    redirect(conn, external: uri_without_static_param)
  end

  defp cache_preview_failure(conn, media_proxy_url, _reason) do
    MediaHelper.cache_preview_failure(media_proxy_url)
    render_preview_decision({:redirect, :media_proxy}, conn, media_proxy_url)
  end

  defp put_preview_response_headers(
         conn,
         [content_type, filename] = _content_info
       ) do
    conn
    |> put_resp_header("content-type", content_type)
    |> put_resp_header("content-disposition", "inline; filename=\"#{filename}\"")
    |> put_resp_header("cache-control", ReverseProxy.default_cache_control_header())
  end

  defp thumbnail_max_dimensions do
    config = media_preview_proxy_config()

    thumbnail_max_width = Keyword.fetch!(config, :thumbnail_max_width)
    thumbnail_max_height = Keyword.fetch!(config, :thumbnail_max_height)

    {thumbnail_max_width, thumbnail_max_height}
  end

  defp min_content_length_for_preview do
    Keyword.get(media_preview_proxy_config(), :min_content_length, 0)
  end

  defp preview_http_client_opts do
    Config.get([:media_proxy, :proxy_opts, :http], pool: :media)
    |> Keyword.put(:connect_timeout, preview_operation_timeout())
    |> Keyword.put(:recv_timeout, preview_operation_timeout())
  end

  defp preview_operation_timeout do
    case Keyword.get(media_preview_proxy_config(), :operation_timeout, 2_000) do
      timeout when is_integer(timeout) and timeout > 0 -> min(timeout, 10_000)
      _ -> 2_000
    end
  end

  defp parse_content_length(value) when is_binary(value) do
    case Integer.parse(value) do
      {content_length, ""} when content_length >= 0 -> content_length
      _ -> 0
    end
  end

  defp parse_content_length(_), do: 0

  defp media_preview_proxy_config do
    Config.get!([:media_preview_proxy])
  end

  defp media_proxy_opts do
    Config.get([:media_proxy, :proxy_opts], [])
    |> Keyword.update(:http, [public_only: true], &Keyword.put(&1, :public_only, true))
    |> Keyword.put_new(:image_fallback_on_failure, true)
    |> Keyword.put_new(:sniff_content_type, true)
  end

  defp sandbox(conn, _params) do
    conn
    |> merge_resp_headers([{"content-security-policy", "sandbox;"}])
  end
end
