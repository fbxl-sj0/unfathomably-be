# Unfathomably PeerTube channel discovery
# ----------------------------------------
#
# File: peertube_channel_discovery.ex
#
# Purpose:
#   Search operator-approved PeerTube bridges for public video-channel actors.
#
# Responsibilities:
#   - reuse the bridge's accepted server-link graph
#   - search only channels already known to the bridge
#   - reject channel records whose declared host disagrees with the actor URL
#   - preserve the ActivityPub actor URL for deliberate local resolution
#
# This file intentionally does not search arbitrary PeerTube servers, enable
# global third-party search, follow channels, or import channel videos.

defmodule Pleroma.Web.ActivityPub.PeerTubeChannelDiscovery do
  alias Pleroma.Config
  alias Pleroma.HTTP
  alias Pleroma.Web.ActivityPub.NativeDiscovery

  @max_indexes 4
  @max_limit 20
  @max_offset 5_000
  @max_query_length 200
  @search_path "/api/v1/search/video-channels"

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query = params |> value("q") |> normalize_query()
    limit = params |> value("limit") |> bounded_integer(12, 1, @max_limit)
    offset = params |> value("offset") |> bounded_integer(0, 0, @max_offset)

    if String.length(query) < 2 do
      response(query, offset, limit, [], [], false, 0)
    else
      results =
        configured_indexes()
        |> Enum.map(&search_index(&1, query, limit, offset))

      items =
        results
        |> Enum.flat_map(& &1.items)
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(limit)

      providers =
        Enum.map(results, fn result ->
          %{
            type: "peertube",
            host: result.host,
            status: result.status,
            accepted_peer_count: result.accepted_peer_count
          }
        end)

      has_more =
        Enum.any?(results, fn result ->
          result.status == "ready" and
            result.raw_count == limit and
            result.total > offset + result.raw_count
        end)

      total =
        results
        |> Enum.filter(&(&1.status == "ready"))
        |> Enum.map(& &1.total)
        |> Enum.max(fn -> 0 end)

      response(query, offset, limit, items, providers, has_more, total)
    end
  end

  defp response(query, offset, limit, items, providers, has_more, total) do
    %{
      family: "peertube_channel",
      query: query,
      count: length(items),
      total: total,
      items: items,
      providers: providers,
      has_more: has_more,
      next_offset: if(has_more, do: offset + limit, else: nil)
    }
  end

  defp configured_indexes do
    Config.get([:native_discovery, :peertube_indexes], [])
    |> case do
      values when is_list(values) -> values
      value when is_binary(value) -> [value]
      _ -> []
    end
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim_trailing(String.trim(&1), "/"))
    |> Enum.filter(&secure_root?/1)
    |> Enum.uniq()
    |> Enum.take(@max_indexes)
  end

  defp secure_root?(root) do
    case URI.parse(root) do
      %URI{scheme: "https", host: host, path: path, query: nil, fragment: nil}
      when is_binary(host) and host != "" and path in ["", "/"] ->
        true

      _ ->
        false
    end
  end

  defp search_index(index, query, limit, offset) do
    with {:ok, %{hosts: accepted_hosts, peers: peers}} <-
           NativeDiscovery.accepted_peertube_graph(index),
         {:ok, payload} <- fetch_channels(index, query, limit, offset),
         data when is_list(data) <- value(payload, "data") do
      items =
        data
        |> Enum.map(&normalize_channel(&1, index, accepted_hosts))
        |> Enum.reject(&is_nil/1)

      %{
        host: source_host(index),
        status: "ready",
        accepted_peer_count: peer_count(peers, accepted_hosts),
        items: items,
        raw_count: length(data),
        total: nonnegative_integer(value(payload, "total"))
      }
    else
      _ -> unavailable_result(index)
    end
  end

  defp unavailable_result(index) do
    %{
      host: source_host(index),
      status: "unavailable",
      accepted_peer_count: 0,
      items: [],
      raw_count: 0,
      total: 0
    }
  end

  defp fetch_channels(index, query, limit, offset) do
    url =
      index <>
        @search_path <>
        "?" <>
        URI.encode_query(%{
          "search" => query,
          "searchTarget" => "local",
          "count" => limit,
          "start" => offset
        })

    case HTTP.get(url, [{"accept", "application/json"}]) do
      {:ok, %{status: 200, body: body}} -> decode_body(body)
      _ -> {:error, :unavailable}
    end
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(_body), do: {:error, :invalid_body}

  defp normalize_channel(channel, index, accepted_hosts) when is_map(channel) do
    actor_url = value(channel, "url") |> safe_channel_url()
    declared_host = value(channel, "host") |> normalized_host()
    actor_host = source_host(actor_url)
    name = value(channel, "name") |> short_text(80)
    title = (value(channel, "displayName") || name) |> short_text(300)

    if actor_url && declared_host && actor_host == declared_host && name && title &&
         accepted_host?(declared_host, accepted_hosts, index) do
      owner = value(channel, "ownerAccount")

      %{
        id: actor_url,
        family: "video",
        kind: "video_channel",
        title: title,
        summary: value(channel, "description") |> plain_text(1_500),
        support: value(channel, "support") |> plain_text(1_000),
        url: actor_url,
        activitypub_url: actor_url,
        avatar_url:
          channel
          |> value("avatars")
          |> best_image()
          |> Pleroma.Web.MediaProxy.browser_url(),
        banner_url:
          channel
          |> value("banners")
          |> best_image()
          |> Pleroma.Web.MediaProxy.browser_url(),
        handle: "@" <> name <> "@" <> declared_host,
        source_host: declared_host,
        owner_name: actor_name(owner),
        owner_url: actor_url(owner),
        followers_count: nonnegative_integer(value(channel, "followersCount")),
        following_count: nonnegative_integer(value(channel, "followingCount")),
        provider_host: source_host(index),
        local_action: "resolve"
      }
    end
  end

  defp normalize_channel(_channel, _index, _accepted_hosts), do: nil

  defp accepted_host?(host, accepted_hosts, index) do
    host == source_host(index) or
      case accepted_hosts do
        %MapSet{} -> MapSet.member?(accepted_hosts, host)
        hosts when is_list(hosts) -> host in hosts
        hosts when is_map(hosts) -> Map.has_key?(hosts, host)
        _ -> false
      end
  end

  defp peer_count(peers, _hosts) when is_list(peers), do: length(peers)
  defp peer_count(_peers, %MapSet{} = hosts), do: MapSet.size(hosts)
  defp peer_count(_peers, hosts) when is_list(hosts), do: length(hosts)
  defp peer_count(_peers, _hosts), do: 0

  defp best_image(images) when is_list(images) do
    images
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&nonnegative_integer(value(&1, "width")), :desc)
    |> Enum.find_value(fn image -> value(image, "fileUrl") |> safe_url() end)
  end

  defp best_image(_images), do: nil

  defp actor_name(actor) when is_map(actor) do
    (value(actor, "displayName") || value(actor, "name"))
    |> short_text(300)
  end

  defp actor_name(_actor), do: nil

  defp actor_url(actor) when is_map(actor) do
    value(actor, "url")
    |> safe_url()
  end

  defp actor_url(_actor), do: nil

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || existing_atom_value(map, key)
  end

  defp value(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    case safe_existing_atom(key) do
      nil -> nil
      atom -> Map.get(map, atom)
    end
  end

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp normalize_query(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, @max_query_length)
  end

  defp normalize_query(_value), do: ""

  defp bounded_integer(value, default, minimum, maximum) do
    parsed =
      case value do
        integer when is_integer(integer) ->
          integer

        binary when is_binary(binary) ->
          case Integer.parse(binary) do
            {integer, ""} -> integer
            _ -> default
          end

        _ ->
          default
      end

    parsed
    |> max(minimum)
    |> min(maximum)
  end

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(value) when is_float(value) and value >= 0, do: trunc(value)
  defp nonnegative_integer(_value), do: 0

  defp plain_text(value, maximum) when is_binary(value) do
    value
    |> String.replace(~r/<[^>]*>/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, maximum)
    |> empty_to_nil()
  end

  defp plain_text(_value, _maximum), do: nil

  defp short_text(value, maximum) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, maximum)
    |> empty_to_nil()
  end

  defp short_text(_value, _maximum), do: nil

  defp normalized_host(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> empty_to_nil()
  end

  defp normalized_host(_value), do: nil

  defp safe_channel_url(value) do
    case safe_url(value) do
      nil ->
        nil

      url ->
        case URI.parse(url) do
          %URI{path: "/video-channels/" <> name} when name != "" -> url
          _ -> nil
        end
    end
  end

  defp safe_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> value
      _ -> nil
    end
  end

  defp safe_url(_value), do: nil

  defp source_host(nil), do: ""

  defp source_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> ""
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end

# end of peertube_channel_discovery.ex
