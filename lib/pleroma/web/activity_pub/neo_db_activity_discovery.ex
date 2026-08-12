# Project: Unfathomably
# File: neodb_activity_discovery.ex
# Purpose: Search public NeoDB cultural activity already received by this server.
#
# Responsibilities:
# - identify NeoDB extended ActivityPub objects by their payload shape
# - search the local object cache through a dedicated PostgreSQL text index
# - expose ratings, collection states, reviews, actors, and catalog metadata
#
# This file intentionally does not fetch remote servers or classify objects by
# hostname. Discovery must reflect federation the instance has actually joined.

defmodule Pleroma.Web.ActivityPub.NeoDBActivityDiscovery do
  @moduledoc """
  Local-first discovery for received NeoDB cultural activity.

  NeoDB represents catalog interactions through `relatedWith` relationships.
  The relationship has a `withRegardTo` catalog reference and typed Rating,
  Review, Status, Comment, or Note records. Requiring that shape avoids
  mistaking ordinary posts from NeoDB-hosted accounts for cultural objects.
  """

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.MediaProxy

  @public "https://www.w3.org/ns/activitystreams#Public"
  @activity_types ~w(Comment Note Rating Review Status)
  @catalog_types ~w(
    Album
    Edition
    Game
    Movie
    Performance
    PerformanceProduction
    Podcast
    PodcastEpisode
    Series
    TVEpisode
    TVSeason
    TVShow
    Work
  )
  @default_limit 12
  @maximum_limit 20
  @maximum_offset 5_000
  @maximum_query_length 200

  @catalog_path ~r{^/(?:edition|book|movie|tv|tvshow|tvseason|tvepisode|album|game|podcast|performance)(?:/|$)}i

  @doc """
  Returns whether a URI identifies a catalog object that can safely receive a
  NeoDB relationship.

  Cached objects are accepted by their concrete vocabulary. An uncached URI is
  accepted only when its host was explicitly configured as a NeoDB index and
  its path has the shape of a catalog item, rather than an account or site root.
  """
  @spec federatable_catalog_uri?(term()) :: boolean()
  def federatable_catalog_uri?(value) when is_binary(value) do
    value = String.trim(value)

    with %URI{scheme: scheme, host: host, userinfo: nil, path: path} <- URI.parse(value),
         true <- scheme in ["http", "https"],
         true <- is_binary(host),
         true <- is_binary(path),
         true <- byte_size(value) <= 2_048,
         true <- Regex.match?(@catalog_path, path) do
      cached_catalog_uri?(value) or received_catalog_uri?(value) or
        configured_neodb_host?(host)
    else
      _ -> false
    end
  rescue
    URI.Error -> false
  end

  def federatable_catalog_uri?(_value), do: false

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query =
      params
      |> Map.get("q", "")
      |> string_value()
      |> String.trim()
      |> String.slice(0, @maximum_query_length)

    limit = bounded_integer(Map.get(params, "limit"), @default_limit, 1, @maximum_limit)
    offset = bounded_integer(Map.get(params, "offset"), 0, 0, @maximum_offset)

    rows =
      if String.length(query) == 1 do
        []
      else
        query
        |> search_query(limit + 1, offset)
        |> Repo.all(timeout: 30_000)
      end

    has_more = length(rows) > limit
    page_rows = Enum.take(rows, limit)
    actor_labels = load_actor_labels(page_rows)

    items =
      page_rows
      |> Enum.map(&normalize_result(&1, actor_labels))
      |> Enum.reject(&is_nil/1)

    %{
      "items" => items,
      "providers" => [
        %{
          "type" => "local_federation_cache",
          "host" => local_host(),
          "status" => "ready"
        }
      ],
      "has_more" => has_more,
      "next_offset" => if(has_more, do: offset + limit, else: nil)
    }
  end

  defp cached_catalog_uri?(value) do
    case Object.get_cached_by_ap_id(value) do
      %Object{data: data} -> Enum.any?(types(data), &(&1 in @catalog_types))
      _object -> false
    end
  end

  # NeoDB normally embeds catalog records in a post's tag array. The catalog
  # URI can therefore be known and safe even when it has not been materialized
  # as a standalone Object row. Use the dedicated partial GIN index to obtain a
  # small candidate set, then require an exact URI match in Elixir. This keeps a
  # create request from falling back to a sequential JSON scan.
  defp received_catalog_uri?(value) do
    Object
    |> where([object], fragment("? \\? 'relatedWith'", object.data))
    |> where(
      [object],
      fragment(
        "unfathomably_neodb_search_document(?) @@ plainto_tsquery('simple', ?)",
        object.data,
        ^value
      )
    )
    |> select([object], object.data)
    |> limit(20)
    |> Repo.all(timeout: 5_000)
    |> Enum.any?(&catalog_reference?(&1, value))
  rescue
    _error -> false
  catch
    _, _ -> false
  end

  defp catalog_reference?(data, value) when is_map(data) do
    tag_match? =
      data
      |> Map.get("tag", [])
      |> List.wrap()
      |> Enum.any?(fn
        %{} = item -> reference_url(item["href"] || item["id"] || item["url"]) == value
        _item -> false
      end)

    relationship_match? =
      data
      |> related_items()
      |> Enum.any?(&(with_regard_to_url(&1) == value))

    tag_match? and relationship_match?
  end

  defp catalog_reference?(_data, _value), do: false

  defp configured_neodb_host?(host) do
    host = String.downcase(host)

    Config.get([:native_discovery, :neodb_indexes], [])
    |> Enum.any?(fn index ->
      case URI.parse(to_string(index)) do
        %URI{host: configured_host} when is_binary(configured_host) ->
          String.downcase(configured_host) == host

        _uri ->
          false
      end
    end)
  end

  defp search_query(query, limit, offset) do
    public_recipient = @public

    Activity
    |> from(as: :activity)
    |> join(:inner, [activity: activity], object in Object,
      as: :object,
      on:
        fragment(
          "(?->>'id') = associated_object_id(?)",
          object.data,
          activity.data
        )
    )
    |> where(
      [activity: activity],
      activity.local == false and fragment("?->>'type' = 'Create'", activity.data)
    )
    |> where([object: object], fragment("? \\? 'relatedWith'", object.data))
    |> where(
      [object: object],
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
      )
    )
    |> maybe_search(query)
    |> order_by([activity: activity], desc: activity.inserted_at, desc: activity.id)
    |> limit(^limit)
    |> offset(^offset)
    |> select([activity: activity, object: object], {activity, object})
  end

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    where(
      query,
      [object: object],
      fragment(
        "unfathomably_neodb_search_document(?) @@ websearch_to_tsquery('simple', ?)",
        object.data,
        ^search
      )
    )
  end

  defp normalize_result({activity, object}, actor_labels) do
    data = object.data || %{}
    related = related_items(data)

    case collection_envelope(related) do
      %{} = collection ->
        normalize_collection(activity, data, collection, related, actor_labels)

      _collection ->
        normalize_catalog_activity(activity, data, related, actor_labels)
    end
  end

  defp normalize_result(_, _actor_labels), do: nil

  defp normalize_catalog_activity(activity, data, related, actor_labels) do
    catalog_tag = catalog_tag(data, related)
    catalog_url = Enum.find_value(related, &with_regard_to_url/1)

    if catalog_tag && catalog_url && Enum.any?(related, &cultural_relationship?/1) do
      actor_url = actor_reference(activity, data, related)
      activitypub_url = reference_url(data["id"])
      source_url = reference_url(data["url"]) || activitypub_url
      rating = relationship_value(related, "Rating", "value")
      rating_best = relationship_value(related, "Rating", "best")
      status = relationship_value(related, "Status", "status")
      catalog_type = first_matching_type(catalog_tag, @catalog_types)
      catalog_name = first_present(catalog_tag, ["name", "title"])
      catalog = catalog_metadata(catalog_tag)

      %{
        "id" => activity.id,
        "family" => "culture",
        "kind" => "neodb_activity",
        "object_type" => first_type(data),
        "title" => discovery_title(data, catalog_name, related),
        "summary" => relationship_summary(data, related),
        "url" => source_url,
        "activitypub_url" => activitypub_url,
        "actor_url" => actor_url,
        "actor_label" => actor_label(data, actor_url, actor_labels),
        "catalog_url" => catalog_url,
        "catalog_type" => catalog_type,
        "catalog_name" => catalog_name,
        "catalog_category" => catalog.category,
        "catalog_description" => catalog.description,
        "catalog_cover_url" => catalog.cover_url,
        "catalog_average_rating" => catalog.average_rating,
        "catalog_rating_count" => catalog.rating_count,
        "catalog_tags" => catalog.tags,
        "catalog_credits" => catalog.credits,
        "catalog_external_resources" => catalog.external_resources,
        "catalog_date" => catalog.date,
        "review_url" => relationship_reference(related, "Review"),
        "rating" => numeric_value(rating),
        "rating_best" => numeric_value(rating_best) || if(rating, do: 10),
        "status" => string_value(status),
        "related_types" => related |> Enum.flat_map(&types/1) |> Enum.uniq(),
        "published_at" => published_at(data, activity),
        "source_host" => source_host(source_url || activitypub_url || actor_url),
        "local_action" => "resolve"
      }
    end
  end

  defp normalize_collection(activity, data, collection, related, actor_labels) do
    collection_url = reference_url(collection["id"]) || reference_url(collection["href"])
    activitypub_url = reference_url(data["id"])
    source_url = reference_url(data["url"]) || activitypub_url
    actor_url = actor_reference(activity, data, related)

    title =
      first_present(collection, ["name", "title"]) ||
        first_present(data, ["name", "title"]) ||
        collection_default_title(collection["shelfType"])

    if collection_url && activitypub_url && source_url && actor_url && title do
      %{
        "id" => activity.id,
        "family" => "culture",
        "kind" => "neodb_collection",
        "object_type" => first_type(data),
        "title" => title,
        "summary" =>
          collection
          |> first_present(["content", "summary"])
          |> plain_text()
          |> truncate(800),
        "url" => source_url,
        "activitypub_url" => activitypub_url,
        "actor_url" => actor_url,
        "actor_label" => actor_label(data, actor_url, actor_labels),
        "collection_url" => collection_url,
        "collection_kind" =>
          if(
            "Shelf" in types(collection) or string_value(collection["shelfType"]) != "",
            do: "shelf",
            else: "collection"
          ),
        "collection_first" => reference_url(collection["first"]),
        "collection_last" => reference_url(collection["last"]),
        "total_items" => nonnegative_integer(collection["totalItems"]),
        "shelf_type" => nullable_string(collection["shelfType"]),
        "collection_query" => nullable_string(collection["query"]),
        "related_types" => related |> Enum.flat_map(&types/1) |> Enum.uniq(),
        "published_at" =>
          nullable_string(collection["published"]) ||
            nullable_string(collection["updated"]) ||
            published_at(data, activity),
        "source_host" => source_host(collection_url),
        "local_action" => "resolve"
      }
    end
  end

  defp collection_envelope(related) do
    Enum.find(related, fn
      %{} = item ->
        Enum.any?(types(item), &(&1 in ["Collection", "Shelf"])) and
          is_binary(reference_url(item["id"]) || reference_url(item["href"])) and
          is_binary(reference_url(item["attributedTo"]))

      _item ->
        false
    end)
  end

  defp collection_default_title(value) when is_binary(value) and value != "" do
    value
    |> String.replace(["_", "-"], " ")
    |> String.capitalize()
    |> Kernel.<>(" shelf")
  end

  defp collection_default_title(_value), do: "Cultural collection"

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value

  defp nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _value -> nil
    end
  end

  defp nonnegative_integer(_value), do: nil

  defp nullable_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp nullable_string(_value), do: nil

  defp related_items(%{"relatedWith" => related}) when is_list(related) do
    Enum.filter(related, &is_map/1)
  end

  defp related_items(%{"relatedWith" => related}) when is_map(related), do: [related]
  defp related_items(_), do: []

  defp load_actor_labels(rows) do
    actor_urls =
      rows
      |> Enum.map(fn {activity, object} ->
        data = object.data || %{}
        actor_reference(activity, data, related_items(data))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(@maximum_limit)

    User
    |> where([user], user.ap_id in ^actor_urls)
    |> select([user], {user.ap_id, user.name, user.nickname})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {ap_id, name, nickname}, labels ->
      label = name |> plain_text() |> truncate(200)
      label = label || clean_string(nickname, 200)

      if label do
        Map.put(labels, ap_id, label)
      else
        labels
      end
    end)
  end

  defp actor_reference(activity, data, related) do
    collection = collection_envelope(related) || %{}

    reference_url(collection["attributedTo"]) ||
      reference_url(data["attributedTo"]) ||
      reference_url(activity.data["actor"])
  end

  defp catalog_tag(data, related) do
    data
    |> Map.get("tag", [])
    |> List.wrap()
    |> Kernel.++(related)
    |> Enum.find(fn
      item when is_map(item) -> Enum.any?(types(item), &(&1 in @catalog_types))
      _ -> false
    end)
  end

  defp catalog_metadata(item) do
    %{
      category: clean_string(item["category"], 40),
      description:
        item
        |> first_present(["description", "brief"])
        |> plain_text()
        |> truncate(1_000),
      cover_url: catalog_cover_url(item["cover_image_url"]),
      average_rating: numeric_value(item["rating"]),
      rating_count: nonnegative_integer(item["rating_count"]),
      tags: catalog_tags(item["tags"]),
      credits: catalog_credits(item["credits"]),
      external_resources: catalog_external_resources(item["external_resources"]),
      date: catalog_date(item)
    }
  end

  defp catalog_cover_url(value) do
    case reference_url(value) do
      url when is_binary(url) -> MediaProxy.browser_url(url)
      _ -> nil
    end
  end

  defp catalog_tags(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        case clean_string(value, 80) do
          nil -> []
          tag -> [tag]
        end

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(12)
  end

  defp catalog_credits(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = credit ->
        name = clean_string(credit["name"], 200)
        role = clean_string(credit["role"], 120)
        character = clean_string(credit["character_name"], 160)
        person_url = reference_url(credit["person_url"])

        if name do
          [
            %{
              "name" => name,
              "role" => role,
              "character_name" => character,
              "person_url" => person_url
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(&{&1["name"], &1["role"], &1["character_name"]})
    |> Enum.take(12)
  end

  defp catalog_external_resources(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = resource ->
        case reference_url(resource["url"]) do
          url when is_binary(url) -> [url]
          _ -> []
        end

      value when is_binary(value) ->
        case reference_url(value) do
          url when is_binary(url) -> [url]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp catalog_date(item) do
    first_present(item, ["release_date", "pub_date", "opening_date"]) ||
      case item["pub_year"] || item["release_year"] || item["year"] do
        value when is_integer(value) and value > 0 -> Integer.to_string(value)
        value when is_binary(value) -> clean_string(value, 40)
        _ -> nil
      end
  end

  defp cultural_relationship?(item) when is_map(item) do
    Enum.any?(types(item), &(&1 in @activity_types)) &&
      is_binary(with_regard_to_url(item))
  end

  defp cultural_relationship?(_), do: false

  defp with_regard_to_url(item) when is_map(item) do
    if Enum.any?(types(item), &(&1 in @activity_types)) do
      reference_url(item["withRegardTo"])
    end
  end

  defp relationship_value(related, type, key) do
    related
    |> Enum.find(fn item -> type in types(item) end)
    |> case do
      item when is_map(item) -> item[key]
      _ -> nil
    end
  end

  defp relationship_reference(related, type) do
    related
    |> Enum.find(fn item -> type in types(item) end)
    |> reference_url()
  end

  defp relationship_summary(data, related) do
    related_text =
      Enum.find_value(related, fn item ->
        if Enum.any?(types(item), &(&1 in ["Review", "Comment", "Note"])) do
          first_present(item, ["content", "summary", "name"])
        end
      end)

    data
    |> first_present(["summary", "content"])
    |> then(&(&1 || related_text))
    |> plain_text()
    |> truncate(800)
  end

  defp discovery_title(data, catalog_name, related) do
    first_present(data, ["name", "title"]) ||
      catalog_name ||
      cond do
        Enum.any?(related, &("Review" in types(&1))) -> "Catalog review"
        Enum.any?(related, &("Rating" in types(&1))) -> "Catalog rating"
        true -> "Catalog activity"
      end
  end

  defp actor_label(data, actor_url, actor_labels) do
    Map.get(actor_labels, actor_url) || embedded_actor_label(data, actor_url)
  end

  defp embedded_actor_label(data, actor_url) do
    actor = data["attributedTo"]

    cond do
      is_map(actor) ->
        first_present(actor, ["name", "preferredUsername"]) || source_host(actor_url)

      true ->
        source_host(actor_url)
    end
  end

  defp first_matching_type(item, allowed) do
    Enum.find(types(item), &(&1 in allowed))
  end

  defp first_type(item) do
    item
    |> types()
    |> List.first()
  end

  defp types(%{"type" => value}) when is_binary(value), do: [value]
  defp types(%{"type" => value}) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp types(_), do: []

  defp first_present(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case map[key] do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: nil, else: value

        _ ->
          nil
      end
    end)
  end

  defp first_present(_, _), do: nil

  defp clean_string(value, maximum) when is_binary(value) do
    value =
      value
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, maximum)

    if value == "", do: nil, else: value
  end

  defp clean_string(_, _), do: nil

  defp reference_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and byte_size(value) <= 2_048 ->
        URI.to_string(uri)

      _ ->
        nil
    end
  end

  defp reference_url(%{"id" => value}), do: reference_url(value)
  defp reference_url(%{"href" => value}), do: reference_url(value)
  defp reference_url(%{"url" => value}), do: reference_url(value)

  defp reference_url(values) when is_list(values) do
    Enum.find_value(values, &reference_url/1)
  end

  defp reference_url(_), do: nil

  defp numeric_value(value) when is_integer(value) or is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp numeric_value(_), do: nil

  defp plain_text(value) when is_binary(value) do
    value
    |> Pleroma.HTML.strip_non_content()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp plain_text(_), do: nil

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

# end of neodb_activity_discovery.ex
