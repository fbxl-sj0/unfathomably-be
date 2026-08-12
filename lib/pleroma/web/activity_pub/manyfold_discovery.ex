# Unfathomably Manyfold discovery
# --------------------------------
#
# File: manyfold_discovery.ex
#
# Purpose:
#   Search reviewed Manyfold catalogues for public 3D model actors.
#
# Responsibilities:
#   - browse or search one bounded page from configured servers
#   - parse public model cards without crawling model detail pages
#   - retain the native page URL and the model's WebFinger handle
#   - reject cross-origin links and malformed catalogue records
#
# This file intentionally does not implement FASP registration, follow actors,
# download model files, or crawl a Manyfold server's federation graph.

defmodule Pleroma.Web.ActivityPub.ManyfoldDiscovery do
  alias Pleroma.Config
  alias Pleroma.HTTP

  @http_timeout 15_000
  @max_body_bytes 4_000_000
  @max_indexes 3

  @type provider_result :: %{
          items: [map()],
          total: non_neg_integer(),
          has_more: boolean(),
          provider: map()
        }

  @spec searches(String.t(), pos_integer(), non_neg_integer()) :: [provider_result()]
  def searches(query, limit, offset)
      when is_binary(query) and is_integer(limit) and limit > 0 and is_integer(offset) and
             offset >= 0 do
    configured_indexes()
    |> Enum.map(&search_index(&1, query, limit, offset))
  end

  def searches(_query, _limit, _offset), do: []

  # Manyfold's public catalogue does not expose a stable offset contract.
  # Restricting discovery to its first filtered page prevents duplicate or
  # misleading pagination while still providing a useful route into native
  # actor resolution.
  defp search_index(index, _query, _limit, offset) when offset > 0 do
    result(index, [], "ready")
  end

  defp search_index(index, query, limit, 0) do
    with {:ok, document} <- fetch_search(index, query) do
      items =
        document
        |> Floki.find(".card.preview-card")
        |> Enum.map(&normalize_model(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(limit)

      result(index, items, "ready")
    else
      _ -> result(index, [], "unavailable")
    end
  end

  defp fetch_search(index, query) do
    path =
      case String.trim(query) do
        "" -> "/models"
        query -> "/models?" <> URI.encode_query(%{"q" => query})
      end

    url =
      index
      |> URI.parse()
      |> URI.merge(path)
      |> to_string()

    headers = [{"accept", "text/html,application/xhtml+xml"}]

    with {:ok, %{status: 200, body: body}}
         when is_binary(body) and byte_size(body) <= @max_body_bytes <-
           HTTP.get(url, headers, pool: :default, recv_timeout: @http_timeout) do
      Floki.parse_document(body)
    else
      _ -> {:error, :provider_unavailable}
    end
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    _, _ -> {:error, :provider_unavailable}
  end

  defp normalize_model(card, index) do
    model_path = first_path(card, ~r{^/models/[A-Za-z0-9]+$})
    title = card |> Floki.find(".card-title") |> List.first() |> node_text(300)

    with path when is_binary(path) <- model_path,
         slug when is_binary(slug) <- model_slug(path),
         model_url when is_binary(model_url) <- same_origin_url(index, path),
         host when is_binary(host) <- URI.parse(index).host,
         title when is_binary(title) <- title do
      %{
        id: "manyfold:" <> String.downcase(host) <> ":" <> slug,
        family: "model",
        kind: "3DModel",
        title: title,
        summary: card |> Floki.find(".card-subtitle") |> List.first() |> node_text(1_000),
        url: model_url,
        activitypub_handle: "@#{slug}@#{String.downcase(host)}",
        thumbnail_url: image_url(card, index) |> Pleroma.Web.MediaProxy.browser_url(),
        creator: related_actor(card, index, ~r{^/creators/[^/?#]+$}),
        collection: related_actor(card, index, ~r{^/collections/[^/?#]+$}),
        tags: tags(card),
        source_host: String.downcase(host),
        published_at: nil,
        local_action: "resolve"
      }
    else
      _ -> nil
    end
  end

  defp model_slug(path) do
    case String.split(path, "/", trim: true) do
      ["models", slug] -> slug
      _ -> nil
    end
  end

  defp related_actor(card, index, path_pattern) do
    case first_link(card, path_pattern) do
      {path, name} ->
        case same_origin_url(index, path) do
          url when is_binary(url) -> %{name: name, url: url}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp first_link(card, path_pattern) do
    card
    |> Floki.find("a[href]")
    |> Enum.find_value(fn node ->
      path = attribute(node, "href")
      name = node_text(node, 200)

      if is_binary(path) and is_binary(name) and Regex.match?(path_pattern, path) do
        {path, name}
      end
    end)
  end

  defp first_path(card, path_pattern) do
    card
    |> Floki.find("a[href]")
    |> Enum.find_value(fn node ->
      path = attribute(node, "href")
      if is_binary(path) and Regex.match?(path_pattern, path), do: path
    end)
  end

  defp image_url(card, index) do
    card
    |> Floki.find("img.image-preview")
    |> List.first()
    |> attribute("src")
    |> same_origin_url(index)
  end

  defp tags(card) do
    card
    |> Floki.find("a.tag")
    |> Enum.map(&node_text(&1, 80))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp same_origin_url(nil, _index), do: nil

  defp same_origin_url(path, index) when is_binary(path) and is_binary(index) do
    index_uri = URI.parse(index)
    url = index_uri |> URI.merge(path) |> to_string()
    uri = URI.parse(url)

    if uri.scheme == "https" and is_binary(uri.host) and uri.userinfo == nil and
         String.downcase(uri.host) == String.downcase(index_uri.host) do
      String.slice(url, 0, 2_000)
    end
  rescue
    _ -> nil
  end

  defp same_origin_url(_path, _index), do: nil

  defp attribute(nil, _name), do: nil

  defp attribute(node, name) do
    node
    |> Floki.attribute(name)
    |> List.first()
  end

  defp node_text(nil, _limit), do: nil

  defp node_text(node, limit) do
    text =
      node
      |> Floki.text()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, limit)

    if text == "", do: nil, else: text
  end

  defp result(index, items, status) do
    %{
      items: items,
      total: length(items),
      has_more: false,
      provider: %{
        type: "manyfold",
        host: URI.parse(index).host,
        status: status,
        accepted_peer_count: 0
      }
    }
  end

  defp configured_indexes do
    Config.get([:native_discovery, :manyfold_indexes], [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&valid_index_url?/1)
    |> Enum.uniq()
    |> Enum.take(@max_indexes)
  end

  defp valid_index_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and path in [nil, "", "/"] ->
        true

      _ ->
        false
    end
  end
end

# end of manyfold_discovery.ex
