# Unfathomably alien publishing discovery
# ----------------------------------------
#
# File: publishing_discovery.ex
#
# Purpose:
#   Search public bookmarks, articles, and publications already held locally.
#
# Responsibilities:
#   - query immutable native-family and full-text indexes
#   - enforce normal public visibility before returning an object
#   - distinguish authored Document roots from stored media attachments
#   - preserve the distinction between a bookmark target and its AP object
#   - normalize author, subject, language, licence, tag, and attachment context
#
# This file intentionally does not crawl outboxes, fetch article bodies,
# classify arbitrary Notes as bookmarks, or expose private records.

defmodule Pleroma.Web.ActivityPub.PublishingDiscovery do
  import Ecto.Query

  require Logger

  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.Endpoint

  @families ~w[bookmarks longform publishing]
  @maximum_limit 24
  @maximum_offset 500
  @maximum_scan 800
  @minimum_scan 80
  @query_timeout 15_000

  @spec searches(String.t(), String.t(), integer(), integer()) :: [map()]
  def searches(family, query, limit, offset) when family in @families do
    [search(family, query, limit, offset)]
  end

  def searches(_family, _query, _limit, _offset), do: []

  @spec search(String.t(), String.t(), integer(), integer()) :: map()
  def search(family, query, limit, offset) when family in @families do
    query = bounded_text(query, 200) || ""
    limit = bounded_integer(limit, 1, @maximum_limit, 16)
    offset = bounded_integer(offset, 0, @maximum_offset, 0)
    scan_limit = min(max((offset + limit) * 4, @minimum_scan), @maximum_scan)

    matching_objects =
      family
      |> publishing_query(query, scan_limit)
      |> Repo.all(timeout: @query_timeout)
      |> Enum.filter(&public_object?/1)
      |> Enum.map(&normalize_object(&1, family))
      |> Enum.reject(&is_nil/1)

    items =
      matching_objects
      |> Enum.drop(offset)
      |> Enum.take(limit)

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
      Logger.warning("Local #{family} discovery failed: #{Exception.message(error)}")

      %{
        items: [],
        total: 0,
        has_more: false,
        provider: provider_metadata("unavailable"),
        communities: []
      }
  end

  def search(_family, _query, _limit, _offset) do
    %{
      items: [],
      total: 0,
      has_more: false,
      provider: provider_metadata("unavailable"),
      communities: []
    }
  end

  defp publishing_query(family, search, scan_limit) do
    query =
      from(object in Object,
        where: fragment("unfathomably_native_discoverable(?) = true", object.data),
        # Uploaded media are stored as standalone ActivityPub Document objects
        # with an actor, name, media type, and URL. They have no Create activity
        # or audience and are not publications. Preserve explicit native
        # Documents and remote Document roots that carry normal status fields.
        where:
          fragment(
            """
            COALESCE(?->>'type', '') <> 'Document'
            OR ?->>'https://unfathomably.social/ns#family' IN (
              'bookmarks', 'longform', 'publishing'
            )
            OR jsonb_exists_any(
              ?,
              ARRAY['published', 'updated', 'to', 'cc', 'audience']
            )
            """,
            object.data,
            object.data,
            object.data
          ),
        order_by: [desc: object.id],
        limit: ^scan_limit
      )

    query =
      from(object in query,
        where: fragment("unfathomably_native_family(?) = ?", object.data, ^family)
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

  defp public_object?(%Object{} = object) do
    Visibility.is_public?(object) and not Visibility.is_local_public?(object)
  rescue
    _ -> false
  end

  defp public_object?(_object), do: false

  defp normalize_object(%Object{data: data}, family) when is_map(data) do
    with activitypub_url when is_binary(activitypub_url) <- https_url(data["id"]),
         source_host when is_binary(source_host) <- URI.parse(activitypub_url).host do
      content = first_text(data["content"])
      content_link = first_content_link(content)
      sensitive = data["sensitive"] == true
      title = object_title(data, family, content, content_link, source_host)
      summary = object_summary(data, content, title, sensitive)
      target_url = bookmark_target(data, family, content_link)
      source_url = object_source_url(data, family, activitypub_url)
      attachment = document_attachment(data["attachment"])

      %{
        id: activitypub_url,
        family: family,
        kind: family_kind(family),
        object_type: short_type(data["type"]),
        title: title,
        summary: summary,
        url: source_url,
        activitypub_url: activitypub_url,
        actor_url: https_url(data["actor"]) || https_url(data["attributedTo"]),
        target_url: target_url,
        target_host: target_host(target_url),
        byline:
          human_text(data["byline"]) ||
            human_text(data["author"]) ||
            human_text(extension_field(data, "author")),
        site_name:
          human_text(data["siteName"]) ||
            human_text(data["site_name"]) ||
            human_text(extension_field(data, "site_name")),
        subtitle:
          human_text(data["subtitle"]) ||
            human_text(extension_field(data, "subtitle")),
        subject:
          human_text(data["subject"]) ||
            human_text(extension_field(data, "subject")),
        language:
          human_text(data["language"]) ||
            human_text(extension_field(data, "language")),
        licence:
          human_text(data["license"]) ||
            human_text(data["licence"]) ||
            human_text(extension_field(data, "license")),
        tags: hashtag_names(data["tag"]),
        attachment: attachment,
        sensitive: sensitive,
        published_at: first_text(data["published"]) || first_text(data["updated"]),
        source_host: String.downcase(source_host),
        local_action: "resolve"
      }
    else
      _ -> nil
    end
  end

  defp normalize_object(_object, _family), do: nil

  defp object_title(data, "bookmarks", content, content_link, source_host) do
    first_text(data["name"]) ||
      Map.get(content_link || %{}, :text) ||
      bounded_text(plain_text(content), 160) ||
      "Bookmark from #{source_host}"
  end

  defp object_title(data, _family, content, _content_link, source_host) do
    first_text(data["name"]) ||
      first_text(data["subject"]) ||
      bounded_text(plain_text(content), 160) ||
      "Publication from #{source_host}"
  end

  defp object_summary(data, _content, _title, true) do
    data["summary"]
    |> first_text()
    |> plain_text()
    |> bounded_text(1_200)
  end

  defp object_summary(data, content, title, false) do
    summary =
      first_text(data["summary"]) ||
        first_text(data["description"]) ||
        content

    summary = summary |> plain_text() |> bounded_text(1_200)
    if summary == title, do: nil, else: summary
  end

  defp bookmark_target(data, "bookmarks", content_link) do
    https_url(data["target"]) ||
      explicit_bookmark_url(data) ||
      Map.get(content_link || %{}, :url)
  end

  defp bookmark_target(_data, _family, _content_link), do: nil

  defp explicit_bookmark_url(data) do
    explicit_family = first_text(data["https://unfathomably.social/ns#family"])

    if explicit_family == "bookmarks", do: https_url(data["url"])
  end

  defp object_source_url(_data, "bookmarks", activitypub_url), do: activitypub_url

  defp object_source_url(data, _family, activitypub_url) do
    https_url(data["url"]) || activitypub_url
  end

  defp first_content_link(nil), do: nil

  defp first_content_link(content) when is_binary(content) do
    with {:ok, document} <- Floki.parse_fragment(content),
         node when not is_nil(node) <- document |> Floki.find("a") |> List.first(),
         url when is_binary(url) <- node |> Floki.attribute("href") |> List.first(),
         url when is_binary(url) <- https_url(url) do
      %{url: url, text: node |> Floki.text(sep: " ") |> bounded_text(200)}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp first_content_link(_content), do: nil

  defp document_attachment(attachments) do
    attachments
    |> List.wrap()
    |> Enum.find_value(fn
      attachment when is_map(attachment) ->
        case https_url(attachment["url"]) || https_url(attachment["href"]) do
          url when is_binary(url) ->
            %{
              url: url,
              name:
                human_text(attachment["name"]) ||
                  human_text(attachment["description"]),
              media_type: human_text(attachment["mediaType"])
            }

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp extension_field(data, key) do
    case data["_unfathomably_native"] do
      %{"extensionFields" => fields} when is_map(fields) -> Map.get(fields, key)
      _ -> nil
    end
  end

  defp hashtag_names(tags) do
    tags
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "Hashtag", "name" => name} -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&String.trim_leading(&1, "#"))
    |> Enum.map(&bounded_text(&1, 80))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp family_kind("bookmarks"), do: "bookmark"
  defp family_kind("longform"), do: "article"
  defp family_kind("publishing"), do: "publication"

  defp short_type(value) do
    value
    |> first_text()
    |> case do
      nil -> nil
      type -> type |> String.split(~r{[/#:]}) |> List.last() |> String.downcase()
    end
  end

  defp target_host(nil), do: nil
  defp target_host(url), do: URI.parse(url).host

  defp human_text(value) do
    value
    |> first_text()
    |> case do
      "http://" <> _ -> nil
      "https://" <> _ -> nil
      text -> bounded_text(text, 200)
    end
  end

  defp plain_text(nil), do: nil

  defp plain_text(value) when is_binary(value) do
    case Floki.parse_fragment(value) do
      {:ok, document} -> document |> Floki.text(sep: " ") |> bounded_text(2_000)
      _ -> bounded_text(value, 2_000)
    end
  rescue
    _ -> bounded_text(value, 2_000)
  end

  defp first_text(value) when is_binary(value), do: bounded_text(value, 2_000)
  defp first_text(value) when is_list(value), do: Enum.find_value(value, &first_text/1)

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
      type: "local_publishing",
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

# end of publishing_discovery.ex
