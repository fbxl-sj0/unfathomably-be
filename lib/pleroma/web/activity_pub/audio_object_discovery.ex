# Project: Unfathomably
# File: audio_object_discovery.ex
# Purpose: Search public Audio objects already received through federation.
#
# Responsibilities:
# - search the local object cache through a dedicated PostgreSQL text index
# - preserve useful Funkwhale and generic ActivityStreams audio metadata
# - expose safe source, actor, and local-resolution actions
#
# This file intentionally does not fetch, proxy, autoplay, or inspect remote
# media. It only describes objects accepted by the normal federation pipeline.

defmodule Pleroma.Web.ActivityPub.AudioObjectDiscovery do
  @moduledoc """
  Local-first discovery for received ActivityStreams Audio objects.

  Funkwhale Track objects are normalized to Audio by the inbound validator
  while retaining artist, album, attachment, and attribution metadata. The
  query deliberately uses object shape rather than server names so compatible
  audio publishers receive the same treatment.
  """

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo

  @public "https://www.w3.org/ns/activitystreams#Public"
  @default_limit 12
  @maximum_limit 20
  @maximum_offset 5_000

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query = params |> Map.get("q", "") |> string_value() |> String.trim()
    limit = bounded_integer(Map.get(params, "limit"), @default_limit, 1, @maximum_limit)
    offset = bounded_integer(Map.get(params, "offset"), 0, 0, @maximum_offset)

    normalized_items =
      cond do
        query == "" ->
          query
          |> discovery_query(limit + 1, offset)
          |> Repo.all(timeout: 30_000)
          |> Enum.map(&normalize_result/1)
          |> Enum.reject(&is_nil/1)

        String.length(query) >= 2 ->
          query
          |> discovery_query(limit + 1, offset)
          |> Repo.all(timeout: 30_000)
          |> Enum.map(&normalize_result/1)
          |> Enum.reject(&is_nil/1)

        true ->
          []
      end

    items = Enum.take(normalized_items, limit)
    has_more = length(normalized_items) > limit

    %{
      "items" => items,
      "has_more" => has_more,
      "next_offset" => if(has_more, do: offset + limit),
      "providers" => [
        %{
          "type" => "local_federation_cache",
          "host" => local_host(),
          "status" => "ready"
        }
      ]
    }
  end

  defp discovery_query(query, limit, offset) do
    public_recipient = @public

    # Audio is rare compared with the global remote Create stream. Starting
    # from the native-family recency index avoids scanning unrelated posts
    # while the Activity join still supplies the local status identifier.
    base_query =
      from(object in Object,
        join: activity in Activity,
        on:
          fragment(
            "(?->>'id') = associated_object_id(?)",
            object.data,
            activity.data
          ),
        where: fragment("unfathomably_native_discoverable(?)", object.data),
        where: fragment("unfathomably_native_feed_eligible(?)", object.data),
        where: fragment("unfathomably_native_family(?) = 'audio'", object.data),
        where: activity.local == false,
        where: fragment("?->>'type' = 'Create'", activity.data),
        where: fragment("?->>'type' = 'Audio'", object.data),
        where:
          fragment(
            """
            jsonb_exists(coalesce(?->'to', '[]'::jsonb), ?) OR
            jsonb_exists(coalesce(?->'cc', '[]'::jsonb), ?) OR
            ?->>'to' = ? OR
            ?->>'cc' = ?
            """,
            object.data,
            ^public_recipient,
            object.data,
            ^public_recipient,
            object.data,
            ^@public,
            object.data,
            ^@public
          ),
        # A remote object can have several legacy or idless Create envelopes.
        # Keep the newest local envelope for each canonical object so discovery
        # cards and look-ahead pagination remain stable.
        distinct: [desc: object.id],
        order_by: [desc: object.id, desc: activity.id],
        limit: ^limit,
        offset: ^offset,
        select: {activity, object}
      )

    if query == "" do
      base_query
    else
      from([object, _activity] in base_query,
        where:
          fragment(
            "unfathomably_audio_search_document(?) @@ websearch_to_tsquery('simple', ?)",
            object.data,
            ^query
          )
      )
    end
  end

  defp normalize_result({activity, object}) do
    data = object.data || %{}
    track = if is_map(data["track"]), do: data["track"], else: %{}

    album =
      if is_map(data["album"]) do
        data["album"]
      else
        if is_map(track["album"]), do: track["album"], else: %{}
      end

    artist_credit =
      data["artist_credit"] || track["artist_credit"] || data["artist"] || track["artist"]

    title = first_present(data, ["name", "title"]) || title_from_content(data["content"])
    activitypub_url = reference_url(data["id"])
    source_url = reference_url(data["url"]) || activitypub_url
    actor_url = reference_url(data["attributedTo"]) || reference_url(activity.data["actor"])

    audio_reference =
      first_audio_reference(data["attachment"]) ||
        first_audio_reference(data["url"])

    if title && activitypub_url && source_url do
      %{
        "id" => activity.id,
        "status_id" => activity.id,
        "family" => "audio",
        "kind" => "received_audio",
        "title" => title,
        "summary" => summary(data, title),
        "url" => source_url,
        "activitypub_url" => activitypub_url,
        "actor_url" => actor_url,
        "actor_label" => actor_label(data, actor_url),
        "artist" => artist_label(artist_credit),
        "artist_url" => artist_reference_url(artist_credit),
        "artist_image_url" =>
          artist_credit |> artist_cover_url() |> Pleroma.Web.MediaProxy.browser_url(),
        "album" => album_label(album),
        "album_url" => reference_url(album["id"]),
        "track_url" => reference_url(track["id"]),
        "library_url" => reference_url(data["library"]),
        "image_url" =>
          data
          |> image_url(track, album, artist_credit)
          |> Pleroma.Web.MediaProxy.browser_url(),
        "media_url" => reference_url(audio_reference),
        "media_type" => attachment_media_type(audio_reference),
        "duration" => duration_value(data, audio_reference),
        "licence" => licence_label(data["license"] || data["licence"]),
        "tags" => audio_tags(data, track, album),
        "content_category" => content_category(data, track),
        "platform_hint" => platform_hint(data),
        "published_at" => published_at(data, activity),
        "source_host" => source_host(source_url),
        "local_action" => "resolve"
      }
    end
  end

  defp normalize_result(_), do: nil

  defp first_audio_reference(references) do
    references
    |> List.wrap()
    |> Enum.find(fn
      %{"mediaType" => media_type} when is_binary(media_type) ->
        String.starts_with?(String.downcase(media_type), "audio/")

      %{"type" => "Audio"} ->
        true

      _ ->
        false
    end)
  end

  defp attachment_media_type(%{"mediaType" => media_type}) when is_binary(media_type),
    do: media_type

  defp attachment_media_type(_), do: nil

  defp duration_value(data, attachment) do
    value =
      data["duration"] ||
        if(is_map(attachment), do: attachment["duration"])

    case value do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_integer(value) and value >= 0 ->
        Integer.to_string(value)

      value when is_float(value) and value >= 0 ->
        Float.to_string(value)

      _ ->
        nil
    end
  end

  defp artist_label(value) when is_binary(value), do: clean_text(value, 300)

  defp artist_label(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{"artist" => artist} when is_map(artist) ->
        first_present(artist, ["name", "preferredUsername"])

      %{"name" => name} when is_binary(name) ->
        clean_text(name, 200)

      value when is_binary(value) ->
        clean_text(value, 200)

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(", ")
    |> blank_to_nil()
  end

  defp artist_label(value) when is_map(value) do
    first_present(value, ["name", "title"])
  end

  defp artist_label(_), do: nil

  defp artist_reference_url(values) when is_list(values) do
    Enum.find_value(values, &artist_reference_url/1)
  end

  defp artist_reference_url(%{"artist" => artist}) do
    reference_url(artist)
  end

  defp artist_reference_url(value) when is_map(value) do
    reference_url(value)
  end

  defp artist_reference_url(value) when is_binary(value), do: reference_url(value)
  defp artist_reference_url(_), do: nil

  defp album_label(value) when is_binary(value), do: clean_text(value, 300)
  defp album_label(value) when is_map(value), do: first_present(value, ["name", "title"])
  defp album_label(_), do: nil

  defp image_url(data, track, album, artist_credit) do
    reference_url(data["image"]) ||
      reference_url(data["icon"]) ||
      reference_url(track["image"]) ||
      reference_url(track["icon"]) ||
      album_image_url(album) ||
      artist_cover_url(artist_credit)
  end

  defp album_image_url(album) when is_map(album) do
    reference_url(album["image"]) || reference_url(album["cover"])
  end

  defp album_image_url(_), do: nil

  defp artist_cover_url(values) when is_list(values) do
    values
    |> Enum.take(32)
    |> Enum.find_value(&artist_cover_url/1)
  end

  defp artist_cover_url(%{"artist" => artist}) when is_map(artist),
    do: artist_cover_url(artist)

  defp artist_cover_url(artist) when is_map(artist) do
    cover_reference(artist["cover"]) ||
      cover_reference(artist["attachment_cover"]) ||
      cover_reference(artist["image"]) ||
      cover_reference(artist["icon"])
  end

  defp artist_cover_url(_artist), do: nil

  # Funkwhale cover serializers expose a bounded set of generated URLs rather
  # than an ActivityStreams Link. Prefer the original and common display sizes,
  # then accept the first ordinary URL for forward-compatible size labels.
  defp cover_reference(%{"urls" => urls}) when is_map(urls) do
    Enum.find_value(["original", "large", "medium", "small", "square"], fn key ->
      reference_url(urls[key])
    end) ||
      urls
      |> Map.values()
      |> Enum.take(16)
      |> Enum.find_value(&reference_url/1)
  end

  defp cover_reference(value), do: reference_url(value)

  defp licence_label(value) when is_binary(value), do: clean_text(value, 200)

  defp licence_label(value) when is_map(value) do
    first_present(value, ["full_name", "name", "code", "url"])
  end

  defp licence_label(_), do: nil

  defp hashtag_names(tags) do
    tags
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "Hashtag", "name" => name} when is_binary(name) ->
        [name |> String.trim_leading("#") |> clean_text(80)]

      %{"name" => name} when is_binary(name) ->
        [name |> String.trim_leading("#") |> clean_text(80)]

      name when is_binary(name) ->
        [name |> String.trim_leading("#") |> clean_text(80)]

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(12)
  end

  defp audio_tags(data, track, album) do
    [data, track, album]
    |> Enum.flat_map(fn metadata ->
      hashtag_names(metadata["tag"]) ++
        taxonomy_names([
          metadata["genre"],
          metadata["genres"],
          metadata["category"],
          metadata["categories"],
          metadata["content_category"],
          metadata["contentCategory"]
        ])
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(12)
  end

  defp taxonomy_names(values) when is_list(values) do
    Enum.flat_map(values, &taxonomy_names/1)
  end

  defp taxonomy_names(value) when is_binary(value) do
    case clean_text(value, 80) do
      nil -> []
      value -> [value]
    end
  end

  defp taxonomy_names(value) when is_map(value) do
    case first_present(value, ["name", "label", "title", "term"]) do
      nil -> []
      value -> [value]
    end
  end

  defp taxonomy_names(_), do: []

  defp content_category(data, track) do
    first_present(data, ["content_category", "contentCategory"]) ||
      first_present(track, ["content_category", "contentCategory"])
  end

  defp platform_hint(data) do
    if Map.has_key?(data, "artist_credit") or is_map(data["album"]) do
      "funkwhale"
    else
      "activitypub_audio"
    end
  end

  defp summary(data, title) do
    value = first_present(data, ["summary", "content"])

    case plain_text(value) do
      ^title -> nil
      summary -> truncate(summary, 800)
    end
  end

  defp title_from_content(value) do
    value
    |> plain_text()
    |> truncate(300)
  end

  defp actor_label(data, actor_url) do
    actor = data["attributedTo"]

    if is_map(actor) do
      first_present(actor, ["name", "preferredUsername"]) || source_host(actor_url)
    else
      source_host(actor_url)
    end
  end

  defp first_present(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case map[key] do
        value when is_binary(value) -> clean_text(value, 500)
        _ -> nil
      end
    end)
  end

  defp first_present(_, _), do: nil

  defp reference_url(value) when is_binary(value) do
    value = String.trim(value)
    if String.starts_with?(value, ["http://", "https://"]), do: value
  end

  defp reference_url(%{"url" => value}), do: reference_url(value)
  defp reference_url(%{"href" => value}), do: reference_url(value)
  defp reference_url(%{"id" => value}), do: reference_url(value)

  defp reference_url(values) when is_list(values) do
    Enum.find_value(values, &reference_url/1)
  end

  defp reference_url(_), do: nil

  defp plain_text(value) when is_binary(value) do
    value
    |> Pleroma.HTML.strip_non_content()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> blank_to_nil()
  end

  defp plain_text(_), do: nil

  defp clean_text(value, maximum) when is_binary(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(maximum)
    |> blank_to_nil()
  end

  defp clean_text(_, _), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp truncate(nil, _maximum), do: nil
  defp truncate(value, maximum) when byte_size(value) <= maximum, do: value

  defp truncate(value, maximum) do
    value
    |> String.slice(0, maximum)
    |> Kernel.<>("...")
  end

  defp published_at(%{"published" => published}, _activity) when is_binary(published),
    do: published

  defp published_at(_data, %{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_iso8601(inserted_at)

  defp published_at(_data, %{inserted_at: %NaiveDateTime{} = inserted_at}),
    do: NaiveDateTime.to_iso8601(inserted_at)

  defp published_at(_data, _activity), do: nil

  defp source_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end

  defp source_host(_), do: nil

  defp bounded_integer(value, default, minimum, maximum) do
    parsed =
      case value do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
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

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_), do: ""

  defp local_host do
    Config.get([Pleroma.Web.Endpoint, :url, :host], "local")
  end
end

# end of audio_object_discovery.ex
