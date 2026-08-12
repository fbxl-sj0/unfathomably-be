# Unfathomably Mobilizon search-index discovery
# ------------------------------------------------
#
# File: mobilizon_search_discovery.ex
#
# Purpose:
#   Search operator-approved Mobilizon indexes for public events and organizer
#   group actors.
#
# Responsibilities:
#   - bound every user-initiated index request
#   - accept only configured HTTPS index roots
#   - normalize event and organizer records into the native discovery envelope
#   - preserve stable ActivityPub identifiers for local resolution
#
# This file intentionally does not follow actors, join events, persist remote
# objects, crawl Mobilizon instances, or accept a provider URL from a client.

defmodule Pleroma.Web.ActivityPub.MobilizonSearchDiscovery do
  alias Pleroma.Config
  alias Pleroma.HTTP

  @default_indexes ["https://search.mobilizon.fr"]
  @event_path "/api/v1/search/events"
  @group_path "/api/v1/search/groups"
  @max_indexes 4
  @max_limit 20
  @max_offset 5_000
  @max_query_length 200

  @type mode :: :events | :groups

  @spec search(map(), mode()) :: map()
  def search(params, mode) when is_map(params) and mode in [:events, :groups] do
    query = params |> value("q") |> normalize_query()
    limit = params |> value("limit") |> bounded_integer(16, 1, @max_limit)
    offset = params |> value("offset") |> bounded_integer(0, 0, @max_offset)

    if String.length(query) < 2 do
      response(mode, query, offset, limit, [], [], false)
    else
      results =
        configured_indexes()
        |> Enum.map(&fetch_index(&1, mode, query, limit, offset))

      items =
        results
        |> Enum.flat_map(& &1.items)
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(limit)

      providers =
        Enum.map(results, fn result ->
          %{
            type: "mobilizon_search",
            host: result.host,
            status: result.status
          }
        end)

      has_more =
        Enum.any?(results, fn result ->
          result.status == "ready" and result.total > offset + length(result.items)
        end)

      response(mode, query, offset, limit, items, providers, has_more)
    end
  end

  defp response(mode, query, offset, limit, items, providers, has_more) do
    %{
      family: if(mode == :events, do: "mobilizon_event", else: "mobilizon_group"),
      query: query,
      count: length(items),
      items: items,
      results: items,
      providers: providers,
      has_more: has_more,
      next_offset: if(has_more, do: offset + limit, else: nil)
    }
  end

  defp configured_indexes do
    configured =
      Config.get(
        [:native_discovery, :mobilizon_search_indexes],
        @default_indexes
      )

    configured
    |> case do
      values when is_list(values) -> values
      value when is_binary(value) -> [value]
      _ -> @default_indexes
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

  defp fetch_index(root, mode, query, limit, offset) do
    endpoint = if(mode == :events, do: @event_path, else: @group_path)

    query_params =
      %{
        "search" => query,
        "count" => limit,
        "start" => offset
      }
      |> maybe_require_upcoming_events(mode)

    url =
      root <>
        endpoint <>
        "?" <>
        URI.encode_query(query_params)

    case HTTP.get(url, [{"accept", "application/json"}]) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, payload} <- decode_body(body),
             data when is_list(data) <- value(payload, "data") do
          items =
            data
            |> Enum.map(&normalize_item(&1, mode, root))
            |> Enum.reject(&is_nil/1)

          %{
            host: provider_host(root),
            status: "ready",
            items: items,
            total: nonnegative_integer(value(payload, "total"))
          }
        else
          _ -> unavailable_result(root)
        end

      _ ->
        unavailable_result(root)
    end
  end

  defp unavailable_result(root) do
    %{host: provider_host(root), status: "unavailable", items: [], total: 0}
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(_body), do: {:error, :invalid_body}

  defp normalize_item(item, :events, root) when is_map(item) do
    id = value(item, "id") |> safe_url()
    url = (value(item, "url") || id) |> safe_url()
    title = value(item, "name") |> short_text(300)

    if id && url && title do
      location = value(item, "location")
      creator = value(item, "creator")
      group = value(item, "group")
      organizer = if(is_map(group), do: group, else: creator)

      %{
        id: id,
        family: "event",
        kind: "event",
        title: title,
        summary: value(item, "description") |> plain_text(1_500),
        url: url,
        activitypub_url: id,
        image_url: value(item, "banner") |> safe_url() |> Pleroma.Web.MediaProxy.browser_url(),
        begins_at: value(item, "startTime") |> short_text(80),
        ends_at: value(item, "endTime") |> short_text(80),
        venue_name: location_name(location),
        venue_address: location_address(location),
        organizer_name: actor_name(organizer),
        organizer_url: actor_url(organizer),
        creator_name: actor_name(creator),
        creator_url: actor_url(creator),
        group_name: actor_name(group),
        group_url: actor_url(group),
        category: value(item, "category") |> short_text(80),
        language: value(item, "language") |> short_text(24),
        status: value(item, "status") |> short_text(40),
        join_mode: value(item, "joinMode") |> short_text(40),
        is_online: value(item, "isOnline") == true,
        participant_count: nonnegative_integer(value(item, "participantCount")),
        capacity: nonnegative_integer(value(item, "maximumAttendeeCapacity")),
        remaining_capacity:
          optional_nonnegative_integer(value(item, "remainingAttendeeCapacity")),
        tags: normalize_tags(value(item, "tags")),
        source_host: source_host(id),
        provider_host: provider_host(root),
        local_action: "resolve"
      }
    end
  end

  defp normalize_item(item, :groups, root) when is_map(item) do
    id = (value(item, "id") || value(item, "url")) |> safe_url()
    url = (value(item, "url") || id) |> safe_url()
    title = (value(item, "displayName") || value(item, "name")) |> short_text(300)

    if id && url && title do
      host = value(item, "host") |> short_text(255)
      name = value(item, "name") |> short_text(255)

      %{
        id: id,
        family: "event",
        kind: "organizer",
        title: title,
        summary: value(item, "description") |> plain_text(1_500),
        url: url,
        activitypub_url: id,
        image_url: value(item, "avatar") |> safe_url() |> Pleroma.Web.MediaProxy.browser_url(),
        handle: actor_handle(name, host),
        member_count: nonnegative_integer(value(item, "memberCount")),
        openness: value(item, "openness") |> short_text(40),
        manually_approves_followers: value(item, "manuallyApprovesFollowers") == true,
        language: value(item, "language") |> short_text(24),
        source_host: host || source_host(id),
        provider_host: provider_host(root),
        local_action: "resolve"
      }
    end
  end

  defp normalize_item(_item, _mode, _root), do: nil

  # Relevance-only Mobilizon searches can otherwise return a perfect textual
  # match for an event that ended years ago. Organizer search has no date
  # concept, so the lower bound applies only to event records.
  defp maybe_require_upcoming_events(params, :events) do
    Map.put(params, "startDateMin", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp maybe_require_upcoming_events(params, :groups), do: params

  defp actor_name(actor) when is_map(actor) do
    (value(actor, "displayName") || value(actor, "name"))
    |> short_text(300)
  end

  defp actor_name(_actor), do: nil

  defp actor_url(actor) when is_map(actor) do
    (value(actor, "id") || value(actor, "url"))
    |> safe_url()
  end

  defp actor_url(_actor), do: nil

  defp actor_handle(name, host)
       when is_binary(name) and name != "" and is_binary(host) and host != "" do
    "@" <> name <> "@" <> host
  end

  defp actor_handle(_name, _host), do: nil

  defp location_name(location) when is_map(location) do
    value(location, "name")
    |> short_text(300)
  end

  defp location_name(_location), do: nil

  defp location_address(location) when is_map(location) do
    address = value(location, "address")

    if is_map(address) do
      [
        value(address, "streetAddress"),
        value(address, "postalCode"),
        value(address, "addressLocality"),
        value(address, "addressRegion"),
        value(address, "addressCountry")
      ]
      |> Enum.map(&short_text(&1, 200))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(", ")
      |> empty_to_nil()
    end
  end

  defp location_address(_location), do: nil

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim_leading(String.trim(&1), "#"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp normalize_tags(_tags), do: []

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

  defp optional_nonnegative_integer(nil), do: nil
  defp optional_nonnegative_integer(value), do: nonnegative_integer(value)

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

  defp safe_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> value
      _ -> nil
    end
  end

  defp safe_url(_value), do: nil

  defp source_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> ""
    end
  end

  defp provider_host(root), do: source_host(root)

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end

# end of mobilizon_search_discovery.ex
