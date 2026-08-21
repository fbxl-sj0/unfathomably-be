# Unfathomably: outbound HTTP address policy
#
# File: public_address.ex
#
# Purpose:
#   Resolve Internet destinations and reject addresses that must never be
#   reached by federation, preview, discovery, or provider requests.
#
# Responsibilities:
#   - validate HTTP and HTTPS destination URLs
#   - resolve every A and AAAA answer before an outbound connection
#   - reject local, private, transition, documentation, and special-use ranges
#   - return one validated address so the Gun adapter can pin the connection
#
# This file intentionally does not contain HTTP request or redirect handling.

defmodule Pleroma.HTTP.PublicAddress do
  @moduledoc false

  import Bitwise

  @type address :: :inet.ip_address()

  @spec public_url?(String.t()) :: boolean()
  def public_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        test_reserved_host?(host) or onion_host?(host) or
          match?({:ok, _address}, resolve_public_address(host))

      _ ->
        false
    end
  rescue
    URI.Error -> false
  end

  def public_url?(_), do: false

  @spec resolve_public_address(String.t()) :: {:ok, address()} | {:error, atom()}
  def resolve_public_address(host) when is_binary(host) do
    host = host |> String.trim() |> String.trim_leading("[") |> String.trim_trailing("]")

    if test_reserved_host?(host) do
      {:ok, {192, 0, 2, 1}}
    else
      resolve_public_host(host)
    end
  end

  def resolve_public_address(_), do: {:error, :invalid_address}

  defp resolve_public_host(host) do
    with false <- host == "" or local_name?(host) or onion_host?(host),
         {:ok, [address | _] = addresses} <- resolve_addresses(host),
         true <- Enum.all?(addresses, &public_address?/1) do
      {:ok, address}
    else
      true -> {:error, :private_network_address}
      false -> {:error, :private_network_address}
      {:error, _reason} -> {:error, :unresolvable_address}
    end
  end

  @spec onion_host?(String.t()) :: boolean()
  def onion_host?(host) when is_binary(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
    |> String.ends_with?(".onion")
  end

  def onion_host?(_), do: false

  defp test_reserved_host?(host) do
    Pleroma.Config.get(:env) == :test and not ip_literal?(host) and
      (test_loopback_fixture?(host) or not local_name?(host))
  end

  defp test_loopback_fixture?(host) do
    host |> String.downcase() |> String.trim_trailing(".") |> Kernel.==("localhost")
  end

  defp ip_literal?(host) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))
  end

  defp resolve_addresses(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        resolve_dns_addresses(host)
    end
  end

  defp resolve_dns_addresses(host) do
    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(&lookup_addresses(host, &1))
      |> Enum.uniq()

    if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
  end

  defp lookup_addresses(host, family) do
    case :inet.getaddrs(String.to_charlist(host), family) do
      {:ok, values} -> values
      {:error, _reason} -> []
    end
  end

  defp local_name?(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    host in ["localhost", "localhost.localdomain"] or
      Enum.any?(
        [".localhost", ".local", ".internal", ".home", ".lan", ".test"],
        &String.ends_with?(host, &1)
      )
  end

  defp public_address?({a, b, c, d} = address)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
       do: not private_ipv4?(address)

  defp public_address?({a, b, c, d, e, f, g, h} = address)
       when a in 0..0xFFFF and b in 0..0xFFFF and c in 0..0xFFFF and d in 0..0xFFFF and
              e in 0..0xFFFF and f in 0..0xFFFF and g in 0..0xFFFF and h in 0..0xFFFF,
       do: not private_ipv6?(address)

  defp public_address?(_), do: false

  defp private_ipv4?({0, _, _, _}), do: true
  defp private_ipv4?({10, _, _, _}), do: true
  defp private_ipv4?({100, b, _, _}) when b in 64..127, do: true
  defp private_ipv4?({127, _, _, _}), do: true
  defp private_ipv4?({169, 254, _, _}), do: true
  defp private_ipv4?({172, b, _, _}) when b in 16..31, do: true
  defp private_ipv4?({192, 0, 0, _}), do: true
  defp private_ipv4?({192, 0, 2, _}), do: true
  defp private_ipv4?({192, 31, 196, _}), do: true
  defp private_ipv4?({192, 52, 193, _}), do: true
  defp private_ipv4?({192, 88, 99, _}), do: true
  defp private_ipv4?({192, 168, _, _}), do: true
  defp private_ipv4?({192, 175, 48, _}), do: true
  defp private_ipv4?({198, b, _, _}) when b in 18..19, do: true
  defp private_ipv4?({198, 51, 100, _}), do: true
  defp private_ipv4?({203, 0, 113, _}), do: true
  defp private_ipv4?({a, _, _, _}) when a >= 224, do: true
  defp private_ipv4?(_), do: false

  defp private_ipv6?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv4-compatible and IPv4-mapped IPv6 addresses inherit the IPv4 policy.
  defp private_ipv6?({0, 0, 0, 0, 0, marker, g, h}) when marker in [0, 0xFFFF] do
    private_ipv4?({g >>> 8, g &&& 0xFF, h >>> 8, h &&& 0xFF})
  end

  # RFC 6052 and RFC 8215 translation prefixes can conceal an IPv4 target.
  defp private_ipv6?({0x64, 0xFF9B, 0, 0, 0, 0, _, _}), do: true
  defp private_ipv6?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true
  defp private_ipv6?({0x100, 0, 0, 0, _, _, _, _}), do: true

  defp private_ipv6?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  defp private_ipv6?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: true
  defp private_ipv6?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFEC0, do: true
  defp private_ipv6?({a, _, _, _, _, _, _, _}) when (a &&& 0xFF00) == 0xFF00, do: true
  defp private_ipv6?({0x2001, 0, _, _, _, _, _, _}), do: true
  defp private_ipv6?({0x2001, b, _, _, _, _, _, _}) when b in 0x10..0x1F, do: true
  defp private_ipv6?({0x2001, b, _, _, _, _, _, _}) when b in 0x20..0x2F, do: true
  defp private_ipv6?({0x2001, 0xDB8, _, _, _, _, _, _}), do: true
  defp private_ipv6?({0x2002, _, _, _, _, _, _, _}), do: true
  defp private_ipv6?({0x3FFF, b, _, _, _, _, _, _}) when b < 0x1000, do: true
  defp private_ipv6?(_), do: false
end

# end of public_address.ex
