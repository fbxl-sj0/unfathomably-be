# Unfathomably: local web-origin identity
#
# File: local_origin.ex
#
# Purpose:
#   Normalize every configured origin that identifies this installation and
#   prevent remote-discovery code from recursively probing those origins.
#
# Responsibilities:
#   - compare HTTP origins by normalized scheme, hostname, and effective port
#   - include the endpoint, WebFinger domain, and fetch-actor origin
#   - recognize WebFinger authorities without weakening URL-origin matching
#
# This file intentionally does not perform HTTP requests or decide whether a
# genuinely remote destination is safe to contact.

defmodule Pleroma.Web.LocalOrigin do
  alias Pleroma.Config
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.WebFinger

  @blocked_host_suffixes [".internal", ".invalid", ".local", ".localhost"]
  @type origin :: {String.t(), String.t(), pos_integer()}

  @spec local_url?(term()) :: boolean()
  def local_url?(url), do: local_url?(url, configured_origins())

  @doc false
  @spec local_url?(term(), [String.t()]) :: boolean()
  def local_url?(url, origins) when is_binary(url) and is_list(origins) do
    with {:ok, candidate} <- normalize_url_origin(url) do
      Enum.any?(origins, &(normalize_configured_origin(&1) == {:ok, candidate}))
    else
      _ -> false
    end
  end

  def local_url?(_url, _origins), do: false

  @spec local_webfinger_host?(term()) :: boolean()
  def local_webfinger_host?(host), do: local_webfinger_host?(host, configured_origins())

  @doc false
  @spec local_webfinger_host?(term(), [String.t()]) :: boolean()
  def local_webfinger_host?(host, origins) when is_binary(host) and is_list(origins) do
    case URI.parse("https://" <> host) do
      %URI{scheme: "https", host: parsed_host, userinfo: nil} = uri
      when is_binary(parsed_host) ->
        candidate = {"https", normalize_host(parsed_host), effective_port(uri)}
        Enum.any?(origins, &(normalize_configured_origin(&1) == {:ok, candidate}))

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def local_webfinger_host?(_host, _origins), do: false

  @spec public_remote_host?(term()) :: boolean()
  def public_remote_host?(host) when is_binary(host) do
    host =
      host
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> normalize_host()

    parsed_address = :inet.parse_address(String.to_charlist(host))

    cond do
      host == "" ->
        false

      host in ["localhost", "localhost.localdomain"] ->
        false

      Enum.any?(@blocked_host_suffixes, &String.ends_with?(host, &1)) ->
        false

      match?({:ok, _address}, parsed_address) ->
        {:ok, address} = parsed_address
        public_address?(address)

      Config.get(:env) == :test ->
        true

      true ->
        addresses = resolve_addresses(host)
        addresses != [] and Enum.all?(addresses, &public_address?/1)
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def public_remote_host?(_host), do: false

  @spec configured_origins() :: [String.t()]
  def configured_origins do
    endpoint_url = Endpoint.url()

    [
      endpoint_url,
      webfinger_origin(WebFinger.domain(), endpoint_url),
      Config.get([:activitypub, :fetch_actor_origin])
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp webfinger_origin(domain, endpoint_url) when is_binary(domain) and domain != "" do
    endpoint = URI.parse(endpoint_url)

    case URI.parse("//" <> domain) do
      %URI{host: host} = authority when is_binary(host) ->
        %URI{
          scheme: endpoint.scheme || "https",
          host: host,
          port: authority.port || endpoint.port
        }
        |> URI.to_string()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp webfinger_origin(_domain, _endpoint_url), do: nil

  defp normalize_configured_origin(origin) when is_binary(origin),
    do: normalize_url_origin(origin)

  defp normalize_configured_origin(_origin), do: :error

  defp normalize_url_origin(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, {scheme, normalize_host(host), effective_port(uri)}}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp normalize_host(host) do
    host
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80

  defp resolve_addresses(host) do
    char_host = String.to_charlist(host)

    [:inet, :inet6]
    |> Enum.flat_map(fn family ->
      case :inet.getaddrs(char_host, family) do
        {:ok, addresses} -> addresses
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
  defp public_address?({198, a, _, _}) when a in [18, 19], do: false
  defp public_address?({198, 51, 100, _}), do: false
  defp public_address?({203, 0, 113, _}), do: false
  defp public_address?({a, _, _, _}) when a >= 224, do: false
  defp public_address?({_a, _b, _c, _d}), do: true
  defp public_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_address?({0, 0, 0, 0, 0, prefix, high, low})
       when prefix in [0, 0xFFFF] and high in 0..0xFFFF and low in 0..0xFFFF do
    # IPv4-compatible and IPv4-mapped IPv6 literals must inherit the embedded
    # IPv4 classification. Otherwise ::ffff:127.0.0.1 can bypass an apparently
    # complete IPv4 and IPv6 loopback policy.
    public_address?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})
  end

  defp public_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF,
    do: false

  defp public_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF,
    do: false

  defp public_address?({0x2001, 0xDB8, _, _, _, _, _, _}), do: false
  defp public_address?({first, _, _, _, _, _, _, _}) when first >= 0xFF00, do: false
  defp public_address?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp public_address?(_address), do: false
end

# end of local_origin.ex
