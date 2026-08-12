# Project: Unfathomably
# File: music_catalog_discovery.ex
# Purpose: Search durable public music-catalog objects received by this server.
#
# Responsibilities:
# - identify Artist, Album, Library, and Playlist objects by protocol shape
# - search the local object cache through a dedicated PostgreSQL text index
# - expose ownership, collection, artwork, count, and release metadata
#
# This file intentionally excludes transient AudioCollection bulk-update
# envelopes and never crawls remote collection pages.

defmodule Pleroma.Web.ActivityPub.MusicCatalogDiscovery do
  @moduledoc """
  Local-first discovery for durable Funkwhale-style music catalog objects.

  Funkwhale publishes artists and albums with MusicBrainz-oriented metadata,
  libraries as actor/collection hybrids, and playlists as ordered collections.
  Structural checks keep unrelated objects with generic names out of the audio
  surface without relying on domain-name guesses.
  """

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo

  @public "https://www.w3.org/ns/activitystreams#Public"
  @default_limit 12
  @maximum_limit 20
  @maximum_offset 1_000
  @musicbrainz_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query = params |> Map.get("q", "") |> string_value() |> String.trim()
    limit = bounded_integer(Map.get(params, "limit"), @default_limit, 1, @maximum_limit)
    offset = bounded_integer(Map.get(params, "offset"), 0, 0, @maximum_offset)

    results =
      cond do
        query == "" ->
          browse_query(limit + 1, offset)

        String.length(query) >= 2 ->
          search_query(query, limit + 1, offset)

        true ->
          nil
      end

    normalized =
      if results do
        results
        |> Repo.all(timeout: 30_000)
        |> Enum.map(&normalize_result/1)
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    items = Enum.take(normalized, limit)
    has_more = length(normalized) > limit

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

  defp browse_query(limit, offset) do
    public_recipient = @public

    from(activity in Activity,
      join: object in Object,
      on:
        fragment(
          "(?->>'id') = associated_object_id(?)",
          object.data,
          activity.data
        ),
      where: activity.local == false,
      where: fragment("?->>'type' = 'Create'", activity.data),
      where:
        fragment(
          "?->>'type' IN ('Artist', 'Album', 'Library', 'Playlist')",
          object.data
        ),
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
      order_by: [desc: activity.inserted_at, desc: activity.id],
      limit: ^limit,
      offset: ^offset,
      select: {activity, object}
    )
  end

  defp search_query(query, limit, offset) do
    public_recipient = @public

    from(activity in Activity,
      join: object in Object,
      on:
        fragment(
          "(?->>'id') = associated_object_id(?)",
          object.data,
          activity.data
        ),
      where: activity.local == false,
      where: fragment("?->>'type' = 'Create'", activity.data),
      where:
        fragment(
          "?->>'type' IN ('Artist', 'Album', 'Library', 'Playlist')",
          object.data
        ),
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
      where:
        fragment(
          "unfathomably_music_catalog_search_document(?) @@ websearch_to_tsquery('simple', ?)",
          object.data,
          ^query
        ),
      order_by: [desc: activity.inserted_at, desc: activity.id],
      limit: ^limit,
      offset: ^offset,
      select: {activity, object}
    )
  end

  defp normalize_result({activity, object}) do
    data = object.data || %{}
    type = data["type"]

    if durable_music_object?(type, data) do
      activitypub_url = reference_url(data["id"])
      source_url = reference_url(data["url"]) || activitypub_url
      actor_url = reference_url(data["attributedTo"]) || reference_url(activity.data["actor"])
      title = first_present(data, ["name", "title"])

      if activitypub_url && source_url && title do
        %{
          "id" => activity.id,
          "family" => "audio",
          "kind" => music_kind(type),
          "title" => title,
          "summary" =>
            data |> first_present(["summary", "content"]) |> plain_text() |> truncate(800),
          "url" => source_url,
          "activitypub_url" => activitypub_url,
          "actor_url" => actor_url,
          "actor_label" => actor_label(data, actor_url),
          "image_url" => data |> image_url() |> Pleroma.Web.MediaProxy.browser_url(),
          "artist" => artist_label(data["artist_credit"]),
          "artist_url" => artist_url(data["artist_credit"]),
          "released" => first_present(data, ["released", "release_date"]),
          "musicbrainz_id" => first_present(data, ["musicbrainzId", "musicbrainz_id"]),
          "musicbrainz_url" =>
            musicbrainz_url(type, first_present(data, ["musicbrainzId", "musicbrainz_id"])),
          "total_items" => non_negative_integer(data["totalItems"]),
          "first_page" => reference_url(data["first"]),
          "last_page" => reference_url(data["last"]),
          "current_page" => reference_url(data["current"]),
          "followers_url" => reference_url(data["followers"]),
          "published_at" => published_at(data, activity),
          "source_host" => source_host(source_url),
          "local_action" => "resolve"
        }
      end
    end
  end

  defp normalize_result(_), do: nil

  defp durable_music_object?("Artist", data) do
    musicbrainz_shape?(data) or funkwhale_context?(data)
  end

  defp durable_music_object?("Album", data) do
    musicbrainz_shape?(data) or
      Map.has_key?(data, "artist_credit") or
      Map.has_key?(data, "cover") or
      funkwhale_context?(data)
  end

  defp durable_music_object?("Library", data) do
    is_binary(reference_url(data["followers"])) and
      is_binary(reference_url(data["first"])) and
      is_integer(non_negative_integer(data["totalItems"]))
  end

  defp durable_music_object?("Playlist", data) do
    is_binary(reference_url(data["first"])) and
      is_binary(reference_url(data["last"])) and
      is_integer(non_negative_integer(data["totalItems"]))
  end

  defp durable_music_object?(_, _), do: false

  defp musicbrainz_shape?(data) do
    is_binary(first_present(data, ["musicbrainzId", "musicbrainz_id"]))
  end

  defp funkwhale_context?(data) do
    data
    |> Map.get("@context", [])
    |> List.wrap()
    |> Enum.any?(fn
      value when is_binary(value) ->
        String.starts_with?(value, "https://funkwhale.audio/ns")

      value when is_map(value) ->
        value
        |> Map.values()
        |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "funkwhale.audio/ns")))

      _ ->
        false
    end)
  end

  defp music_kind("Artist"), do: "artist"
  defp music_kind("Album"), do: "album"
  defp music_kind("Library"), do: "library"
  defp music_kind("Playlist"), do: "playlist"

  defp image_url(data) do
    reference_url(data["image"]) ||
      reference_url(data["icon"]) ||
      reference_url(data["cover"])
  end

  defp artist_label(value) when is_binary(value), do: clean_text(value, 300)

  defp artist_label(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{"credit" => credit} when is_binary(credit) ->
        clean_text(credit, 200)

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

  defp artist_label(_), do: nil

  defp artist_url(values) when is_list(values) do
    Enum.find_value(values, fn
      %{"artist" => artist} -> reference_url(artist)
      _ -> nil
    end)
  end

  defp artist_url(%{"artist" => artist}), do: reference_url(artist)
  defp artist_url(_), do: nil

  defp musicbrainz_url(type, identifier)
       when type in ["Artist", "Album"] and is_binary(identifier) do
    if Regex.match?(@musicbrainz_uuid, identifier) do
      entity = if(type == "Artist", do: "artist", else: "release")
      "https://musicbrainz.org/#{entity}/#{String.downcase(identifier)}"
    end
  end

  defp musicbrainz_url(_, _), do: nil

  defp actor_label(data, actor_url) do
    actor = data["attributedTo"]

    if is_map(actor) do
      first_present(actor, ["name", "preferredUsername"]) || source_host(actor_url)
    else
      source_host(actor_url)
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp non_negative_integer(_), do: nil

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

    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) ->
        value

      _ ->
        nil
    end
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

  defp clean_text(value, maximum) do
    if is_binary(value) do
      value
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> truncate(maximum)
      |> blank_to_nil()
    end
  end

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

# end of music_catalog_discovery.ex
