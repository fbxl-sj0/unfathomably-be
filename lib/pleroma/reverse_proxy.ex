# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReverseProxy do
  @range_headers ~w(range if-range)
  @keep_req_headers ~w(accept accept-encoding cache-control if-modified-since) ++
                      ~w(if-unmodified-since if-none-match) ++ @range_headers
  @resp_cache_headers ~w(etag date last-modified)
  @keep_resp_headers @resp_cache_headers ++
                       ~w(content-length content-type content-disposition content-encoding) ++
                       ~w(content-range accept-ranges vary)
  @default_cache_control_header "public, max-age=1209600, immutable, no-transform"
  @valid_resp_codes [200, 206, 304]
  @max_read_duration :timer.seconds(30)
  @max_body_length :infinity
  @failed_request_ttl :timer.seconds(60)
  @sniff_bytes 8 * 1024
  @origin_concurrency_default 2
  @origin_concurrency_max 8
  @origin_retry_after_default 60
  @origin_retry_after_max 900
  @methods ~w(GET HEAD)
  @quiet_http_response_codes [403, 404, 410]
  @image_fallback_extensions ~w(.apng .avif .gif .heic .heif .ico .jpeg .jpg .png .svg .webp)
  @failed_image_placeholder """
  <svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">
    <g fill="none" stroke-linecap="round" stroke-linejoin="round">
      <path d="M27 83V37a10 10 0 0 1 10-10h46a10 10 0 0 1 10 10v46a10 10 0 0 1-10 10H37a10 10 0 0 1-10-10Z"
            stroke="#000" stroke-opacity=".7" stroke-width="8"/>
      <path d="m31 78 17-20 15 16 9-10 17 16M43 48h.1"
            stroke="#000" stroke-opacity=".7" stroke-width="8"/>
      <path d="M27 83V37a10 10 0 0 1 10-10h46a10 10 0 0 1 10 10v46a10 10 0 0 1-10 10H37a10 10 0 0 1-10-10Z"
            stroke="#fff" stroke-opacity=".85" stroke-width="3"/>
      <path d="m31 78 17-20 15 16 9-10 17 16M43 48h.1"
            stroke="#fff" stroke-opacity=".85" stroke-width="3"/>
    </g>
  </svg>
  """
  @transient_request_errors [
    :closed,
    :connect_timeout,
    :timeout,
    :econnrefused,
    :enotconn,
    :invalid_state,
    :nxdomain,
    :recv_body_timeout,
    :recv_chunk_timeout,
    :recv_response_timeout
  ]
  # Rejecting an oversized upstream body is an intentional safety decision.
  # Media proxy callers can turn this result into a local image placeholder.
  @quiet_request_errors [:body_too_large]
  @timeout_request_errors [
    :connect_timeout,
    :recv_body_timeout,
    :recv_chunk_timeout,
    :recv_response_timeout,
    :timeout
  ]

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)

  defmodule StreamError do
    @moduledoc false
    defexception [:url, :reason]

    @impl true
    def message(%{url: url, reason: reason}) do
      "reverse proxy stream from #{url} failed: #{inspect(reason)}"
    end
  end

  def max_read_duration_default, do: @max_read_duration
  def default_cache_control_header, do: @default_cache_control_header

  @moduledoc """
  A reverse proxy.

      Pleroma.ReverseProxy.call(conn, url, options)

  It is not meant to be added into a plug pipeline, but to be called from another plug or controller.

  Supports `#{inspect(@methods)}` HTTP methods, and only allows `#{inspect(@valid_resp_codes)}` status codes.

  Responses are chunked to the client while downloading from the upstream.

  Some request / responses headers are preserved:

  * request: `#{inspect(@keep_req_headers)}`
  * response: `#{inspect(@keep_resp_headers)}`

  Options:

  * `redirect_on_failure` (default `false`). Redirects the client to the real remote URL if there's any HTTP
  errors. Any error during body processing will not be redirected as the response is chunked. This may expose
  remote URL, clients IPs, ….

  * `image_fallback_on_failure` (default `false`). Returns a short-lived local SVG placeholder for failed image
  requests. This is useful for media proxy callers that should not redirect browsers to dead remote media.

  * `sniff_content_type` (default `false`). Detects an image MIME type from the first response chunk when the
  upstream type is missing or `application/octet-stream`.

  * `max_body_length` (default `#{inspect(@max_body_length)}`): limits the content length to be approximately the
  specified length. It is validated with the `content-length` header and also verified when proxying.

  * `max_read_duration` (default `#{inspect(@max_read_duration)}` ms): the total time the connection is allowed to
  read from the remote upstream.

  * `failed_request_ttl` (default `#{inspect(@failed_request_ttl)}` ms): the time the failed request is cached and cannot be retried.

  * `inline_content_types`:
    * `true` will not alter `content-disposition` (up to the upstream),
    * `false` will add `content-disposition: attachment` to any request,
    * a list of whitelisted content types

  * `req_headers`, `resp_headers` additional headers.

  * `http`: options for [hackney](https://github.com/benoitc/hackney) or [gun](https://github.com/ninenines/gun).

  """
  @default_options [pool: :media]

  @inline_content_types [
    "image/apng",
    "image/avif",
    "image/bmp",
    "image/gif",
    "image/jpeg",
    "image/jpg",
    "image/png",
    "image/svg+xml",
    "image/webp",
    "audio/mpeg",
    "audio/mp3",
    "video/webm",
    "video/mp4",
    "video/quicktime"
  ]

  require Logger
  import Plug.Conn

  @type option() ::
          {:max_read_duration, non_neg_integer() | :infinity}
          | {:max_body_length, non_neg_integer() | :infinity}
          | {:failed_request_ttl, non_neg_integer() | :infinity}
          | {:http, []}
          | {:req_headers, [{String.t(), String.t()}]}
          | {:resp_headers, [{String.t(), String.t()}]}
          | {:inline_content_types, boolean() | [String.t()]}
          | {:redirect_on_failure, boolean()}
          | {:image_fallback_on_failure, boolean()}
          | {:sniff_content_type, boolean()}

  @spec media_call(Plug.Conn.t(), url :: String.t(), [option()]) :: Plug.Conn.t()
  def media_call(conn, url, opts \\ []) do
    case origin_cooldown(url) do
      {:throttled, retry_after} ->
        origin_throttled_response(conn, url, retry_after, opts)

      :ok ->
        result =
          :global.trans(origin_lock(url), fn ->
            case origin_cooldown(url) do
              {:throttled, retry_after} ->
                origin_throttled_response(conn, url, retry_after, opts)

              :ok ->
                call(conn, url, opts)
            end
          end)

        case result do
          {:aborted, reason} ->
            Logger.warning("Remote media origin limiter aborted: #{inspect(reason)}")

            conn
            |> put_resp_header("retry-after", "1")
            |> error_or_redirect(url, 503, "Remote media origin is busy", opts)

          response ->
            response
        end
    end
  end

  @spec call(Plug.Conn.t(), url :: String.t(), [option()]) :: Plug.Conn.t()
  def call(_conn, _url, _opts \\ [])

  def call(conn = %{method: method}, url, opts) when method in @methods do
    client_opts = Keyword.merge(@default_options, Keyword.get(opts, :http, []))

    req_headers = build_req_headers(conn.req_headers, opts)

    opts =
      if filename = Pleroma.Web.MediaProxy.filename(url) do
        Keyword.put_new(opts, :attachment_name, filename)
      else
        opts
      end

    with {:ok, nil} <- @cachex.get(:failed_proxy_url_cache, url),
         {:ok, code, headers, client} <-
           request_with_constraints(method, url, req_headers, client_opts, opts) do
      response(conn, client, url, code, headers, opts)
    else
      {:ok, %{status: status, body: body}}
      when is_integer(status) and is_binary(body) ->
        conn
        |> error_or_redirect(url, status, body, opts)
        |> halt()

      # Entries created before response-aware failure caching did not retain
      # the upstream failure class. Treat them as gateway failures rather than
      # reporting an internal application error to the browser.
      {:ok, true} ->
        conn
        |> error_or_redirect(url, 502, "Upstream request failed", opts)
        |> halt()

      {:ok, code, headers} ->
        head_response(conn, url, code, headers, opts)
        |> halt()

      {:error, {:invalid_http_response, code, headers}} ->
        invalid_http_response(conn, url, code, headers, opts)

      {:error, {:invalid_http_response, code}} ->
        invalid_http_response(conn, url, code, [], opts)

      {:error, error} ->
        log_request_error(url, error)

        {response_code, response_body} = request_error_response(error)
        track_failed_url(url, error, {response_code, response_body}, opts)

        conn
        |> error_or_redirect(url, response_code, response_body, opts)
        |> halt()
    end
  end

  def call(conn, _, _) do
    conn
    |> send_resp(400, Plug.Conn.Status.reason_phrase(400))
    |> halt()
  end

  defp request(method, url, headers, opts) do
    Logger.debug("#{__MODULE__} #{method} #{url} #{inspect(headers)}")
    method = method |> String.downcase() |> String.to_existing_atom()

    case client().request(method, url, headers, "", opts) do
      {:ok, code, headers, client} when code in @valid_resp_codes ->
        {:ok, code, downcase_headers(headers), client}

      {:ok, code, headers} when code in @valid_resp_codes ->
        {:ok, code, downcase_headers(headers)}

      {:ok, code, headers, client} ->
        client().close(client)
        {:error, {:invalid_http_response, code, downcase_headers(headers)}}

      {:ok, code, headers} ->
        {:error, {:invalid_http_response, code, downcase_headers(headers)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp request_with_constraints(method, url, headers, client_opts, opts) do
    method
    |> request(url, headers, client_opts)
    |> constrain_response(Keyword.get(opts, :max_body_length, @max_body_length))
  end

  defp constrain_response({:ok, code, headers, client}, limit) do
    case header_length_constraint(headers, limit) do
      {:ok, headers} ->
        {:ok, code, headers, client}

      error ->
        client().close(client)
        error
    end
  end

  defp constrain_response({:ok, code, headers}, limit) do
    case header_length_constraint(headers, limit) do
      {:ok, headers} -> {:ok, code, headers}
      error -> error
    end
  end

  defp constrain_response(response, _limit), do: response

  defp response(conn, client, url, status, headers, opts) do
    Logger.debug("#{__MODULE__} #{status} #{url} #{inspect(headers)}")

    case maybe_prefetch_for_content_type(headers, client, opts) do
      {_headers, client, {:error, {:upstream, error}}} ->
        Logger.warning(
          "#{__MODULE__} request to #{url} failed before streaming: #{inspect(error)}"
        )

        client().close(client)
        {response_code, response_body} = request_error_response(error)
        track_failed_url(url, error, {response_code, response_body}, opts)

        conn
        |> error_or_redirect(url, response_code, response_body, opts)
        |> halt()

      {headers, client, prefetched} ->
        stream_response(conn, client, url, status, headers, opts, prefetched)
    end
  end

  defp stream_response(conn, client, url, status, headers, opts, prefetched) do
    result =
      conn
      |> put_resp_headers(build_resp_headers(headers, opts))
      |> streaming_compat()
      |> send_chunked(status)
      |> chunk_reply(client, opts, prefetched)

    case result do
      {:ok, conn} ->
        halt(conn)

      {:error, {:downstream, _error}, conn} ->
        client().close(client)
        halt(conn)

      {:error, {:upstream, error}, conn} ->
        Logger.warning(
          "#{__MODULE__} request to #{url} failed while reading/chunking: #{inspect(error)}"
        )

        {response_code, response_body} = request_error_response(error)
        track_failed_url(url, error, {response_code, response_body}, opts)

        client().close(client)
        raise_stream_error(conn, url, error)
    end
  end

  defp chunk_reply(conn, client, opts, :none) do
    chunk_reply(conn, client, opts, 0, 0)
  end

  defp chunk_reply(conn, _client, _opts, :done), do: {:ok, conn}
  defp chunk_reply(conn, _client, _opts, {:error, error}), do: {:error, error, conn}

  defp chunk_reply(conn, client, opts, {:ok, data, duration}) do
    with :ok <-
           body_size_constraint(
             byte_size(data),
             Keyword.get(opts, :max_body_length, @max_body_length)
           ),
         {:ok, conn} <- write_chunk(conn, data) do
      chunk_reply(conn, client, opts, byte_size(data), duration)
    else
      {:error, {:downstream, error}} -> {:error, {:downstream, error}, conn}
      {:error, error} -> {:error, {:upstream, error}, conn}
    end
  end

  defp chunk_reply(conn, client, opts, sent_so_far, duration) do
    with {:ok, data, client, duration} <- read_chunk(client, duration, opts),
         sent_so_far = sent_so_far + byte_size(data),
         :ok <-
           body_size_constraint(
             sent_so_far,
             Keyword.get(opts, :max_body_length, @max_body_length)
           ),
         {:ok, conn} <- write_chunk(conn, data) do
      chunk_reply(conn, client, opts, sent_so_far, duration)
    else
      :done -> {:ok, conn}
      {:error, {source, error}} -> {:error, {source, error}, conn}
      {:error, error} -> {:error, {:upstream, error}, conn}
    end
  end

  defp read_chunk(client, duration, opts) do
    result =
      with {:ok, timer} <-
             check_read_duration(
               duration,
               Keyword.get(opts, :max_read_duration, @max_read_duration)
             ),
           {:ok, data, client} <- client().stream_body(client),
           {:ok, duration} <- increase_read_duration(timer) do
        {:ok, data, client, duration}
      end

    case result do
      {:error, error} -> {:error, {:upstream, error}}
      result -> result
    end
  end

  defp write_chunk(conn, data) do
    case chunk(conn, data) do
      {:error, error} -> {:error, {:downstream, error}}
      result -> result
    end
  end

  defp maybe_prefetch_for_content_type(headers, client, opts) do
    if Keyword.get(opts, :sniff_content_type, false) and generic_content_type?(headers) do
      case read_chunk(client, 0, opts) do
        {:ok, data, client, duration} ->
          {maybe_put_image_content_type(headers, data), client, {:ok, data, duration}}

        :done ->
          {headers, client, :done}

        {:error, error} ->
          {headers, client, {:error, error}}
      end
    else
      {headers, client, :none}
    end
  end

  defp generic_content_type?(headers) do
    headers
    |> get_content_type()
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["", "application/octet-stream"]))
  end

  defp maybe_put_image_content_type(headers, data) do
    with false <- data == "",
         {:ok, %{mime_type: "image/" <> _ = content_type}} <-
           Majic.perform({:bytes, binary_part(data, 0, min(byte_size(data), @sniff_bytes))},
             pool: Pleroma.MajicPool
           ) do
      [
        {"content-type", content_type}
        | Enum.reject(headers, fn {key, _} -> key == "content-type" end)
      ]
    else
      _ -> headers
    end
  rescue
    error ->
      Logger.debug("#{__MODULE__}: content-type sniffing failed: #{Exception.message(error)}")
      headers
  catch
    kind, reason ->
      Logger.debug("#{__MODULE__}: content-type sniffing failed: #{kind}: #{inspect(reason)}")
      headers
  end

  defp head_response(conn, url, code, headers, opts) do
    Logger.debug("#{__MODULE__} #{code} #{url} #{inspect(headers)}")

    conn
    |> put_resp_headers(build_resp_headers(headers, opts))
    |> send_resp(code, "")
  end

  defp error_or_redirect(conn, url, code, body, opts) do
    cond do
      Keyword.get(opts, :redirect_on_failure, false) ->
        conn
        |> Phoenix.Controller.redirect(external: url)
        |> halt()

      Keyword.get(opts, :image_fallback_on_failure, false) and image_request?(conn, url, opts) ->
        failed_image_placeholder(conn)

      true ->
        conn
        |> send_resp(code, body)
        |> halt()
    end
  end

  defp image_request?(conn, url, opts) do
    image_filename? =
      [
        Keyword.get(opts, :attachment_name),
        Pleroma.Web.MediaProxy.filename(url),
        image_query_filename(url)
      ]
      |> Enum.any?(&image_filename?/1)

    image_filename? or accepts_image?(conn)
  end

  defp accepts_image?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(fn accepted_type ->
      accepted_type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.starts_with?("image/")
    end)
  end

  defp image_filename?(filename) when is_binary(filename) do
    filename
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in @image_fallback_extensions))
  end

  defp image_filename?(_filename), do: false

  # Some media hosts expose only an opaque path and put the user-facing name in
  # the query string. The signed proxy route can also carry an opaque attachment
  # name, so inspect both sources before deciding whether an error may safely be
  # replaced with the local image placeholder.
  defp image_query_filename(url) when is_binary(url) do
    with query when is_binary(query) <- URI.parse(url).query,
         params when is_map(params) <- URI.decode_query(query) do
      Enum.find_value(~w(name filename file), &Map.get(params, &1))
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
    URI.Error -> nil
  end

  defp image_query_filename(_url), do: nil

  @doc false
  @spec failed_image_placeholder(Plug.Conn.t()) :: Plug.Conn.t()
  def failed_image_placeholder(conn) do
    conn
    |> put_resp_header("content-type", "image/svg+xml")
    |> put_resp_header("content-disposition", "inline; filename=\"remote-media-unavailable.svg\"")
    |> put_resp_header("cache-control", "public, max-age=60")
    |> send_resp(200, @failed_image_placeholder)
    |> halt()
  end

  defp downcase_headers(headers) do
    Enum.map(headers, fn {k, v} ->
      {String.downcase(k), v}
    end)
  end

  defp get_content_type(headers) do
    {_, content_type} =
      List.keyfind(headers, "content-type", 0, {"content-type", "application/octet-stream"})

    [content_type | _] = String.split(content_type, ";")
    content_type
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, conn ->
      put_resp_header(conn, k, v)
    end)
  end

  defp build_req_headers(headers, opts) do
    headers
    |> downcase_headers()
    |> Enum.filter(fn {k, _} -> k in @keep_req_headers end)
    |> build_req_range_or_encoding_header(opts)
    |> build_req_user_agent_header(opts)
    |> merge_headers(Keyword.get(opts, :req_headers, []))
    |> maybe_force_identity_encoding(opts)
  end

  defp merge_headers(headers, extra_headers) do
    Enum.reduce(extra_headers, headers, fn {key, value}, headers ->
      replace_header(headers, String.downcase(key), value)
    end)
  end

  defp maybe_force_identity_encoding(headers, opts) do
    if Keyword.get(opts, :sniff_content_type, false) do
      replace_header(headers, "accept-encoding", "identity")
    else
      headers
    end
  end

  # Disable content-encoding if any @range_headers are requested (see #1823).
  defp build_req_range_or_encoding_header(headers, _opts) do
    range? = Enum.any?(headers, fn {header, _} -> Enum.member?(@range_headers, header) end)

    if range? && List.keymember?(headers, "accept-encoding", 0) do
      List.keydelete(headers, "accept-encoding", 0)
    else
      headers
    end
  end

  defp build_req_user_agent_header(headers, _opts) do
    List.keystore(
      headers,
      "user-agent",
      0,
      {"user-agent", Pleroma.Application.user_agent()}
    )
  end

  defp build_resp_headers(headers, opts) do
    headers
    |> Enum.filter(fn {k, _} -> k in @keep_resp_headers end)
    |> build_resp_cache_headers(opts)
    |> build_resp_content_disposition_header(opts)
    |> merge_headers(Keyword.get(opts, :resp_headers, []))
    |> ensure_no_transform()
  end

  defp ensure_no_transform(headers) do
    {_, cache_control} =
      List.keyfind(headers, "cache-control", 0, {"cache-control", @default_cache_control_header})

    directives =
      cache_control
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    if "no-transform" in directives do
      headers
    else
      replace_header(headers, "cache-control", cache_control <> ", no-transform")
    end
  end

  defp build_resp_cache_headers(headers, _opts) do
    has_cache? = Enum.any?(headers, fn {k, _} -> k in @resp_cache_headers end)

    cond do
      has_cache? ->
        # There's caching header present but no cache-control -- we need to set our own
        # as Plug defaults to "max-age=0, private, must-revalidate"
        List.keystore(
          headers,
          "cache-control",
          0,
          {"cache-control", @default_cache_control_header}
        )

      true ->
        List.keystore(
          headers,
          "cache-control",
          0,
          {"cache-control", @default_cache_control_header}
        )
    end
  end

  defp build_resp_content_disposition_header(headers, opts) do
    opt = Keyword.get(opts, :inline_content_types, @inline_content_types)

    content_type = get_content_type(headers)

    attachment? =
      cond do
        is_list(opt) && !Enum.member?(opt, content_type) -> true
        opt == false -> true
        true -> false
      end

    if attachment? do
      name =
        content_disposition_filename(headers) || Keyword.get(opts, :attachment_name) ||
          "attachment"

      name = escape_content_disposition_filename(name)

      disposition = "attachment; filename=\"#{name}\""

      List.keystore(headers, "content-disposition", 0, {"content-disposition", disposition})
    else
      headers
    end
  end

  defp content_disposition_filename(headers) do
    with {_, content_disposition} <- List.keyfind(headers, "content-disposition", 0) do
      parse_content_disposition_filename(content_disposition)
    else
      _ -> nil
    end
  end

  defp parse_content_disposition_filename(content_disposition)
       when is_binary(content_disposition) do
    cond do
      match =
          Regex.run(~r/filename\*=UTF-8''([^;]+)/iu, content_disposition, capture: :all_but_first) ->
        [filename] = match
        URI.decode(filename)

      match =
          Regex.run(~r/filename="((?:[^"\\]|\\.)*)"/u, content_disposition,
            capture: :all_but_first
          ) ->
        [filename] = match
        Regex.replace(~r/\\(.)/u, filename, "\\1")

      match = Regex.run(~r/filename=([^;]+)/u, content_disposition, capture: :all_but_first) ->
        [filename] = match
        String.trim(filename)

      true ->
        nil
    end
  end

  defp parse_content_disposition_filename(_), do: nil

  defp escape_content_disposition_filename(filename) do
    filename
    |> to_string()
    |> String.replace(~r/[\x00-\x1F\x7F]/u, "_")
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp replace_header(headers, key, value) do
    [{key, value} | Enum.reject(headers, fn {header, _} -> header == key end)]
  end

  defp header_length_constraint(headers, limit) do
    lengths =
      for {"content-length", value} <- headers,
          do: parse_content_length(value)

    case Enum.uniq(lengths) do
      [] ->
        {:ok, headers}

      [size] when is_integer(size) ->
        case body_size_constraint(size, limit) do
          :ok -> {:ok, replace_header(headers, "content-length", to_string(size))}
          error -> error
        end

      _ ->
        {:error, :invalid_content_length}
    end
  end

  defp parse_content_length(value) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size >= 0 -> size
      _ -> :invalid
    end
  end

  defp parse_content_length(_value), do: :invalid

  defp body_size_constraint(size, limit) when is_integer(limit) and limit > 0 and size > limit do
    {:error, :body_too_large}
  end

  defp body_size_constraint(_, _), do: :ok

  defp check_read_duration(nil = _duration, max), do: check_read_duration(@max_read_duration, max)

  defp check_read_duration(duration, max)
       when is_integer(duration) and is_integer(max) and max > 0 do
    if duration > max do
      {:error, :read_duration_exceeded}
    else
      {:ok, {duration, :erlang.system_time(:millisecond)}}
    end
  end

  defp check_read_duration(_, _), do: {:ok, :no_duration_limit}

  defp increase_read_duration(:no_duration_limit), do: {:ok, :no_duration_limit}

  defp increase_read_duration({previous_duration, started})
       when is_integer(previous_duration) and is_integer(started) do
    duration = :erlang.system_time(:millisecond) - started
    {:ok, previous_duration + duration}
  end

  defp increase_read_duration(_), do: {:ok, :no_duration_limit}

  defp client, do: Pleroma.ReverseProxy.Client.Wrapper

  # Plug does not expose a portable way to abort a committed response. Ensure
  # an upstream truncation remains visibly incomplete instead of finalizing a
  # partial media body as a successful download.
  defp raise_stream_error(
         %Plug.Conn{adapter: {Plug.Cowboy.Conn, %{pid: connection_pid}}} = conn,
         url,
         error
       ) do
    if Plug.Conn.get_http_protocol(conn) in [:"HTTP/1.0", :"HTTP/1.1"] do
      Process.exit(connection_pid, :kill)
    end

    raise StreamError, url: url, reason: error
  end

  defp raise_stream_error(_conn, url, error) do
    raise StreamError, url: url, reason: error
  end

  defp log_http_response_error(url, code) when code in @quiet_http_response_codes do
    Logger.debug("#{__MODULE__}: request to #{inspect(url)} failed with HTTP status #{code}")
  end

  defp log_http_response_error(url, code) do
    Logger.warning("#{__MODULE__}: request to #{inspect(url)} failed with HTTP status #{code}")
  end

  defp log_request_error(url, error)
       when error in @transient_request_errors or error in @quiet_request_errors do
    Logger.debug("#{__MODULE__}: request to #{inspect(url)} failed: #{inspect(error)}")
  end

  defp log_request_error(
         url,
         {Tesla.Middleware.FollowRedirects, :too_many_redirects} = error
       ) do
    Logger.warning("#{__MODULE__}: request to #{inspect(url)} failed: #{inspect(error)}")
  end

  defp log_request_error(url, error) do
    Logger.error("#{__MODULE__}: request to #{inspect(url)} failed: #{inspect(error)}")
  end

  defp error_response_status(code) when is_integer(code) do
    {code, Plug.Conn.Status.reason_phrase(code)}
  rescue
    ArgumentError -> {502, Plug.Conn.Status.reason_phrase(502)}
  end

  defp error_response_status(_code), do: {502, Plug.Conn.Status.reason_phrase(502)}

  defp request_error_response(error) when error in @timeout_request_errors do
    {504, "Upstream request timed out"}
  end

  defp request_error_response(_error), do: {502, "Upstream request failed"}

  defp invalid_http_response(conn, url, code, headers, opts) do
    log_http_response_error(url, code)
    track_origin_throttle(url, code, headers, opts)

    {response_code, reason_phrase} = error_response_status(code)
    response_body = "Request failed: " <> reason_phrase
    track_failed_url(url, code, {response_code, response_body}, opts)

    conn
    |> error_or_redirect(url, response_code, response_body, opts)
    |> halt()
  end

  defp track_failed_url(url, error, {response_code, response_body}, opts) do
    ttl =
      unless error in [:body_too_large, 400, 204] do
        Keyword.get(opts, :failed_request_ttl, @failed_request_ttl)
      else
        nil
      end

    cached_response = %{status: response_code, body: response_body}
    @cachex.put(:failed_proxy_url_cache, url, cached_response, expire: ttl)
  end

  defp origin_lock(url) do
    origin = origin_key(url)
    slot = :erlang.phash2(url, origin_concurrency())
    {{__MODULE__, :media_origin, origin, slot}, self()}
  end

  defp origin_concurrency do
    case Pleroma.Config.get([__MODULE__, :origin_concurrency], @origin_concurrency_default) do
      value when is_integer(value) and value > 0 ->
        min(value, @origin_concurrency_max)

      _ ->
        @origin_concurrency_default
    end
  end

  defp origin_key(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) ->
        {String.downcase(scheme), String.downcase(host), port || URI.default_port(scheme)}

      _ ->
        {:url, url}
    end
  end

  defp origin_cooldown_key(url), do: {:media_origin_throttle, origin_key(url)}

  defp origin_cooldown(url) do
    case @cachex.get(:failed_proxy_url_cache, origin_cooldown_key(url)) do
      {:ok, %{retry_at: retry_at}} when is_integer(retry_at) ->
        now = System.system_time(:second)

        if retry_at > now do
          {:throttled, retry_at - now}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp origin_throttled_response(conn, url, retry_after, opts) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(max(retry_after, 1)))
    |> error_or_redirect(url, 429, "Remote media origin is rate limited", opts)
  end

  defp track_origin_throttle(url, 429, headers, opts) do
    retry_after = retry_after_seconds(headers, opts)
    retry_at = System.system_time(:second) + retry_after

    @cachex.put(
      :failed_proxy_url_cache,
      origin_cooldown_key(url),
      %{retry_at: retry_at},
      expire: :timer.seconds(retry_after)
    )

    Logger.debug(
      "Pausing remote media origin #{inspect(origin_key(url))} for #{retry_after} seconds after HTTP 429"
    )
  end

  defp track_origin_throttle(_url, _code, _headers, _opts), do: :ok

  defp retry_after_seconds(headers, opts) do
    default =
      Keyword.get(
        opts,
        :origin_retry_after,
        Pleroma.Config.get([__MODULE__, :origin_retry_after], @origin_retry_after_default)
      )

    default =
      if is_integer(default) and default > 0,
        do: default,
        else: @origin_retry_after_default

    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "retry-after", do: to_string(value)
    end)
    |> parse_retry_after(default)
    |> max(1)
    |> min(@origin_retry_after_max)
  end

  defp parse_retry_after(nil, default), do: default

  defp parse_retry_after(value, default) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds > 0 ->
        seconds

      _ ->
        retry_after_date(value, default)
    end
  end

  defp retry_after_date(value, default) do
    try do
      case :httpd_util.convert_request_date(String.to_charlist(value)) do
        {{_, _, _}, {_, _, _}} = datetime ->
          with {:ok, naive} <- NaiveDateTime.from_erl(datetime),
               {:ok, retry_at} <- DateTime.from_naive(naive, "Etc/UTC") do
            max(DateTime.diff(retry_at, DateTime.utc_now(), :second), 1)
          else
            _ -> default
          end

        _ ->
          default
      end
    catch
      _, _ -> default
    end
  end

  # Cowboy streams HTTP/1.1 responses when content-length is present on a
  # chunked response. Bandit cannot do that, so keep the header only for Cowboy
  # and strip it for other adapters to avoid invalid chunked framing.
  defp streaming_compat(conn) do
    with Phoenix.Endpoint.Cowboy2Adapter <- Pleroma.Web.Endpoint.config(:adapter) do
      conn
    else
      _ -> delete_resp_header(conn, "content-length")
    end
  end
end
