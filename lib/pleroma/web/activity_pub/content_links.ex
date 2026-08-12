# Project: Unfathomably ActivityPub
# ---------------------------------
#
# File: content_links.ex
#
# Purpose:
#
#     Resolve relative links in authored and remote federated content without
#     relying on regular-expression HTML rewriting.
#
# Responsibilities:
#
#     * rewrite HTML URL attributes through a parsed Floki tree
#     * rewrite Markdown link and image nodes through the MDEx AST
#     * choose a safe canonical base from ActivityStreams object metadata
#     * sanitize HTML source representations before federation or storage
#
# This file intentionally does NOT contain:
#
#     * remote HTTP fetching
#     * mention or hashtag parsing
#     * object authorization policy

defmodule Pleroma.Web.ActivityPub.ContentLinks do
  @moduledoc """
  Canonicalizes relative links in ActivityPub content representations.

  Rendered HTML and Markdown source use separate parsers so code blocks, link
  labels, and unrelated text are never changed by URL normalization.
  """

  alias Pleroma.HTML

  @html_url_attributes ~w[cite href poster src]
  @maximum_base_length 2_048

  def canonical_base(object) when is_map(object) do
    object
    |> canonical_references()
    |> Enum.find_value(fn reference ->
      case base_uri(reference) do
        {:ok, _uri} -> reference
        {:error, _reason} -> nil
      end
    end)
  end

  def canonical_base(_object), do: nil

  def normalize_source(content, media_type, base) when is_binary(content) do
    case normalized_media_type(media_type) do
      "text/markdown" -> absolutize_markdown(content, base)
      "text/html" -> content |> absolutize_html(base) |> HTML.filter_tags()
      _other -> content
    end
  end

  def normalize_source(content, _media_type, _base), do: content

  def absolutize_html(html, base) when is_binary(html) do
    with {:ok, base_uri} <- base_uri(base),
         {:ok, nodes} <- Floki.parse_fragment(html) do
      nodes
      |> Enum.map(&rewrite_html_node(&1, base_uri))
      |> Floki.raw_html()
    else
      _invalid -> html
    end
  rescue
    _error -> html
  catch
    _, _error -> html
  end

  def absolutize_html(html, _base), do: html

  def absolutize_markdown(markdown, base) when is_binary(markdown) do
    with {:ok, base_uri} <- base_uri(base),
         {:ok, document} <-
           MDEx.parse_document(markdown,
             extension: [autolink: true, strikethrough: true],
             parse: [smart: false]
           ) do
      {document, changed?} =
        MDEx.traverse_and_update(document, false, fn
          %MDEx.Link{url: url} = link, changed? ->
            rewrite_markdown_node(link, url, base_uri, changed?)

          %MDEx.Image{url: url} = image, changed? ->
            rewrite_markdown_node(image, url, base_uri, changed?)

          node, changed? ->
            {node, changed?}
        end)

      markdown_from_document(document, markdown, changed?)
    else
      _invalid -> markdown
    end
  rescue
    _error -> markdown
  catch
    _, _error -> markdown
  end

  def absolutize_markdown(markdown, _base), do: markdown

  defp rewrite_html_node({tag, attributes, children}, base_uri)
       when is_binary(tag) and is_list(attributes) and is_list(children) do
    attributes =
      Enum.map(attributes, fn
        {name, value} when name in @html_url_attributes and is_binary(value) ->
          {name, absolutize_url(value, base_uri)}

        attribute ->
          attribute
      end)

    {tag, attributes, Enum.map(children, &rewrite_html_node(&1, base_uri))}
  end

  defp rewrite_html_node(nodes, base_uri) when is_list(nodes),
    do: Enum.map(nodes, &rewrite_html_node(&1, base_uri))

  defp rewrite_html_node(node, _base_uri), do: node

  defp rewrite_markdown_node(node, url, base_uri, changed?) do
    normalized = absolutize_url(url, base_uri)
    {%{node | url: normalized}, changed? or normalized != url}
  end

  defp markdown_from_document(_document, markdown, false), do: markdown

  defp markdown_from_document(document, markdown, true) do
    case MDEx.to_markdown(document) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> markdown
    end
  end

  defp absolutize_url(value, base_uri) do
    candidate = String.trim(value)

    cond do
      candidate == "" ->
        value

      absolute_url?(candidate) ->
        value

      true ->
        base_uri
        |> URI.merge(candidate)
        |> URI.to_string()
    end
  rescue
    _error -> value
  end

  defp absolute_url?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme} when is_binary(scheme) and scheme != "" -> true
      _relative -> false
    end
  end

  defp canonical_references(object) do
    reference_urls(object["url"]) ++ reference_urls(object["id"])
  end

  defp reference_urls(value) when is_binary(value), do: [value]
  defp reference_urls(values) when is_list(values), do: Enum.flat_map(values, &reference_urls/1)

  defp reference_urls(%{} = value) do
    [value["href"], value["id"], value["url"]]
    |> Enum.flat_map(&reference_urls/1)
  end

  defp reference_urls(_value), do: []

  defp base_uri(value) when is_binary(value) and byte_size(value) <= @maximum_base_length do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _invalid ->
        {:error, :invalid_base}
    end
  end

  defp base_uri(_value), do: {:error, :invalid_base}

  defp normalized_media_type(media_type) when is_binary(media_type) do
    media_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  defp normalized_media_type(_media_type), do: nil
end

# end of content_links.ex
