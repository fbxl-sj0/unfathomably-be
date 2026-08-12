# Project: Unfathomably
# File: manyfold_actor_discovery.ex
# Purpose: Search Manyfold actors already received through federation.
#
# Responsibilities:
# - identify models, creators, and collections from f3di concrete types
# - preserve preview, licence, attribution, collection, tag, and link metadata
# - hydrate locally known creator and collection relationships in one query
# - expose stable actor identifiers for deliberate local resolution
#
# This file intentionally does not infer Manyfold from hostnames, fetch model
# binaries, query remote catalogues, or surface compatibility Notes as models.

defmodule Pleroma.Web.ActivityPub.ManyfoldActorDiscovery do
  @moduledoc """
  Local-first discovery for known Manyfold-compatible actors.

  Manyfold models are `Service` actors identified by
  `f3di:concreteType: "3DModel"`. Creators and collections use the same
  extension with `Creator` and `Collection`. This structural marker is the
  discovery boundary, not a hostname or profile description.
  """

  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.MediaProxy

  @concrete_types ~w[3DModel Collection Creator]
  @default_limit 18
  @maximum_limit 30
  @maximum_offset 5_000

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query = params |> Map.get("q", "") |> string_value() |> String.trim()
    limit = bounded_integer(Map.get(params, "limit"), @default_limit, 1, @maximum_limit)
    offset = bounded_integer(Map.get(params, "offset"), 0, 0, @maximum_offset)

    items =
      if query == "" or String.length(query) >= 2 do
        actors =
          query
          |> search_query(limit + 1, offset)
          |> Repo.all(timeout: 30_000)

        items =
          actors
          |> Enum.map(&normalize_actor/1)
          |> Enum.reject(&is_nil/1)

        relations = related_actor_map(items)
        Enum.map(items, &hydrate_relations(&1, relations))
      else
        []
      end

    has_more = length(items) > limit

    %{
      "items" => Enum.take(items, limit),
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
    base_query =
      from(user in User,
        where: user.local == false,
        where: user.is_active == true,
        where: user.invisible == false,
        where:
          fragment(
            """
            coalesce(
              ?->>'f3di:concreteType',
              ?->>'concreteType',
              ?->>'http://purl.org/f3di/ns#concreteType'
            ) IN ('3DModel', 'Collection', 'Creator')
            """,
            user.actor_extensions,
            user.actor_extensions,
            user.actor_extensions
          ),
        order_by: [desc: user.updated_at, desc: user.id],
        limit: ^limit,
        offset: ^offset
      )

    if query == "" do
      base_query
    else
      from(user in base_query,
        where:
          fragment(
            """
            unfathomably_manyfold_actor_search_document(
              ?, ?, ?, ?, ?
            ) @@ websearch_to_tsquery('simple', ?)
            """,
            user.nickname,
            user.name,
            user.bio,
            user.ap_id,
            user.actor_extensions,
            ^query
          )
      )
    end
  end

  defp normalize_actor(%User{} = user) do
    extensions = user.actor_extensions || %{}
    concrete_type = concrete_type(extensions)
    actor_url = reference_url(user.ap_id)
    source_url = reference_url(user.uri) || actor_url
    title = clean_text(user.name, 300) || clean_text(user.nickname, 300)
    license = license_metadata(extensions)

    with concrete_type when concrete_type in @concrete_types <- concrete_type,
         actor_url when is_binary(actor_url) <- actor_url,
         title when is_binary(title) <- title do
      %{
        "id" => user.id,
        "family" => "model",
        "kind" => kind_for_type(concrete_type),
        "concrete_type" => concrete_type,
        "title" => title,
        "summary" => user.bio |> plain_text() |> truncate(900),
        "description" => extensions["content"] |> plain_text() |> truncate(1_500),
        "url" => source_url,
        "activitypub_url" => actor_url,
        "activitypub_handle" => actor_handle(user.nickname, actor_url),
        "source_host" => source_host(actor_url),
        "thumbnail_url" => thumbnail_url(user, extensions),
        "sensitive" => sensitive?(extensions),
        "creator_url" => reference_url(extensions["attributedTo"]),
        "collection_urls" => reference_urls(extensions["context"]),
        "license" => license && license.label,
        "license_url" => license && license.url,
        "commercial_license" => license && license.commercial,
        "tags" => actor_tags(extensions["tag"]),
        "links" => actor_links(extensions["attachment"]),
        "attribution_domains" => attribution_domains(extensions),
        "updated_at" => iso8601(user.updated_at),
        "local_action" => "resolve"
      }
    else
      _ -> nil
    end
  end

  defp normalize_actor(_), do: nil

  defp related_actor_map(items) do
    references =
      items
      |> Enum.flat_map(fn item ->
        [item["creator_url"] | List.wrap(item["collection_urls"])]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(400)

    if references == [] do
      %{}
    else
      from(user in User,
        where: user.local == false,
        where: user.is_active == true,
        where: user.ap_id in ^references
      )
      |> Repo.all(timeout: 30_000)
      |> Enum.map(&related_actor/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1["url"], &1})
    end
  end

  defp related_actor(%User{} = user) do
    extensions = user.actor_extensions || %{}
    concrete_type = concrete_type(extensions)
    url = reference_url(user.ap_id)
    name = clean_text(user.name, 300) || clean_text(user.nickname, 300)

    if (concrete_type in @concrete_types and url) && name do
      %{
        "name" => name,
        "url" => url,
        "activitypub_handle" => actor_handle(user.nickname, url),
        "concrete_type" => concrete_type
      }
    end
  end

  defp related_actor(_), do: nil

  defp hydrate_relations(item, relations) do
    creator = Map.get(relations, item["creator_url"])

    collections =
      item["collection_urls"]
      |> List.wrap()
      |> Enum.flat_map(fn url ->
        case Map.get(relations, url) do
          %{} = relation -> [relation]
          _ -> []
        end
      end)

    item
    |> Map.put("creator", creator)
    |> Map.put("collections", collections)
  end

  defp concrete_type(extensions) do
    extensions["f3di:concreteType"] ||
      extensions["concreteType"] ||
      extensions["http://purl.org/f3di/ns#concreteType"]
  end

  defp kind_for_type("3DModel"), do: "model"
  defp kind_for_type("Creator"), do: "creator"
  defp kind_for_type("Collection"), do: "collection"

  defp thumbnail_url(user, extensions) do
    (reference_url(extensions["preview"]) || reference_url(user.avatar))
    |> then(fn
      url when is_binary(url) -> MediaProxy.browser_url(url)
      _ -> nil
    end)
  end

  defp sensitive?(extensions) do
    extensions["as:sensitive"] == true || extensions["sensitive"] == true
  end

  defp license_metadata(extensions) do
    case extensions["spdx:license"] || extensions["license"] do
      %{} = license ->
        label =
          clean_text(
            license["spdx:licenseId"] || license["licenseId"] || license["name"] ||
              license["id"] || license["@id"],
            240
          )

        url = license_url(license["@id"] || license["id"])
        build_license_metadata(label, url)

      value ->
        build_license_metadata(clean_text(value, 240), nil)
    end
  end

  defp build_license_metadata(nil, nil), do: nil

  defp build_license_metadata(label, url) do
    %{
      label: label || url,
      url: url,
      commercial:
        is_binary(label) and
          String.starts_with?(String.downcase(label), "licenseref-commercial")
    }
  end

  defp license_url(value) do
    case reference_url(value) do
      "http://spdx.org/" <> path -> "https://spdx.org/" <> path
      url -> url
    end
  end

  defp actor_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.flat_map(fn
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

  defp actor_links(attachments) do
    attachments
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "Link"} = link ->
        url = reference_url(link["href"] || link["url"])
        label = clean_text(link["name"], 160) || source_host(url)

        if url && label, do: [%{"label" => label, "url" => url}], else: []

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(8)
  end

  defp attribution_domains(extensions) do
    (extensions["toot:attributionDomains"] || extensions["attributionDomains"] || [])
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        case clean_domain(value) do
          domain when is_binary(domain) -> [domain]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp clean_domain(value) do
    value = value |> String.trim() |> String.downcase()

    if String.match?(value, ~r/\A[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?\z/) and
         String.contains?(value, ".") do
      value
    end
  end

  defp actor_handle(nickname, actor_url) when is_binary(nickname) do
    nickname = String.trim(nickname)

    cond do
      nickname == "" -> actor_handle(nil, actor_url)
      String.starts_with?(nickname, "@") -> nickname
      String.contains?(nickname, "@") -> "@" <> nickname
      true -> actor_handle(nil, actor_url)
    end
  end

  defp actor_handle(_nickname, actor_url) do
    case URI.parse(actor_url || "") do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        username = path |> String.split("/", trim: true) |> List.last()
        if username, do: "@#{username}@#{String.downcase(host)}"

      _ ->
        nil
    end
  end

  defp reference_urls(values) when is_list(values) do
    values
    |> Enum.flat_map(&reference_urls/1)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp reference_urls(value) do
    case reference_url(value) do
      url when is_binary(url) -> [url]
      _ -> []
    end
  end

  defp reference_url(%URI{} = value), do: reference_url(URI.to_string(value))

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

  defp reference_url(%{"url" => value}), do: reference_url(value)
  defp reference_url(%{"href" => value}), do: reference_url(value)
  defp reference_url(%{"id" => value}), do: reference_url(value)
  defp reference_url(%{"@id" => value}), do: reference_url(value)

  defp reference_url(values) when is_list(values) do
    Enum.find_value(values, &reference_url/1)
  end

  defp reference_url(_), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_), do: nil

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

# end of manyfold_actor_discovery.ex
