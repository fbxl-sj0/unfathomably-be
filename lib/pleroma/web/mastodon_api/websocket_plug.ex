# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.WebsocketPlug do
  @moduledoc """
  A Phoenix 1.8 compatible WebSocket transport for Mastodon streaming.

  It mirrors Phoenix.Transports.WebSocket, but echoes a successfully authenticated
  Mastodon-style Sec-WebSocket-Protocol token so browser clients accept the handshake.
  """

  @behaviour Plug

  import Plug.Conn

  alias Phoenix.Socket.Transport
  alias Pleroma.User
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.MastodonAPI.WebsocketHandler
  alias Pleroma.Web.Streamer

  @connect_info_opts [:check_csrf]
  @eventsource_tick :timer.seconds(15)

  @impl Plug
  def init(opts) do
    path = String.split(Keyword.fetch!(opts, :path), "/", trim: true)
    websocket = Keyword.fetch!(opts, :websocket)
    config = Transport.load_config(websocket, Phoenix.Transports.WebSocket)

    {path, config}
  end

  @impl Plug
  def call(%{method: "GET", path_info: request_path} = conn, {path, opts}) do
    case stream_from_path(path, request_path) do
      :pass ->
        conn

      :health ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, "OK")
        |> halt()

      {:stream, stream} ->
        conn
        |> fetch_query_params()
        |> put_stream_param(stream)
        |> Transport.code_reload(Endpoint, opts)
        |> Transport.transport_log(opts[:transport_log])
        |> Transport.check_origin(WebsocketHandler, Endpoint, opts)
        |> connect(opts)

      :unknown ->
        conn
        |> send_resp(404, "Not Found")
        |> halt()
    end
  end

  def call(%{path_info: request_path} = conn, {path, _opts}) do
    if streaming_path?(path, request_path) do
      conn
      |> send_resp(400, "")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp stream_from_path(path, request_path) do
    if streaming_path?(path, request_path) do
      request_path
      |> Enum.drop(length(path))
      |> stream_from_path_parts()
    else
      :pass
    end
  end

  defp streaming_path?(path, request_path) do
    Enum.take(request_path, length(path)) == path
  end

  defp stream_from_path_parts([]), do: {:stream, nil}
  defp stream_from_path_parts(["health"]), do: :health
  defp stream_from_path_parts(["user"]), do: {:stream, "user"}
  defp stream_from_path_parts(["user", "notification"]), do: {:stream, "user:notification"}
  defp stream_from_path_parts(["public"]), do: {:stream, "public"}
  defp stream_from_path_parts(["public", "local"]), do: {:stream, "public:local"}
  defp stream_from_path_parts(["public", "remote"]), do: {:stream, "public:remote"}
  defp stream_from_path_parts(["hashtag"]), do: {:stream, "hashtag"}
  defp stream_from_path_parts(["hashtag", "local"]), do: {:stream, "hashtag:local"}
  defp stream_from_path_parts(["direct"]), do: {:stream, "direct"}
  defp stream_from_path_parts(["list"]), do: {:stream, "list"}
  defp stream_from_path_parts(["group", group_id]), do: {:stream, "group:" <> group_id}
  defp stream_from_path_parts(["source", source_id]), do: {:stream, "source:" <> source_id}
  defp stream_from_path_parts(_), do: :unknown

  defp put_stream_param(conn, nil), do: conn

  defp put_stream_param(%{params: params} = conn, stream) do
    %{conn | params: Map.put(params, "stream", maybe_media_stream(stream, params))}
  end

  defp maybe_media_stream("public", params) do
    if truthy_param?(params["only_media"]), do: "public:media", else: "public"
  end

  defp maybe_media_stream("public:local", params) do
    if truthy_param?(params["only_media"]), do: "public:local:media", else: "public:local"
  end

  defp maybe_media_stream("public:remote", params) do
    if truthy_param?(params["only_media"]), do: "public:remote:media", else: "public:remote"
  end

  defp maybe_media_stream(stream, _params), do: stream

  defp truthy_param?(value), do: value in [true, "true", "1", 1, "on"]

  defp connect(%{halted: true} = conn, _opts), do: conn

  defp connect(conn, opts) do
    if websocket_upgrade?(conn) do
      connect_websocket(conn, opts)
    else
      connect_eventsource(conn, opts)
    end
  end

  defp connect_websocket(conn, opts) do
    config = handler_config(conn, opts)

    case WebsocketHandler.connect(config) do
      {:ok, arg} ->
        try do
          conn
          |> echo_sec_websocket_protocol()
          |> WebSockAdapter.upgrade(WebsocketHandler, arg, opts)
          |> halt()
        rescue
          e in WebSockAdapter.UpgradeError ->
            conn
            |> send_resp(400, e.message)
            |> halt()
        end

      {:error, reason} ->
        {m, f, args} = opts[:error_handler]

        halt(apply(m, f, [conn, reason | args]))
    end
  end

  defp connect_eventsource(conn, opts) do
    case WebsocketHandler.connect(handler_config(conn, opts)) do
      {:ok, %{topics: []}} ->
        conn
        |> send_resp(404, "Not Found")
        |> halt()

      {:ok, state} ->
        stream_eventsource(conn, state)

      {:error, reason} ->
        {m, f, args} = opts[:error_handler]

        halt(apply(m, f, [conn, reason | args]))
    end
  end

  defp handler_config(%{params: params} = conn, opts) do
    keys = Keyword.get(opts, :connect_info, [])

    connect_info =
      Transport.connect_info(conn, Endpoint, keys, Keyword.take(opts, @connect_info_opts))

    %{
      endpoint: Endpoint,
      transport: :websocket,
      options: opts,
      params: params,
      connect_info: connect_info
    }
  end

  defp websocket_upgrade?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  defp stream_eventsource(conn, state) do
    Enum.each(state.topics, fn topic -> Streamer.add_socket(topic, state.oauth_token) end)

    try do
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "private, no-store")
        |> send_chunked(200)

      case chunk(conn, ":\n\n") do
        {:ok, conn} -> eventsource_loop(conn, state)
        {:error, _reason} -> conn
      end
    after
      Enum.each(state.topics, fn topic -> Streamer.remove_socket(topic) end)
    end
  end

  defp eventsource_loop(conn, state) do
    receive do
      {:render_with_user, view, template, item, topic} ->
        user = %User{} = User.get_cached_by_ap_id(state.user.ap_id)

        if Streamer.filtered_by_user?(user, item) do
          eventsource_loop(conn, %{state | user: user})
        else
          text = view.render(template, item, user, topic)
          eventsource_send(conn, text, %{state | user: user})
        end

      {:text, text} ->
        eventsource_send(conn, text, state)

      :close ->
        conn
    after
      @eventsource_tick ->
        case chunk(conn, ":thump\n\n") do
          {:ok, conn} -> eventsource_loop(conn, state)
          {:error, _reason} -> conn
        end
    end
  end

  defp eventsource_send(conn, text, state) do
    case chunk(conn, eventsource_message(text)) do
      {:ok, conn} -> eventsource_loop(conn, state)
      {:error, _reason} -> conn
    end
  end

  defp eventsource_message(text) do
    case Jason.decode(text) do
      {:ok, %{"event" => event, "payload" => payload}} ->
        "event: #{event}\ndata: #{eventsource_payload(payload)}\n\n"

      _ ->
        "event: message\ndata: #{text}\n\n"
    end
  end

  defp eventsource_payload(payload) when is_binary(payload), do: payload
  defp eventsource_payload(payload), do: Jason.encode!(payload)

  defp echo_sec_websocket_protocol(conn) do
    case get_req_header(conn, "sec-websocket-protocol") do
      [protocols | _] ->
        case Plug.Conn.Utils.list(protocols) do
          [protocol | _] -> put_resp_header(conn, "sec-websocket-protocol", protocol)
          [] -> conn
        end

      [] ->
        conn
    end
  end
end
