# Unfathomably BE
# ----------------
#
# File: nostr/media.ex
#
# Purpose:
#   Convert signed Nostr media references into ActivityPub attachments.
#
# Responsibilities:
#   - parse and emit bounded NIP-92 imeta fields
#   - keep outbound media URLs visible in event content for client discovery
#   - recognize conservative HTTPS media URL fallbacks
#   - build the attachment shape used by Mastodon-compatible clients
#
# This file intentionally does NOT fetch remote media, trust arbitrary MIME
# types, or rewrite authored post text beyond appending missing attachment URLs.

defmodule Pleroma.Nostr.Media do
  alias Pleroma.Config

  @max_url_bytes 2_048
  @max_dimension 32_768
  @url_pattern ~r{https://[^\s<>"']+}i
  @trailing_punctuation ~r/[\]\[(){}.,;:!?]+\z/

  @mime_types %{
    ".avif" => "image/avif",
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp",
    ".flac" => "audio/flac",
    ".m4a" => "audio/mp4",
    ".mp3" => "audio/mpeg",
    ".oga" => "audio/ogg",
    ".ogg" => "audio/ogg",
    ".wav" => "audio/wav",
    ".mov" => "video/quicktime",
    ".mp4" => "video/mp4",
    ".webm" => "video/webm"
  }

  @allowed_mime_types MapSet.new(Map.values(@mime_types))

  def put_attachments(object, event) when is_map(object) do
    case attachments(event) do
      [] -> object
      media -> Map.put(object, "attachment", media)
    end
  end

  def attachments(%{"tags" => tags} = event) when is_list(tags) do
    imeta = Enum.flat_map(tags, &imeta_candidate/1)
    references = Enum.flat_map(tags, &reference_candidate/1)
    content = content_candidates(event["content"])

    (imeta ++ references ++ content)
    |> Enum.uniq_by(& &1.url)
    |> Enum.take(max_attachments())
    |> Enum.map(&attachment/1)
  end

  def attachments(_event), do: []

  def outbound_tags(%{"attachment" => attachments}) when is_list(attachments) do
    attachments
    |> Enum.flat_map(&outbound_attachment/1)
    |> Enum.take(max_attachments())
  end

  def outbound_tags(_object), do: []

  def outbound(content, object) when is_binary(content) and is_map(object) do
    tags = outbound_tags(object)

    content =
      tags
      |> Enum.flat_map(&outbound_tag_urls/1)
      |> Enum.uniq()
      |> Enum.reduce(content, &append_missing_url/2)

    {content, tags}
  end

  def outbound(content, _object), do: {to_string(content || ""), []}

  defp imeta_candidate(["imeta" | fields]) when is_list(fields) do
    metadata =
      Enum.reduce(fields, %{}, fn
        field, acc when is_binary(field) ->
          case String.split(field, " ", parts: 2) do
            [key, value] when value != "" -> Map.put_new(acc, key, value)
            _ -> acc
          end

        _field, acc ->
          acc
      end)

    case candidate(metadata["url"], metadata["m"]) do
      nil ->
        []

      candidate ->
        {width, height} = dimensions(metadata["dim"])

        candidate =
          candidate
          |> maybe_put(:name, bounded_text(metadata["alt"], 1_500))
          |> maybe_put(:blurhash, bounded_text(metadata["blurhash"], 200))
          |> maybe_put(:width, width)
          |> maybe_put(:height, height)

        [candidate]
    end
  end

  defp imeta_candidate(_tag), do: []

  defp reference_candidate(["r", url | _rest]) when is_binary(url) do
    case candidate(url, nil) do
      nil -> []
      candidate -> [candidate]
    end
  end

  defp reference_candidate(_tag), do: []

  defp content_candidates(content) when is_binary(content) do
    @url_pattern
    |> Regex.scan(content, capture: :first)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, @trailing_punctuation, ""))
    |> Enum.flat_map(fn url ->
      case candidate(url, nil) do
        nil -> []
        candidate -> [candidate]
      end
    end)
  end

  defp content_candidates(_content), do: []

  defp outbound_attachment(%{} = attachment) do
    with {url, link} when is_binary(url) <- attachment_url(attachment["url"]),
         true <- valid_https_url?(url),
         mime when is_binary(mime) <-
           allowed_mime(attachment["mediaType"] || link["mediaType"]) || inferred_mime(url) do
      fields =
        ["url #{url}", "m #{mime}"]
        |> maybe_append_field("dim", outbound_dimensions(link, attachment))
        |> maybe_append_field("alt", safe_metadata_text(attachment["name"], 1_500))
        |> maybe_append_field("blurhash", safe_metadata_text(attachment["blurhash"], 200))

      [["imeta" | fields]]
    else
      _invalid -> []
    end
  end

  defp outbound_attachment(_attachment), do: []

  defp outbound_tag_urls(["imeta" | fields]) do
    Enum.flat_map(fields, fn
      "url " <> url -> [url]
      _field -> []
    end)
  end

  defp outbound_tag_urls(_tag), do: []

  defp append_missing_url(url, content) do
    cond do
      String.contains?(content, url) -> content
      content == "" -> url
      String.ends_with?(content, "\n") -> content <> url
      true -> content <> "\n\n" <> url
    end
  end

  defp attachment_url([%{"href" => href} = link | _rest]) when is_binary(href),
    do: {href, link}

  defp attachment_url(%{"href" => href} = link) when is_binary(href), do: {href, link}
  defp attachment_url(href) when is_binary(href), do: {href, %{}}
  defp attachment_url(_url), do: nil

  defp outbound_dimensions(link, attachment) do
    with width when is_integer(width) <- link["width"] || attachment["width"],
         height when is_integer(height) <- link["height"] || attachment["height"],
         true <- width in 1..@max_dimension and height in 1..@max_dimension do
      "#{width}x#{height}"
    else
      _invalid -> nil
    end
  end

  defp safe_metadata_text(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes do
    if String.valid?(value) and not String.contains?(value, ["\0", "\r", "\n"]), do: value
  end

  defp safe_metadata_text(_value, _max_bytes), do: nil

  defp maybe_append_field(fields, _key, nil), do: fields
  defp maybe_append_field(fields, key, value), do: fields ++ ["#{key} #{value}"]

  defp candidate(url, supplied_mime) do
    with true <- valid_https_url?(url),
         mime when is_binary(mime) <- allowed_mime(supplied_mime) || inferred_mime(url) do
      %{url: url, mime: mime}
    else
      _ -> nil
    end
  end

  defp valid_https_url?(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil}
      when is_binary(host) and host != "" and host != "localhost" ->
        true

      _ ->
        false
    end
  end

  defp valid_https_url?(_url), do: false

  defp allowed_mime(mime) when is_binary(mime) do
    mime =
      mime
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.downcase()
      |> case do
        "image/jpg" -> "image/jpeg"
        normalized -> normalized
      end

    if MapSet.member?(@allowed_mime_types, mime), do: mime
  end

  defp allowed_mime(_mime), do: nil

  defp inferred_mime(url) do
    extension =
      url
      |> URI.parse()
      |> Map.get(:path)
      |> to_string()
      |> Path.extname()
      |> String.downcase()

    Map.get(@mime_types, extension)
  end

  defp dimensions(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{1,5})x(\d{1,5})\z/, value) do
      [_, width, height] ->
        width = String.to_integer(width)
        height = String.to_integer(height)

        if width in 1..@max_dimension and height in 1..@max_dimension do
          {width, height}
        else
          {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp dimensions(_value), do: {nil, nil}

  defp bounded_text(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes,
       do: value

  defp bounded_text(_value, _max_bytes), do: nil

  defp attachment(candidate) do
    link =
      %{
        "type" => "Link",
        "mediaType" => candidate.mime,
        "href" => candidate.url
      }
      |> maybe_put("width", candidate[:width])
      |> maybe_put("height", candidate[:height])

    %{
      "type" => "Document",
      "mediaType" => candidate.mime,
      "url" => [link]
    }
    |> maybe_put("name", candidate[:name])
    |> maybe_put("blurhash", candidate[:blurhash])
  end

  defp max_attachments do
    case Config.get([:instance, :max_media_attachments], 4) do
      count when is_integer(count) and count in 1..16 -> count
      _ -> 4
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of nostr/media.ex
