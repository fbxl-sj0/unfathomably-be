# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.RichMedia.Helpers do
  alias Pleroma.Config
  alias Pleroma.Gun.ConnectionPool
  alias Pleroma.ReverseProxy.Client.Tesla, as: TeslaClient

  require Logger

  @type get_errors :: {:error, :body_too_large | :content_type | :head | :get}

  @spec rich_media_get(String.t()) :: {:ok, String.t()} | get_errors()
  def rich_media_get(url) do
    timeout = rich_media_timeout()

    case Pleroma.HTTP.AdapterHelper.can_stream?() do
      true -> stream(url, timeout)
      false -> head_first(url, timeout)
    end
    |> handle_result(url)
  end

  defp stream(url, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case Pleroma.HTTP.get(url, req_headers(), http_options(timeout)) do
      {:ok, %Tesla.Env{status: 200, body: stream_body, headers: headers}} ->
        result =
          try do
            with {_, :ok} <- {:content_type, check_content_type(headers)},
                 {_, :ok} <- {:content_length, check_content_length(headers)},
                 {:read_stream, {:ok, body}} <-
                   {:read_stream,
                    read_stream(stream_body, deadline, expected_content_length(headers))} do
              {:ok, body}
            end
          rescue
            exception ->
              cleanup_stream(stream_body, :error)
              reraise exception, __STACKTRACE__
          end

        cleanup_stream(stream_body, result)
        result

      {:ok, %Tesla.Env{body: stream_body}} = response ->
        cleanup_stream(stream_body, :rejected)
        {:get, response}

      response ->
        {:get, response}
    end
  end

  defp head_first(url, timeout) do
    with {_, {:ok, %Tesla.Env{status: 200, headers: headers}}} <-
           {:head, Pleroma.HTTP.head(url, req_headers(), http_options(timeout))},
         {_, :ok} <- {:content_type, check_content_type(headers)},
         {_, :ok} <- {:content_length, check_content_length(headers)},
         {_, {:ok, %Tesla.Env{status: 200, body: body}}} <-
           {:get, Pleroma.HTTP.get(url, req_headers(), http_options(timeout))} do
      {:ok, body}
    end
  end

  defp handle_result(result, url) do
    safe_url = Pleroma.Helpers.UriHelper.log_safe_url(url)

    case result do
      {:ok, body} ->
        {:ok, body}

      {:head, _} ->
        Logger.debug("Rich media error for #{safe_url}: HTTP HEAD failed")
        {:error, :head}

      {:content_type, {_, type}} ->
        Logger.debug("Rich media error for #{safe_url}: content-type is #{type}")
        {:error, :content_type}

      {:content_length, :error} ->
        Logger.debug("Rich media error for #{safe_url}: content-length exceeded")
        {:error, :body_too_large}

      {:read_stream, {:error, :body_too_large}} ->
        Logger.debug("Rich media error for #{safe_url}: content-length exceeded")
        {:error, :body_too_large}

      {:read_stream, {:error, :timeout}} ->
        Logger.debug("Rich media error for #{safe_url}: HTTP stream timed out")
        {:error, :get}

      {:read_stream, {:error, :incomplete}} ->
        Logger.debug("Rich media error for #{safe_url}: HTTP stream ended before content-length")
        {:error, :get}

      {:get, _} ->
        Logger.debug("Rich media error for #{safe_url}: HTTP GET failed")
        {:error, :get}
    end
  end

  defp check_content_type(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, content_type} ->
        case Pleroma.Web.MediaType.match(content_type, [{"text", "html"}]) do
          {"text", "html", _params} -> :ok
          nil -> {:error, content_type}
        end

      _ ->
        :ok
    end
  end

  defp check_content_length(headers) do
    max_body = max_body()

    case expected_content_length(headers) do
      content_length when is_integer(content_length) and content_length > max_body -> :error
      _ -> :ok
    end
  end

  defp expected_content_length(headers) do
    case List.keyfind(headers, "content-length", 0) do
      {_, maybe_content_length} ->
        case Integer.parse(maybe_content_length) do
          {content_length, ""} when content_length >= 0 -> content_length
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_stream(%{pid: pid, stream: stream, opts: opts}, deadline, expected_content_length) do
    read_chunks(pid, stream, opts, <<>>, 0, deadline, expected_content_length)
  end

  defp read_stream(stream, deadline, expected_content_length) do
    max_body = max_body()

    try do
      result =
        Stream.transform(stream, 0, fn chunk, total_bytes ->
          new_total = total_bytes + byte_size(chunk)

          cond do
            System.monotonic_time(:millisecond) >= deadline ->
              throw(:rich_media_timeout)

            new_total > max_body ->
              throw(:rich_media_body_too_large)

            true ->
              {[chunk], new_total}
          end
        end)
        |> Enum.into(<<>>)

      cond do
        System.monotonic_time(:millisecond) >= deadline ->
          {:error, :timeout}

        is_integer(expected_content_length) and
            byte_size(result) != expected_content_length ->
          {:error, :incomplete}

        true ->
          {:ok, result}
      end
    rescue
      _ -> {:error, :body_too_large}
    catch
      :throw, :rich_media_timeout -> {:error, :timeout}
      :throw, :rich_media_body_too_large -> {:error, :body_too_large}
    end
  end

  defp read_chunks(pid, stream, opts, acc, total_bytes, deadline, expected_content_length) do
    case Tesla.Adapter.Gun.read_chunk(pid, stream, opts) do
      {fin, chunk} when fin in [:fin, :nofin] ->
        total_bytes = total_bytes + byte_size(chunk)

        cond do
          System.monotonic_time(:millisecond) >= deadline ->
            {:error, :timeout}

          total_bytes > max_body() ->
            {:error, :body_too_large}

          fin == :fin and is_integer(expected_content_length) and
              total_bytes != expected_content_length ->
            {:error, :incomplete}

          fin == :fin ->
            {:ok, acc <> chunk}

          true ->
            read_chunks(
              pid,
              stream,
              opts,
              acc <> chunk,
              total_bytes,
              deadline,
              expected_content_length
            )
        end

      {:error, _reason} ->
        {:error, :incomplete}
    end
  end

  defp cleanup_stream(%{pid: pid, stream: stream}, {:ok, _body}),
    do: ConnectionPool.release_stream(pid, stream)

  defp cleanup_stream(%{pid: _pid} = client, _result), do: TeslaClient.close(client)
  defp cleanup_stream(_stream, _result), do: :ok

  defp http_options(timeout) do
    base_options = [
      pool: :rich_media,
      public_only: true,
      max_body: max_body(),
      recv_timeout: timeout
    ]

    if Pleroma.HTTP.AdapterHelper.can_stream?() do
      base_options
      |> Keyword.put(:stream, true)
      |> Keyword.put(:request_timeout, timeout)
    else
      Keyword.put(base_options, :tesla_middleware, [
        {Tesla.Middleware.Timeout, timeout: timeout}
      ])
    end
  end

  defp max_body, do: Config.get([:rich_media, :max_body], 5_000_000)

  defp rich_media_timeout, do: Config.get([:rich_media, :timeout], 5_000)

  defp req_headers do
    user_agent = Config.get([:rich_media, :user_agent], :default)

    case user_agent do
      :default -> [{"user-agent", Pleroma.Application.user_agent() <> "; Bot"}]
      custom -> [{"user-agent", custom}]
    end
  end
end
