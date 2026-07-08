# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReverseProxy.Client.Hackney do
  @behaviour Pleroma.ReverseProxy.Client

  require Logger

  @redirect_statuses [301, 302, 303, 307, 308]
  @max_redirects 6

  @impl true
  def request(method, url, headers, body, opts \\ []) do
    if Keyword.get(opts, :follow_redirect, false) do
      request_follow_redirect(method, url, headers, body, opts, @max_redirects)
    else
      :hackney.request(method, url, headers, body, opts)
    end
  end

  @impl true
  def stream_body(:done), do: :done

  def stream_body(body) when is_binary(body), do: {:ok, body, :done}

  def stream_body(ref) do
    case :hackney.stream_body(ref) do
      :done -> :done
      {:ok, data} -> {:ok, data, ref}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def close(ref), do: :hackney.close(ref)

  defp request_follow_redirect(method, url, headers, body, opts, redirects_left) do
    opts =
      opts
      |> Keyword.put(:follow_redirect, false)
      |> Keyword.put_new(:path_encode_fun, &URI.encode/1)

    case :hackney.request(method, url, headers, body, opts) do
      {:ok, status, response_headers, _ref} = response
      when status in @redirect_statuses and redirects_left > 0 ->
        case redirect_location(url, response_headers) do
          nil ->
            response

          location ->
            Logger.debug("handling redirect #{url} -> #{location}")
            request_follow_redirect(method, location, headers, body, opts, redirects_left - 1)
        end

      {:ok, status, response_headers, _ref} = response when status in @redirect_statuses ->
        if redirect_location(url, response_headers) do
          Logger.debug("redirect limit was reached while handling #{url}")
        end

        response

      other ->
        other
    end
  end

  defp redirect_location(url, headers) do
    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "location", do: value

      _ ->
        nil
    end)
    |> case do
      nil -> nil
      location -> URI.merge(url, location) |> URI.to_string()
    end
  end
end
