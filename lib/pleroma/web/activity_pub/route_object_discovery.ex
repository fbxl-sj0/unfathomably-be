# Project: Unfathomably
# File: route_object_discovery.ex
# Purpose: Search public Wanderer trails already received through federation.
#
# Responsibilities:
# - preselect received Note objects with canonical Wanderer trail shapes
# - reuse CustomObject's structural classification and metadata extraction
# - expose route, author, map, GPX, source, and local-resolution information
#
# This file intentionally does not fetch GPX files, query remote recommendation
# endpoints, infer route software from hostnames, or expose private routes.

defmodule Pleroma.Web.ActivityPub.RouteObjectDiscovery do
  @moduledoc """
  Local-first discovery for received Wanderer trails.

  Wanderer deliberately represents trails, lists, comments, and summit logs as
  `Note` objects. A trail is therefore accepted here only when its canonical
  path and structured GPX, Place, or distance metadata also pass the existing
  `CustomObject.presentation/1` classifier.
  """

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.MediaProxy

  @public "https://www.w3.org/ns/activitystreams#Public"
  @default_limit 12
  @maximum_limit 20
  @maximum_offset 5_000

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query = params |> Map.get("q", "") |> string_value() |> String.trim()
    limit = bounded_integer(Map.get(params, "limit"), @default_limit, 1, @maximum_limit)
    offset = bounded_integer(Map.get(params, "offset"), 0, 0, @maximum_offset)

    normalized =
      if query == "" or String.length(query) >= 2 do
        query
        |> search_query(limit + 1, offset)
        |> Repo.all(timeout: 30_000)
        |> Enum.map(&normalize_result/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1["activitypub_url"])
        |> hydrate_authors()
      else
        []
      end

    has_more = length(normalized) > limit

    %{
      "items" => Enum.take(normalized, limit),
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

  defp search_query(query, limit, offset) do
    public_recipient = @public

    base_query =
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
        where: fragment("?->>'type' = 'Note'", object.data),
        where:
          fragment(
            """
            ?->>'id' ~ '/api/v1/trail/[^/]+$' AND (
              position('application/xml+gpx' in coalesce((?->'attachment')::text, '')) > 0 OR
              position('application/gpx+xml' in coalesce((?->'attachment')::text, '')) > 0 OR
              ?->'location'->>'type' = 'Place' OR
              position('"name": "distance"' in coalesce((?->'tag')::text, '')) > 0
            )
            """,
            object.data,
            object.data,
            object.data,
            object.data,
            object.data
          ),
        where:
          fragment(
            """
            jsonb_exists(coalesce(?->'to', '[]'::jsonb), ?) OR
            jsonb_exists(coalesce(?->'cc', '[]'::jsonb), ?) OR
            ?->>'to' = ? OR
            ?->>'cc' = ? OR
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
            ^@public,
            activity.data,
            ^public_recipient,
            activity.data,
            ^public_recipient,
            activity.data,
            ^@public,
            activity.data,
            ^@public
          ),
        order_by: [desc: activity.inserted_at, desc: activity.id],
        limit: ^limit,
        offset: ^offset,
        select: {activity, object}
      )

    if query == "" do
      base_query
    else
      from([_activity, object] in base_query,
        where:
          fragment(
            "unfathomably_route_search_document(?) @@ websearch_to_tsquery('simple', ?)",
            object.data,
            ^query
          )
      )
    end
  end

  defp normalize_result({activity, object}) do
    data = object.data || %{}

    with %{fields: fields} <- CustomObject.presentation(data),
         "wanderer" <- fields[:platform],
         "trail" <- fields[:route_kind],
         title when is_binary(title) <- clean_text(data["name"], 300),
         activitypub_url when is_binary(activitypub_url) <- reference_url(data["id"]) do
      source_url = reference_url(data["url"]) || activitypub_url
      actor = data["attributedTo"] || data["actor"] || activity.data["actor"]
      actor_url = reference_url(actor)
      latitude = coordinate(fields[:latitude], -90.0, 90.0)
      longitude = coordinate(fields[:longitude], -180.0, 180.0)
      gpx_url = reference_url(fields[:gpx_url])

      %{
        "id" => activity.id,
        "family" => "route",
        "kind" => "trail",
        "title" => title,
        "summary" =>
          data |> first_present(["summary", "content"]) |> plain_text() |> truncate(900),
        "url" => source_url,
        "activitypub_url" => activitypub_url,
        "source_url" => source_url,
        "source_host" => source_host(source_url),
        "image_url" => image_url(data),
        "gpx_url" => gpx_url,
        "gpx_host" => source_host(gpx_url),
        "author" => actor_label(actor, actor_url),
        "author_url" => actor_url,
        "author_handle" => nil,
        "category" => scalar(fields[:category]),
        "difficulty" => scalar(fields[:difficulty]),
        "location" => scalar(fields[:location]),
        "latitude" => latitude,
        "longitude" => longitude,
        "route_point_kind" => if(latitude && longitude, do: "start"),
        "distance" => measurement_in_metres(fields[:distance]),
        "duration" => wanderer_duration_in_seconds(fields[:duration]),
        "duration_unit" => "seconds",
        "elevation_gain" => measurement_in_metres(fields[:elevation_gain]),
        "elevation_loss" => measurement_in_metres(fields[:elevation_loss]),
        "start_time" => scalar_string(fields[:start_time]),
        "published_at" => scalar_string(data["published"]),
        "tags" => wanderer_tags(data["tag"]),
        "local_action" => "resolve"
      }
    else
      _ -> nil
    end
  end

  defp normalize_result(_), do: nil

  defp hydrate_authors([]), do: []

  defp hydrate_authors(items) do
    author_urls =
      items
      |> Enum.map(& &1["author_url"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    authors =
      if author_urls == [] do
        %{}
      else
        User
        |> where([user], user.ap_id in ^author_urls and user.local == false)
        |> Repo.all()
        |> Map.new(&{&1.ap_id, &1})
      end

    Enum.map(items, fn item ->
      case authors[item["author_url"]] do
        %User{} = author ->
          item
          |> Map.put("author", clean_text(author.name, 300) || item["author"])
          |> Map.put("author_handle", author_handle(author))

        _ ->
          item
      end
    end)
  end

  defp author_handle(%User{} = user) do
    case User.full_nickname(user) do
      nickname when is_binary(nickname) and nickname != "" ->
        "@" <> String.trim_leading(nickname, "@")

      _ ->
        nil
    end
  end

  defp image_url(data) do
    data
    |> first_image()
    |> then(fn
      url when is_binary(url) -> MediaProxy.browser_url(url)
      _ -> nil
    end)
  end

  defp first_image(data) do
    reference_url(data["image"]) ||
      reference_url(data["icon"]) ||
      attachment_image(data["attachment"])
  end

  defp attachment_image(attachments) do
    attachments
    |> List.wrap()
    |> Enum.find_value(fn
      %{"mediaType" => media_type} = attachment when is_binary(media_type) ->
        if String.starts_with?(String.downcase(media_type), "image/") do
          reference_url(attachment)
        end

      %{"type" => "Image"} = attachment ->
        reference_url(attachment)

      _ ->
        nil
    end)
  end

  defp actor_label(actor, actor_url) when is_map(actor) do
    first_present(actor, ["name", "preferredUsername"]) || actor_label(nil, actor_url)
  end

  defp actor_label(_actor, actor_url) when is_binary(actor_url) do
    case URI.parse(actor_url) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        username = path |> String.split("/", trim: true) |> List.last()
        if username, do: "@#{username}@#{String.downcase(host)}", else: String.downcase(host)

      _ ->
        source_host(actor_url)
    end
  end

  defp actor_label(_actor, _actor_url), do: nil

  defp wanderer_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "Note", "name" => "tag", "content" => content}
      when is_binary(content) ->
        [clean_text(content, 80)]

      %{"type" => "Hashtag", "name" => name} when is_binary(name) ->
        [name |> String.trim_leading("#") |> clean_text(80)]

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(12)
  end

  defp measurement_in_metres(value) when is_integer(value) or is_float(value) do
    if value >= 0, do: value
  end

  defp measurement_in_metres(value) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      String.ends_with?(String.downcase(normalized), "km") ->
        normalized
        |> String.slice(0, max(String.length(normalized) - 2, 0))
        |> parse_non_negative_number()
        |> multiply_number(1_000)

      String.ends_with?(String.downcase(normalized), "m") ->
        normalized
        |> String.slice(0, max(String.length(normalized) - 1, 0))
        |> parse_non_negative_number()

      true ->
        parse_non_negative_number(normalized)
    end
  end

  defp measurement_in_metres(_), do: nil

  # Wanderer stores trail duration in seconds. Its current ActivityPub
  # serializer appends the same "m" suffix used for metre measurements, so the
  # suffix cannot be interpreted as a duration unit.
  defp wanderer_duration_in_seconds(value)
       when (is_integer(value) or is_float(value)) and value >= 0,
       do: value

  defp wanderer_duration_in_seconds(value) when is_binary(value) do
    normalized = String.trim(value)

    normalized =
      if String.ends_with?(String.downcase(normalized), ["m", "s"]) do
        String.slice(normalized, 0, max(String.length(normalized) - 1, 0))
      else
        normalized
      end

    parse_non_negative_number(normalized)
  end

  defp wanderer_duration_in_seconds(_), do: nil

  defp multiply_number(nil, _factor), do: nil
  defp multiply_number(number, factor), do: number * factor

  defp parse_non_negative_number(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp coordinate(value, minimum, maximum) do
    number =
      cond do
        is_integer(value) or is_float(value) ->
          value * 1.0

        is_binary(value) ->
          case Float.parse(String.trim(value)) do
            {parsed, ""} -> parsed
            _ -> nil
          end

        true ->
          nil
      end

    if is_number(number) and number >= minimum and number <= maximum, do: number
  end

  defp scalar(value) when is_binary(value), do: clean_text(value, 500)
  defp scalar(_), do: nil

  defp scalar_string(value) when is_binary(value), do: clean_text(value, 120)
  defp scalar_string(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar_string(value) when is_float(value), do: Float.to_string(value)
  defp scalar_string(_), do: nil

  defp first_present(map, keys) do
    if is_map(map) do
      Enum.find_value(keys, fn key ->
        case map[key] do
          value when is_binary(value) -> clean_text(value, 1_500)
          _ -> nil
        end
      end)
    end
  end

  defp reference_url(value) when is_binary(value) do
    value = String.trim(value)

    with true <- byte_size(value) <= 2_048,
         %URI{scheme: scheme, host: host, userinfo: nil} <- URI.parse(value),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "" do
      value
    else
      _ -> nil
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

# end of route_object_discovery.ex
