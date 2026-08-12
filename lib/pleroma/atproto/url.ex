# Unfathomably BE
# ----------------
#
# File: atproto/url.ex
#
# Purpose:
#   Keep AT Protocol discovery and PDS requests on public HTTPS origins.
#
# Responsibilities:
#   - normalize origin-only service URLs
#   - reject credentials, local hostnames, and private IP ranges
#   - resolve hostnames before requests to reduce SSRF exposure
#
# This file intentionally does NOT perform HTTP requests, follow redirects, or
# decide which DID document controls an identity.

defmodule Pleroma.ATProto.URL do
  alias Pleroma.Config

  @blocked_suffixes [".internal", ".invalid", ".local", ".localhost", ".test"]

  def normalize_origin(value) when is_binary(value) and byte_size(value) <= 2_048 do
    with {:ok, %URI{} = uri} <- URI.new(String.trim(value)),
         true <- uri.scheme == "https",
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo),
         true <- uri.path in [nil, "", "/"],
         true <- is_nil(uri.query) and is_nil(uri.fragment),
         true <- public_host?(uri.host) do
      port = if is_integer(uri.port) and uri.port != 443, do: ":#{uri.port}", else: ""
      {:ok, "https://#{String.downcase(uri.host)}#{port}"}
    else
      _ -> {:error, :unsafe_service_url}
    end
  rescue
    URI.Error -> {:error, :unsafe_service_url}
  end

  def normalize_origin(_value), do: {:error, :unsafe_service_url}

  def public_https_url?(value) when is_binary(value) and byte_size(value) <= 2_048 do
    with {:ok, %URI{scheme: "https", host: host, userinfo: nil}} <- URI.new(value),
         true <- is_binary(host) and host != "",
         true <- public_host?(host) do
      true
    else
      _ -> false
    end
  rescue
    URI.Error -> false
  end

  def public_https_url?(_value), do: false

  def public_host?(host) when is_binary(host) do
    host = String.downcase(String.trim_trailing(host, "."))
    parsed_address = :inet.parse_address(String.to_charlist(host))

    cond do
      host in ["localhost", "localhost.localdomain"] ->
        false

      Enum.any?(@blocked_suffixes, &String.ends_with?(host, &1)) ->
        false

      match?({:ok, _address}, parsed_address) ->
        {:ok, address} = parsed_address
        public_address?(address)

      Config.get(:env) == :test ->
        true

      true ->
        resolved_addresses = addresses(host)
        resolved_addresses != [] and Enum.all?(resolved_addresses, &public_address?/1)
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def public_host?(_host), do: false

  defp addresses(host) do
    char_host = String.to_charlist(host)

    [:inet, :inet6]
    |> Enum.flat_map(fn family ->
      case :inet.getaddrs(char_host, family) do
        {:ok, values} -> values
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp public_address?({a, _, _, _}) when a in [0, 10, 127], do: false
  defp public_address?({169, 254, _, _}), do: false
  defp public_address?({172, b, _, _}) when b in 16..31, do: false
  defp public_address?({192, 168, _, _}), do: false
  defp public_address?({100, b, _, _}) when b in 64..127, do: false
  defp public_address?({192, 0, 0, _}), do: false
  defp public_address?({192, 0, 2, _}), do: false
  defp public_address?({198, 18, _, _}), do: false
  defp public_address?({198, 19, _, _}), do: false
  defp public_address?({198, 51, 100, _}), do: false
  defp public_address?({203, 0, 113, _}), do: false
  defp public_address?({a, _, _, _}) when a >= 224, do: false
  defp public_address?({_a, _b, _c, _d}), do: true
  defp public_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  # IPv4-compatible and IPv4-mapped literals can otherwise smuggle loopback
  # and private IPv4 destinations through an IPv6-shaped URL.
  defp public_address?({0, _, _, _, _, _, _, _}), do: false

  defp public_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF,
    do: false

  defp public_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF,
    do: false

  defp public_address?({0x2001, 0xDB8, _, _, _, _, _, _}), do: false
  defp public_address?({0x2001, 0, _, _, _, _, _, _}), do: false
  defp public_address?({0x2002, _, _, _, _, _, _, _}), do: false
  defp public_address?({first, _, _, _, _, _, _, _}) when first >= 0xFF00, do: false
  defp public_address?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp public_address?(_address), do: false
end

# end of atproto/url.ex
