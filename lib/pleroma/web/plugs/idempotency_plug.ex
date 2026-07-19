# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.IdempotencyPlug do
  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  @behaviour Plug

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @lock_retry_interval 25
  @lock_wait_timeout :timer.seconds(30)

  @impl true
  def init(opts), do: opts

  # Sending idempotency keys in `GET` and `DELETE` requests has no effect
  # and should be avoided, as these requests are idempotent by definition.

  @impl true
  def call(%{method: method} = conn, _) when method in ["POST", "PUT", "PATCH"] do
    case get_req_header(conn, "idempotency-key") do
      [key] -> process_request(conn, key)
      _ -> conn
    end
  end

  def call(conn, _), do: conn

  def process_request(conn, key) do
    cache_key = scoped_cache_key(conn, key)

    case acquire_lock(cache_key) do
      {:ok, lock} ->
        process_locked_request(conn, key, cache_key, lock)

      {:error, :timeout} ->
        render_error(conn, "An identical request is still being processed", :conflict)
    end
  end

  defp process_locked_request(conn, key, cache_key, lock) do
    case @cachex.get(:idempotency_cache, cache_key) do
      {:ok, nil} ->
        cache_response(conn, key, cache_key, lock)

      {:ok, record} ->
        release_lock(lock)
        send_cached(conn, key, record)

      {atom, message} when atom in [:ignore, :error] ->
        release_lock(lock)
        render_error(conn, message)
    end
  end

  defp cache_response(conn, key, cache_key, lock) do
    register_before_send(conn, fn conn ->
      try do
        request_id = List.first(get_resp_header(conn, "x-request-id")) || ""
        content_type = get_content_type(conn)
        record = {request_id, content_type, conn.status, conn.resp_body}

        case @cachex.put(:idempotency_cache, cache_key, record) do
          {:ok, _} ->
            conn
            |> put_resp_header("idempotency-key", key)
            |> put_resp_header("x-original-request-id", request_id)

          _ ->
            conn
        end
      after
        release_lock(lock)
      end
    end)
  end

  defp send_cached(conn, key, record) do
    {request_id, content_type, status, body} = record

    conn
    |> put_resp_header("idempotency-key", key)
    |> put_resp_header("idempotent-replayed", "true")
    |> put_resp_header("x-original-request-id", request_id)
    |> put_resp_content_type(content_type)
    |> send_resp(status, body)
    |> halt()
  end

  defp render_error(conn, message, status \\ :unprocessable_entity) do
    conn
    |> put_status(status)
    |> json(%{error: message})
    |> halt()
  end

  defp get_content_type(conn) do
    content_type =
      List.first(get_resp_header(conn, "content-type")) || "application/octet-stream"

    if String.contains?(content_type, ";") do
      content_type
      |> String.split(";")
      |> hd()
    else
      content_type
    end
  end

  defp scoped_cache_key(conn, key) do
    {request_identity(conn), conn.method, conn.request_path, key}
  end

  defp request_identity(%{assigns: %{user: %{id: id}}}) when not is_nil(id), do: {:user, id}

  defp request_identity(%{assigns: %{token: %{id: id}}}) when not is_nil(id),
    do: {:token, id}

  defp request_identity(%{remote_ip: remote_ip}), do: {:anonymous, remote_ip}

  defp acquire_lock(cache_key) do
    nodes = Enum.uniq([node() | Node.list()])
    lock_id = {{__MODULE__, cache_key}, self()}
    deadline = System.monotonic_time(:millisecond) + @lock_wait_timeout

    acquire_lock(lock_id, nodes, deadline)
  end

  defp acquire_lock(lock_id, nodes, deadline) do
    if :global.set_lock(lock_id, nodes, 0) do
      {:ok, {lock_id, nodes}}
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(@lock_retry_interval)
        acquire_lock(lock_id, nodes, deadline)
      else
        {:error, :timeout}
      end
    end
  end

  defp release_lock({lock_id, nodes}) do
    :global.del_lock(lock_id, nodes)
    :ok
  end
end
