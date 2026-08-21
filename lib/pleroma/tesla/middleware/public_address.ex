# Unfathomably: outbound HTTP address policy
#
# File: public_address.ex
#
# Purpose:
#   Apply the public-address policy immediately before an HTTP adapter runs.
#
# Responsibilities:
#   - reject private and special-use destinations
#   - run again when redirect middleware follows a new URL
#
# This file intentionally does not resolve or open network connections itself.

defmodule Pleroma.Tesla.Middleware.PublicAddress do
  @moduledoc false

  @behaviour Tesla.Middleware

  alias Pleroma.HTTP.PublicAddress

  @impl Tesla.Middleware
  def call(%Tesla.Env{url: url} = env, next, _options) do
    if PublicAddress.public_url?(url) do
      env
      |> put_uri_authority()
      |> Tesla.run(next)
    else
      {:error, :private_network_address}
    end
  end

  # Gun opens a public-only socket by its validated address so DNS cannot
  # redirect the connection after validation. The HTTP authority must still
  # identify the URI host, especially for HTTP/2 servers and shared CDNs.
  defp put_uri_authority(%Tesla.Env{url: url} = env) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        Tesla.put_header(env, "host", authority(scheme, host, port))

      _ ->
        env
    end
  end

  defp authority(scheme, host, port) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    case {scheme, port} do
      {"http", 80} -> host
      {"https", 443} -> host
      {_, nil} -> host
      {_, port} -> "#{host}:#{port}"
    end
  end
end

# end of public_address.ex
