# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.RemoteIp do
  @moduledoc """
  This is a shim to call [`RemoteIp`](https://hex.pm/packages/remote_ip) but with runtime configuration.
  """

  alias Pleroma.Config
  import Plug.Conn

  @behaviour Plug

  def init(_), do: nil

  def call(%{remote_ip: original_remote_ip} = conn, _) do
    if Config.get([__MODULE__, :enabled]) do
      new_remote_ip = remote_ip(conn) || original_remote_ip
      conn = %{conn | remote_ip: new_remote_ip}

      assign(conn, :remote_ip_found, original_remote_ip != new_remote_ip)
    else
      conn
    end
  end

  defp remote_ip(conn) do
    opts = remote_ip_opts()

    # Do not use RemoteIp.from/2 here. The upstream library always applies its
    # built-in reserved ranges, while Pleroma exposes :reserved as instance
    # configuration. We still reuse the library's header parsing.
    conn.req_headers
    |> RemoteIp.Headers.take(opts[:headers])
    |> RemoteIp.Headers.parse()
    |> Enum.reverse()
    |> Enum.find(&client?(&1, opts))
  end

  defp remote_ip_opts do
    reserved = Config.get([__MODULE__, :reserved], [])

    proxies =
      Config.get([__MODULE__, :proxies], [])
      |> Enum.concat(reserved)
      |> Enum.map(&maybe_add_cidr/1)

    clients =
      Config.get([__MODULE__, :clients], [])
      |> Enum.map(&maybe_add_cidr/1)

    [
      headers: Config.get([__MODULE__, :headers], []),
      clients: clients,
      proxies: proxies
    ]
  end

  defp client?(ip, opts) do
    client_ip?(ip, opts[:clients]) || not proxy_ip?(ip, opts[:proxies])
  end

  defp client_ip?(ip, clients) do
    Enum.any?(clients, &InetCidr.contains?(&1, ip))
  end

  defp proxy_ip?(ip, proxies) do
    Enum.any?(proxies, &InetCidr.contains?(&1, ip))
  end

  defp maybe_add_cidr(proxy) when is_binary(proxy) do
    proxy =
      cond do
        "/" in String.codepoints(proxy) -> proxy
        InetCidr.v4?(InetCidr.parse_address!(proxy)) -> proxy <> "/32"
        InetCidr.v6?(InetCidr.parse_address!(proxy)) -> proxy <> "/128"
      end

    InetCidr.parse_cidr!(proxy, true)
  end
end
