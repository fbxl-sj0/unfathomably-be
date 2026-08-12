# Unfathomably received video playlist discovery
# ------------------------------------------------
#
# File: video_playlist_discovery.ex
#
# Purpose:
#   Search public PeerTube Playlist objects already received through federation.
#
# Responsibilities:
#   - distinguish PeerTube playlists from other Playlist vocabularies by shape
#   - use a dedicated indexed search document
#   - enforce public remote visibility
#   - preserve collection, channel, artwork, count, and publication metadata
#
# This file intentionally does not fetch remote collection pages, enumerate
# missing elements, classify by hostname, or treat audio playlists as video.

defmodule Pleroma.Web.ActivityPub.VideoPlaylistDiscovery do
  import Ecto.Query

  require Logger

  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.MediaProxy

  @maximum_limit 24
  @maximum_offset 500
  @maximum_scan 600
  @minimum_scan 60
  @query_timeout 15_000

  def search(params) when is_map(params) do
    search(
      Map.get(params, "q", Map.get(params, :q, "")),
      integer_value(Map.get(params, "limit", Map.get(params, :limit, 16)), 16),
      integer_value(Map.get(params, "offset", Map.get(params, :offset, 0)), 0)
    )
  end

  def search(query, limit, offset) do
    query = bounded_text(query, 200) || ""
    limit = bounded_integer(limit, 1, @maximum_limit, 16)
    offset = bounded_integer(offset, 0, @maximum_offset, 0)
    scan_limit = min(max((offset + limit) * 4, @minimum_scan), @maximum_scan)

    matching_objects =
      query
      |> playlist_query(scan_limit)
      |> Repo.all(timeout: @query_timeout)
      |> Enum.filter(&public_federated_object?/1)
      |> Enum.map(&normalize_object/1)
      |> Enum.reject(&is_nil/1)

    items =
      matching_objects
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> hydrate_channel_labels()

    %{
      items: items,
      total: max(length(matching_objects), offset + length(items)),
      has_more:
        length(matching_objects) > offset + length(items) or
          length(matching_objects) == scan_limit,
      provider: provider_metadata("ready"),
      communities: []
    }
  rescue
    error ->
      Logger.warning(
        "Local received video playlist discovery failed: #{Exception.message(error)}"
      )

      %{
        items: [],
        total: 0,
        has_more: false,
        provider: provider_metadata("unavailable"),
        communities: []
      }
  end

  defp playlist_query(search, scan_limit) do
    query =
      from(object in Object,
        where: fragment("?->>'type' = 'Playlist'", object.data),
        where: fragment("jsonb_typeof(?->'videoChannelPosition') = 'number'", object.data),
        order_by: [desc: object.id],
        limit: ^scan_limit
      )

    if search == "" do
      query
    else
      from(object in query,
        where:
          fragment(
            """
            to_tsvector(
              'simple',
              coalesce(?->>'name', '') || ' ' ||
              coalesce(?->>'content', '') || ' ' ||
              coalesce(?->>'summary', '') || ' ' ||
              coalesce(?->>'uuid', '') || ' ' ||
              coalesce(?->>'attributedTo', '')
            ) @@ websearch_to_tsquery('simple', ?)
            """,
            object.data,
            object.data,
            object.data,
            object.data,
            object.data,
            ^search
          )
      )
    end
  end

  defp public_federated_object?(%Object{} = object) do
    Visibility.is_public?(object) and not Visibility.is_local_public?(object)
  rescue
    _ -> false
  end

  defp public_federated_object?(_object), do: false

  defp normalize_object(%Object{data: data}) when is_map(data) do
    with activitypub_url when is_binary(activitypub_url) <- https_url(data["id"]),
         source_host when is_binary(source_host) <- URI.parse(activitypub_url).host,
         title when is_binary(title) <- first_text(data["name"]),
         position when is_integer(position) <- nonnegative_integer(data["videoChannelPosition"]) do
      %{
        id: activitypub_url,
        family: "video",
        kind: "video_playlist",
        title: bounded_text(title, 500),
        description: plain_text(data["content"] || data["summary"], 2_000),
        url: source_url(data["url"]) || activitypub_url,
        activitypub_url: activitypub_url,
        thumbnail_url: thumbnail_url(data["icon"]),
        channel: channel_metadata(data["attributedTo"]),
        item_count: nonnegative_integer(data["totalItems"]),
        known_item_count: known_item_count(data["orderedItems"]),
        channel_position: position,
        published_at: first_text(data["published"]),
        updated_at: first_text(data["updated"]),
        source_host: String.downcase(source_host),
        local_action: "resolve"
      }
    else
      _ -> nil
    end
  end

  defp normalize_object(_object), do: nil

  defp hydrate_channel_labels(items) do
    channel_urls =
      items
      |> Enum.flat_map(fn
        %{channel: %{url: url}} when is_binary(url) -> [url]
        _ -> []
      end)
      |> Enum.uniq()

    labels =
      if channel_urls == [] do
        %{}
      else
        from(user in User,
          where: user.ap_id in ^channel_urls,
          select: {user.ap_id, user.name, user.nickname}
        )
        |> Repo.all(timeout: @query_timeout)
        |> Map.new(fn {ap_id, name, nickname} ->
          {ap_id, bounded_text(name, 300) || bounded_text(nickname, 300)}
        end)
      end

    Enum.map(items, fn
      %{channel: channel} = item when is_map(channel) ->
        %{item | channel: Map.update!(channel, :name, &(&1 || labels[channel.url]))}

      item ->
        item
    end)
  end

  defp channel_metadata(attributed_to) do
    attributed_to
    |> List.wrap()
    |> Enum.find_value(fn
      %{"type" => type} = actor ->
        if short_type(type) == "Group" do
          case https_url(actor["id"]) || https_url(actor["url"]) do
            url when is_binary(url) ->
              %{
                url: url,
                name: first_text(actor["name"]) || first_text(actor["preferredUsername"])
              }

            _ ->
              nil
          end
        end

      actor when is_binary(actor) ->
        case https_url(actor) do
          url when is_binary(url) -> %{url: url, name: nil}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp source_url(value) do
    value
    |> List.wrap()
    |> Enum.find_value(fn
      %{"mediaType" => media_type} = link
      when media_type in ["text/html", "text/html; charset=utf-8"] ->
        https_url(link["href"]) || https_url(link["url"])

      _ ->
        nil
    end)
    |> case do
      nil -> https_url(value)
      url -> url
    end
  end

  defp thumbnail_url(value) do
    value
    |> List.wrap()
    |> Enum.find_value(fn
      %{"type" => type} = icon when type in ["Image", "Document"] ->
        case https_url(icon["url"]) || https_url(icon["href"]) do
          url when is_binary(url) -> MediaProxy.browser_url(url)
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp known_item_count(items) when is_list(items), do: min(length(items), 10_000)
  defp known_item_count(_items), do: 0

  defp plain_text(value, maximum) when is_binary(value) do
    case Floki.parse_fragment(value) do
      {:ok, document} -> document |> Floki.text(sep: " ") |> bounded_text(maximum)
      _ -> bounded_text(value, maximum)
    end
  rescue
    _ -> bounded_text(value, maximum)
  end

  defp plain_text(_value, _maximum), do: nil

  defp first_text(value) when is_binary(value), do: bounded_text(value, 2_000)

  defp first_text(value) when is_list(value) do
    Enum.find_value(value, &first_text/1)
  end

  defp first_text(value) when is_map(value) do
    ["name", "value", "label", "href", "id", "url"]
    |> Enum.find_value(&first_text(Map.get(value, &1)))
  end

  defp first_text(_value), do: nil

  defp https_url(value) when is_list(value), do: Enum.find_value(value, &https_url/1)

  defp https_url(value) when is_map(value) do
    https_url(value["href"]) || https_url(value["url"]) || https_url(value["id"])
  end

  defp https_url(value) when is_binary(value) and byte_size(value) <= 2_000 do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil}
      when is_binary(host) and byte_size(host) <= 255 ->
        value

      _ ->
        nil
    end
  end

  defp https_url(_value), do: nil

  defp short_type(value) when is_binary(value) do
    value
    |> String.split(["#", "/", ":"], trim: true)
    |> List.last()
  end

  defp short_type(_value), do: nil

  defp nonnegative_integer(value) when is_integer(value) and value >= 0 and value <= 10_000_000,
    do: value

  defp nonnegative_integer(_value), do: nil

  defp provider_metadata(status) do
    %{
      type: "local_video_playlist",
      host: Endpoint.url() |> URI.parse() |> Map.get(:host),
      status: status
    }
  end

  defp integer_value(value, _default) when is_integer(value), do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp integer_value(_value, default), do: default

  defp bounded_integer(value, minimum, maximum, _default)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: value

  defp bounded_integer(_value, _minimum, _maximum, default), do: default

  defp bounded_text(value, maximum) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, maximum)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp bounded_text(_value, _maximum), do: nil
end

# end of video_playlist_discovery.ex
