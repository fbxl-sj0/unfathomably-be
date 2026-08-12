# Unfathomably received video discovery
# --------------------------------------
#
# File: video_object_discovery.ex
#
# Purpose:
#   Search public PeerTube-compatible Video objects already received through
#   federation and present them as videos instead of generic statuses.
#
# Responsibilities:
#   - use indexed native-object classification and search
#   - enforce normal public remote visibility
#   - preserve video, channel, schedule, language, licence, and policy metadata
#   - proxy non-sensitive thumbnail images before returning them to the UI
#
# This file intentionally does not crawl PeerTube servers, fetch media files,
# autoplay video, infer current live state, or expose non-public objects.

defmodule Pleroma.Web.ActivityPub.VideoObjectDiscovery do
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
  @maximum_scan 800
  @minimum_scan 80
  @query_timeout 15_000
  @public_values ["as:Public", "https://www.w3.org/ns/activitystreams#Public"]

  def search(params) when is_map(params) do
    search(
      map_value(params, "q", ""),
      integer_value(map_value(params, "limit", 16), 16),
      integer_value(map_value(params, "offset", 0), 0)
    )
  end

  def search(query, limit, offset) do
    query = bounded_text(query, 200) || ""
    limit = bounded_integer(limit, 1, @maximum_limit, 16)
    offset = bounded_integer(offset, 0, @maximum_offset, 0)
    scan_limit = min(max((offset + limit) * 4, @minimum_scan), @maximum_scan)

    matching_objects =
      query
      |> video_query(scan_limit)
      |> Repo.all(timeout: @query_timeout)
      |> Enum.filter(&public_federated_object?/1)
      |> Enum.map(&normalize_object/1)
      |> Enum.reject(&is_nil/1)
      |> hydrate_actor_labels()

    items =
      matching_objects
      |> Enum.drop(offset)
      |> Enum.take(limit)

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
      Logger.warning("Local received video discovery failed: #{Exception.message(error)}")

      %{
        items: [],
        total: 0,
        has_more: false,
        provider: provider_metadata("unavailable"),
        communities: []
      }
  end

  defp video_query(search, scan_limit) do
    query =
      from(object in Object,
        where: fragment("unfathomably_native_discoverable(?) = true", object.data),
        where: fragment("unfathomably_native_family(?) = 'video'", object.data),
        # Keep the family recency index as the driving path. Using the bare
        # data->>'type' expression here makes PostgreSQL intersect it with the
        # large generic actor/type index, which is much slower for rare media.
        where: fragment("COALESCE(?->>'type', '') = 'Video'", object.data),
        order_by: [desc: object.id],
        limit: ^scan_limit
      )

    if search == "" do
      query
    else
      from(object in query,
        where:
          fragment(
            "unfathomably_native_search_document(?) @@ websearch_to_tsquery('simple', ?)",
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
         title when is_binary(title) <- first_text(data["name"]) do
      sensitive = data["sensitive"] == true
      channel = channel_metadata(data["attributedTo"], data["audience"])
      content_warning = plain_text(data["summary"], 500)

      %{
        id: activitypub_url,
        family: "video",
        kind: "received_video",
        title: bounded_text(title, 500),
        description: if(sensitive, do: nil, else: plain_text(data["content"], 2_000)),
        content_warning: content_warning,
        url: source_url(data["url"]) || activitypub_url,
        activitypub_url: activitypub_url,
        embed_url: https_url(data["embedUrl"]),
        thumbnail_url: if(sensitive, do: nil, else: thumbnail_url(data["icon"])),
        sensitive: sensitive,
        duration_seconds: duration_seconds(data["duration"]),
        channel: channel,
        category: identifier_name(data["category"]),
        language: identifier_name(data["language"]),
        licence: identifier_name(data["licence"] || data["license"]),
        tags: hashtag_names(data["tag"]),
        views: nonnegative_integer(data["views"]),
        downloads: nonnegative_integer(data["downloads"]),
        is_live_broadcast: boolean_value(data["isLiveBroadcast"]),
        scheduled_at: scheduled_at(data["schedules"]),
        wait_transcoding: boolean_value(data["waitTranscoding"]),
        download_enabled: boolean_value(data["downloadEnabled"]),
        comments_enabled: public_reply_capability(data),
        published_at:
          first_text(data["originallyPublishedAt"]) ||
            first_text(data["published"]) ||
            first_text(data["uploadDate"]),
        updated_at: first_text(data["updated"]),
        source_host: String.downcase(source_host),
        local_action: "resolve"
      }
    else
      _ -> nil
    end
  end

  defp normalize_object(_object), do: nil

  defp channel_metadata(attributed_to, audience) do
    actors = List.wrap(attributed_to)

    actor_urls =
      actors
      |> Enum.flat_map(fn
        value when is_binary(value) -> [https_url(value)]
        %{} = value -> [https_url(value["id"]) || https_url(value["url"])]
        _ -> []
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    group =
      Enum.find(actors, fn
        %{"type" => type} -> short_type(type) == "Group"
        _ -> false
      end)

    owner =
      Enum.find(actors, fn
        %{"type" => type} -> short_type(type) == "Person"
        _ -> false
      end)

    channel_url =
      case group do
        value when is_map(value) -> https_url(value["id"]) || https_url(value["url"])
        _ -> Enum.find(actor_urls, &peertube_channel_url?/1) || https_url(audience)
      end

    if channel_url do
      owner_url =
        case owner do
          value when is_map(value) -> https_url(value["id"]) || https_url(value["url"])
          _ -> Enum.find(actor_urls, &peertube_account_url?/1)
        end

      %{
        url: channel_url,
        name:
          if(is_map(group),
            do: first_text(group["name"]) || first_text(group["preferredUsername"])
          ),
        owner_url: owner_url,
        owner_name:
          if(is_map(owner),
            do: first_text(owner["name"]) || first_text(owner["preferredUsername"])
          )
      }
    end
  end

  defp peertube_channel_url?(url), do: url_path_starts_with?(url, "/video-channels/")
  defp peertube_account_url?(url), do: url_path_starts_with?(url, "/accounts/")

  defp url_path_starts_with?(url, prefix) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path}
      when is_binary(host) and is_binary(path) ->
        String.starts_with?(path, prefix)

      _ ->
        false
    end
  rescue
    URI.Error -> false
  end

  defp url_path_starts_with?(_url, _prefix), do: false

  defp hydrate_actor_labels(items) do
    actor_urls =
      items
      |> Enum.flat_map(fn
        %{channel: channel} when is_map(channel) ->
          [channel[:url], channel[:owner_url]]

        _ ->
          []
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    labels =
      if actor_urls == [] do
        %{}
      else
        from(user in User,
          where: user.ap_id in ^actor_urls,
          select: {user.ap_id, user.name, user.nickname}
        )
        |> Repo.all(timeout: @query_timeout)
        |> Map.new(fn {ap_id, name, nickname} ->
          {ap_id, bounded_text(name, 300) || bounded_text(nickname, 300)}
        end)
      end

    Enum.map(items, &hydrate_actor_labels(&1, labels))
  end

  defp hydrate_actor_labels(%{channel: channel} = item, labels) when is_map(channel) do
    channel =
      channel
      |> Map.update!(:name, &(&1 || labels[channel.url]))
      |> Map.update!(:owner_name, &(&1 || labels[channel.owner_url]))

    %{item | channel: channel}
  end

  defp hydrate_actor_labels(item, _labels), do: item

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

  defp scheduled_at(schedules) do
    schedules
    |> List.wrap()
    |> Enum.find_value(fn
      %{"startDate" => value} -> bounded_text(value, 100)
      _ -> nil
    end)
  end

  defp public_reply_capability(data) do
    cond do
      Map.has_key?(data, "canReply") -> data["canReply"] in @public_values
      is_boolean(data["commentsEnabled"]) -> data["commentsEnabled"]
      true -> nil
    end
  end

  defp duration_seconds(value) when is_binary(value) do
    case Regex.run(
           ~r/\APT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?\z/,
           String.trim(value),
           capture: :all_but_first
         ) do
      [hours, minutes, seconds] when hours != "" or minutes != "" or seconds != "" ->
        parse_duration_part(hours, 3_600) +
          parse_duration_part(minutes, 60) +
          parse_duration_part(seconds, 1)

      _ ->
        nil
    end
  end

  defp duration_seconds(_value), do: nil

  defp parse_duration_part("", _multiplier), do: 0

  defp parse_duration_part(value, multiplier) do
    case Float.parse(value) do
      {number, ""} when number >= 0 -> trunc(number * multiplier)
      _ -> 0
    end
  end

  defp identifier_name(value) when is_map(value) do
    first_text(value["name"]) ||
      first_text(value["label"]) ||
      first_text(value["identifier"])
      |> bounded_text(200)
  end

  defp identifier_name(value), do: value |> first_text() |> bounded_text(200)

  defp hashtag_names(tags) do
    tags
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => type, "name" => name} when type in ["Hashtag", "as:Hashtag"] -> [name]
      _ -> []
    end)
    |> Enum.map(&String.trim_leading(&1, "#"))
    |> Enum.map(&bounded_text(&1, 80))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(8)
  end

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
    ["name", "value", "label", "identifier", "href", "id", "url"]
    |> Enum.find_value(&first_text(Map.get(value, &1)))
  end

  defp first_text(value) when is_integer(value) or is_float(value), do: to_string(value)
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

  defp boolean_value(value) when is_boolean(value), do: value
  defp boolean_value(_value), do: nil

  defp nonnegative_integer(value)
       when is_integer(value) and value >= 0 and value <= 10_000_000_000,
       do: value

  defp nonnegative_integer(_value), do: nil

  defp provider_metadata(status) do
    %{
      type: "local_video",
      host: Endpoint.url() |> URI.parse() |> Map.get(:host),
      status: status
    }
  end

  defp map_value(map, key, default) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
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

# end of video_object_discovery.ex
