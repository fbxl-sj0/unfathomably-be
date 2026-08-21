# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.Onion do
  @moduledoc """
  Applies the local Tor client transport to v3 onion-service requests.

  Onion names must never reach the ordinary resolver. This module therefore
  validates the v3 address, including its checksum and version byte, before it
  selects a loopback-only SOCKS5 proxy. Invalid or disabled onion requests fail
  before the HTTP adapter is called.

  Tor itself is responsible for resolving the onion name. Passing the original
  destination hostname to the SOCKS5 connection is required for that behavior.
  """

  alias Pleroma.Config

  @checksum_prefix ".onion checksum"
  @onion_suffix ".onion"
  @onion_version 3
  @onion_public_key_size 32
  @onion_checksum_size 2
  @loopback {127, 0, 0, 1}

  @spec route(URI.t(), keyword()) :: {:ok, keyword()} | {:error, atom()}
  def route(%URI{scheme: scheme, host: host}, options)
      when scheme in ["http", "https"] and is_binary(host) and is_list(options) do
    case classify_host(host) do
      :clearnet ->
        {:ok, options}

      :invalid_onion ->
        {:error, :invalid_onion_host}

      :onion ->
        onion_options(options)
    end
  end

  def route(_uri, options) when is_list(options), do: {:ok, options}

  defp classify_host(host) do
    host = String.downcase(host)

    if String.ends_with?(host, @onion_suffix) do
      if valid_v3_host?(host), do: :onion, else: :invalid_onion
    else
      :clearnet
    end
  end

  defp valid_v3_host?(host) do
    labels = String.split(host, ".")

    case Enum.reverse(labels) do
      ["onion", service | subdomains] ->
        valid_service_label?(service) and Enum.all?(subdomains, &valid_subdomain_label?/1)

      _ ->
        false
    end
  end

  defp valid_service_label?(service) do
    with {:ok, decoded} <- Base.decode32(service, case: :lower, padding: false),
         <<public_key::binary-size(@onion_public_key_size),
           checksum::binary-size(@onion_checksum_size), @onion_version>> <- decoded,
         expected_checksum <- onion_checksum(public_key),
         true <- Plug.Crypto.secure_compare(checksum, expected_checksum) do
      true
    else
      _ -> false
    end
  end

  defp valid_subdomain_label?(label) do
    byte_size(label) in 1..63 and
      String.match?(label, ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/)
  end

  defp onion_checksum(public_key) do
    :crypto.hash(:sha3_256, @checksum_prefix <> public_key <> <<@onion_version>>)
    |> binary_part(0, @onion_checksum_size)
  end

  defp onion_options(options) do
    if Config.get([__MODULE__, :enabled], false) do
      with {:ok, socks_port} <- positive_integer(:socks_port, 9050, 65_535),
           {:ok, connect_timeout} <- positive_integer(:connect_timeout, 15_000),
           {:ok, recv_timeout} <- positive_integer(:recv_timeout, 30_000) do
        forced_options = [
          proxy: {:socks5, @loopback, socks_port},
          pool: :onion,
          connect_timeout: connect_timeout,
          recv_timeout: recv_timeout,
          retry: 0
        ]

        {:ok, Keyword.merge(options, forced_options)}
      end
    else
      {:error, :onion_transport_disabled}
    end
  end

  defp positive_integer(key, default, maximum \\ :infinity) do
    value = Config.get([__MODULE__, key], default)

    if is_integer(value) and value > 0 and (maximum == :infinity or value <= maximum) do
      {:ok, value}
    else
      {:error, :invalid_onion_transport_config}
    end
  end
end

# End of Pleroma.HTTP.Onion.
