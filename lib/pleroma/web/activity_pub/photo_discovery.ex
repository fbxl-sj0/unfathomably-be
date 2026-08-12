# Unfathomably public photograph discovery
# -----------------------------------------
#
# File: photo_discovery.ex
#
# Purpose:
#   Search public photographic objects that this server already received.
#
# Responsibilities:
#   - use the indexed native-object family and search-document functions
#   - enforce normal ActivityPub public visibility before returning a record
#   - normalize Pixelfed-compatible image, caption, place, tag, and actor data
#   - route non-sensitive previews through the configured media proxy
#
# This file intentionally does not crawl Pixelfed servers, query private
# collections, expose sensitive thumbnails, or perform social interactions.

defmodule Pleroma.Web.ActivityPub.PhotoDiscovery do
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
  @public "https://www.w3.org/ns/activitystreams#Public"
  @maximum_gallery_items 12
  @maximum_attachment_scan 100

  @spec searches(String.t(), integer(), integer()) :: [map()]
  def searches(query, limit, offset) do
    [search(query, limit, offset)]
  end

  @spec search(String.t(), integer(), integer()) :: map()
  def search(query, limit, offset) do
    query = bounded_text(query, 200) || ""
    limit = bounded_integer(limit, 1, @maximum_limit, 16)
    offset = bounded_integer(offset, 0, @maximum_offset, 0)
    scan_limit = min(max((offset + limit) * 4, @minimum_scan), @maximum_scan)

    matching_objects =
      query
      |> photo_query(scan_limit)
      |> Repo.all(timeout: @query_timeout)
      |> Enum.filter(&public_federated_object?/1)
      |> Enum.map(&normalize_object/1)
      |> Enum.reject(&is_nil/1)

    items =
      matching_objects
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> hydrate_actor_labels()

    has_more =
      length(matching_objects) > offset + length(items) or
        length(matching_objects) == scan_limit

    %{
      items: items,
      total: max(length(matching_objects), offset + length(items)),
      has_more: has_more,
      provider: provider_metadata("ready"),
      communities: []
    }
  rescue
    error ->
      Logger.warning("Local public photograph discovery failed: #{Exception.message(error)}")

      %{
        items: [],
        total: 0,
        has_more: false,
        provider: provider_metadata("unavailable"),
        communities: []
      }
  end

  defp photo_query(search, scan_limit) do
    query =
      from(object in Object,
        where: fragment("unfathomably_native_discoverable(?) = true", object.data),
        where: fragment("unfathomably_native_family(?) = 'photo'", object.data),
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
         media_items when is_list(media_items) and media_items != [] <- image_media(data) do
      media = List.first(media_items)
      source_url = https_url(data["url"]) || activitypub_url
      actor_url = https_url(data["actor"]) || https_url(data["attributedTo"])
      sensitive = data["sensitive"] == true
      caption = plain_text(first_text(data["content"]) || first_text(data["summary"]))
      title = photograph_title(data, media, caption, source_host)
      summary = if caption == title, do: nil, else: bounded_text(caption, 1_000)
      comments_enabled = boolean_value(data["commentsEnabled"])
      interaction_permissions = interaction_permissions(data["capabilities"], comments_enabled)

      %{
        id: activitypub_url,
        family: "photo",
        kind: "photograph",
        title: title,
        summary: summary,
        url: source_url,
        activitypub_url: activitypub_url,
        actor_url: actor_url,
        actor_label: embedded_actor_label(data),
        preview_url: if(sensitive, do: nil, else: MediaProxy.browser_url(media.url)),
        alt_text: media.alt_text,
        sensitive: sensitive,
        image_count: length(media_items),
        images: gallery_images(media_items, sensitive),
        tags: hashtag_names(data["tag"]),
        location: location_name(data["location"]),
        licence: first_text(data["license"]) || first_text(data["licence"]),
        comments_enabled: comments_enabled,
        capabilities: interaction_permissions.allowed,
        capabilities_declared: interaction_permissions.declared,
        published_at: first_text(data["published"]) || first_text(data["updated"]),
        source_host: String.downcase(source_host),
        local_action: "resolve"
      }
    else
      _ -> nil
    end
  end

  defp normalize_object(_object), do: nil

  defp hydrate_actor_labels(items) do
    actor_urls =
      items
      |> Enum.map(& &1.actor_url)
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

    Enum.map(items, fn item ->
      %{item | actor_label: item.actor_label || labels[item.actor_url]}
    end)
  end

  defp embedded_actor_label(data) do
    [data["actor"], data["attributedTo"]]
    |> Enum.find_value(fn
      actor when is_map(actor) ->
        first_text(actor["name"]) || first_text(actor["preferredUsername"])

      _ ->
        nil
    end)
    |> bounded_text(300)
  end

  defp image_media(data) do
    data
    |> image_candidates()
    |> Enum.take(@maximum_attachment_scan)
    |> Enum.flat_map(fn candidate ->
      if image_candidate?(candidate) do
        case https_url(candidate["url"]) || https_url(candidate["href"]) do
          url when is_binary(url) ->
            [
              %{
                url: url,
                alt_text:
                  bounded_text(
                    first_text(candidate["name"]) || first_text(candidate["description"]),
                    500
                  ),
                width: image_dimension(candidate["width"]),
                height: image_dimension(candidate["height"])
              }
            ]

          _ ->
            []
        end
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1.url)
  end

  defp image_candidates(data) do
    attachments =
      case data["attachment"] do
        value when is_list(value) -> value
        value when is_map(value) -> [value]
        _ -> []
      end

    if image_candidate?(data), do: [data | attachments], else: attachments
  end

  defp image_candidate?(data) when is_map(data) do
    data["type"] == "Image" or
      (is_binary(data["mediaType"]) and String.starts_with?(data["mediaType"], "image/"))
  end

  defp image_candidate?(_data), do: false

  defp gallery_images(_media_items, true), do: []

  defp gallery_images(media_items, false) do
    media_items
    |> Enum.take(@maximum_gallery_items)
    |> Enum.map(fn media ->
      %{
        preview_url: MediaProxy.browser_url(media.url),
        alt_text: media.alt_text,
        width: media.width,
        height: media.height
      }
    end)
  end

  defp photograph_title(data, media, caption, source_host) do
    first_text(data["name"]) ||
      media.alt_text ||
      bounded_text(caption, 160) ||
      "Photograph from #{source_host}"
  end

  @doc false
  @spec interaction_permissions(map() | term(), boolean() | nil) :: %{
          allowed: %{announce: boolean(), like: boolean(), reply: boolean()},
          declared: %{announce: boolean(), like: boolean(), reply: boolean()}
        }
  def interaction_permissions(capabilities, comments_enabled) do
    capabilities = if is_map(capabilities), do: capabilities, else: %{}
    reply_declared = Map.has_key?(capabilities, "reply") or is_boolean(comments_enabled)

    %{
      allowed: %{
        announce: public_capability(capabilities, "announce"),
        like: public_capability(capabilities, "like"),
        reply: reply_capability(capabilities, comments_enabled)
      },
      declared: %{
        announce: Map.has_key?(capabilities, "announce"),
        like: Map.has_key?(capabilities, "like"),
        reply: reply_declared
      }
    }
  end

  defp reply_capability(_capabilities, false), do: false

  defp reply_capability(capabilities, comments_enabled) do
    if Map.has_key?(capabilities, "reply") do
      public_capability(capabilities, "reply")
    else
      comments_enabled == true
    end
  end

  defp public_capability(capabilities, key) do
    capabilities
    |> Map.get(key)
    |> capability_values()
    |> Enum.member?(@public)
  end

  defp capability_values(value) when is_binary(value), do: [value]

  defp capability_values(values) when is_list(values) do
    values
    |> Enum.take(32)
    |> Enum.flat_map(&capability_values/1)
  end

  defp capability_values(%{"id" => value}) when is_binary(value), do: [value]
  defp capability_values(%{"items" => values}), do: capability_values(values)
  defp capability_values(%{"orderedItems" => values}), do: capability_values(values)
  defp capability_values(_value), do: []

  defp boolean_value(value) when is_boolean(value), do: value
  defp boolean_value(_value), do: nil

  defp image_dimension(value) when is_integer(value) and value > 0 and value <= 30_000,
    do: value

  defp image_dimension(value) when is_binary(value) do
    case Integer.parse(value) do
      {dimension, ""} when dimension > 0 and dimension <= 30_000 -> dimension
      _ -> nil
    end
  end

  defp image_dimension(_value), do: nil

  defp hashtag_names(tags) do
    tags
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "Hashtag", "name" => name} -> [name]
      name when is_binary(name) and binary_part(name, 0, 1) == "#" -> [name]
      _ -> []
    end)
    |> Enum.map(&String.trim_leading(&1, "#"))
    |> Enum.map(&bounded_text(&1, 80))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp location_name(location) when is_map(location) do
    first_text(location["name"]) ||
      first_text(location["address"]) ||
      first_text(location["id"])
      |> bounded_text(200)
  end

  defp location_name(location), do: location |> first_text() |> bounded_text(200)

  defp plain_text(nil), do: nil

  defp plain_text(value) when is_binary(value) do
    case Floki.parse_fragment(value) do
      {:ok, document} -> document |> Floki.text(sep: " ") |> bounded_text(1_000)
      _ -> bounded_text(value, 1_000)
    end
  rescue
    _ -> bounded_text(value, 1_000)
  end

  defp first_text(value) when is_binary(value), do: bounded_text(value, 2_000)

  defp first_text(value) when is_list(value) do
    Enum.find_value(value, &first_text/1)
  end

  defp first_text(value) when is_map(value) do
    ["name", "value", "href", "id", "url"]
    |> Enum.find_value(&first_text(Map.get(value, &1)))
    |> case do
      nil -> value |> Map.values() |> Enum.find_value(&first_text/1)
      text -> text
    end
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

  defp provider_metadata(status) do
    %{
      type: "local_photo",
      host: Endpoint.url() |> URI.parse() |> Map.get(:host),
      status: status,
      accepted_peer_count: 0
    }
  end

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

# end of photo_discovery.ex
