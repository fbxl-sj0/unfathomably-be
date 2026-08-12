# Unfathomably BE
# ----------------
#
# File: atproto/blobs.ex
#
# Purpose:
#   Upload local post attachments to a linked AT Protocol repository.
#
# Responsibilities:
#   - accept only trusted local HTTPS media URLs
#   - enforce Bluesky image and PDS blob size limits before upload
#   - upload bytes through com.atproto.repo.uploadBlob
#   - build native image and video embed records with alt text
#   - retain URL fallback for unsupported media
#
# This file intentionally does NOT fetch arbitrary remote URLs, process a
# firehose, transcode video, or bypass the local upload sanitization pipeline.

defmodule Pleroma.ATProto.Blobs do
  alias Pleroma.ATProto.Client
  alias Pleroma.ATProto.URL
  alias Pleroma.Config
  alias Pleroma.HTTP

  @image_types ["image/jpeg", "image/png", "image/webp", "image/gif"]
  @video_types ["video/mp4"]
  @media_types @image_types ++ @video_types
  @maximum_image_bytes 2_000_000
  @maximum_video_bytes 50_000_000
  @maximum_alt_characters 2_000

  @doc """
  Uploads one compatible media group and returns fallback URLs for the rest.

  Local uploads have already passed Unfathomably's metadata filters. Restricting
  fetches to configured local media hosts preserves that guarantee and avoids
  turning outbound federation into an SSRF-capable URL fetcher.
  """
  def prepare(attachments, session) when is_list(attachments) and is_map(session) do
    candidates = attachments |> Enum.flat_map(&candidate/1) |> Enum.uniq_by(& &1.url)
    images = Enum.filter(candidates, &(&1.mime_type in @image_types))
    videos = Enum.filter(candidates, &(&1.mime_type in @video_types))

    cond do
      images != [] ->
        selected = Enum.take(images, 4)

        with {:ok, uploaded} <- upload_all(selected, session) do
          fallback = fallback_urls(candidates, selected)
          {:ok, image_embed(uploaded), fallback}
        end

      videos != [] ->
        selected = [hd(videos)]

        with {:ok, [uploaded]} <- upload_all(selected, session) do
          fallback = fallback_urls(candidates, selected)
          {:ok, video_embed(uploaded), fallback}
        end

      true ->
        {:ok, nil, Enum.map(candidates, & &1.url)}
    end
  end

  def prepare(_attachments, _session), do: {:ok, nil, []}

  defp upload_all(candidates, session) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, uploaded} ->
      case upload(candidate, session) do
        {:ok, item} -> {:cont, {:ok, [item | uploaded]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, uploaded} -> {:ok, Enum.reverse(uploaded)}
      error -> error
    end
  end

  defp upload(candidate, session) do
    with true <- trusted_local_url?(candidate.url),
         {:ok, body, mime_type} <- fetch(candidate),
         true <- byte_size(body) <= maximum_bytes(mime_type),
         {:ok, %{"blob" => blob}} <-
           Client.upload_blob(
             session.pds_url,
             session.authorization,
             body,
             mime_type
           ),
         true <- valid_blob?(blob, mime_type, byte_size(body)) do
      {:ok, Map.put(candidate, :blob, blob)}
    else
      false -> {:error, :atproto_blob_rejected}
      error -> error
    end
  end

  defp fetch(candidate) do
    with {:ok, %{status: 200, body: body, headers: headers}} <-
           HTTP.get(
             candidate.url,
             [{"accept", candidate.mime_type}],
             pool: :upload,
             recv_timeout: Config.get([Pleroma.ATProto, :blob_timeout_ms], 30_000)
           ),
         body when is_binary(body) <- normalize_body(body),
         mime_type when mime_type in @media_types <-
           response_mime_type(headers),
         true <- same_media_family?(candidate.mime_type, mime_type) do
      {:ok, body, mime_type}
    else
      _error -> {:error, :atproto_blob_fetch_failed}
    end
  end

  defp normalize_body(body) when is_binary(body), do: body

  defp normalize_body(body) when is_list(body) do
    IO.iodata_to_binary(body)
  rescue
    _error -> nil
  end

  defp normalize_body(_body), do: nil

  defp candidate(%{} = attachment) do
    mime_type = attachment["mediaType"] || attachment["mime_type"]

    attachment
    |> attachment_urls()
    |> Enum.map(fn %{url: url, mime_type: url_mime_type} ->
      %{
        url: url,
        mime_type: normalize_mime_type(mime_type || url_mime_type),
        alt: attachment_alt(attachment),
        aspect_ratio: aspect_ratio(attachment)
      }
    end)
  end

  defp candidate(_attachment), do: []

  defp attachment_urls(%{"url" => urls}) do
    urls
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"href" => "https://" <> _rest = href} = value ->
        [%{url: href, mime_type: value["mediaType"] || value["mime_type"]}]

      "https://" <> _rest = href ->
        [%{url: href, mime_type: nil}]

      _value ->
        []
    end)
  end

  defp attachment_urls(%{"href" => "https://" <> _rest = href} = value) do
    [%{url: href, mime_type: value["mediaType"] || value["mime_type"]}]
  end

  defp attachment_urls(_attachment), do: []

  defp attachment_alt(attachment) do
    (attachment["name"] || attachment["description"] || "")
    |> to_string()
    |> String.slice(0, @maximum_alt_characters)
  end

  defp aspect_ratio(attachment) do
    width = attachment["width"] || get_in(attachment, ["meta", "original", "width"])
    height = attachment["height"] || get_in(attachment, ["meta", "original", "height"])

    if is_integer(width) and is_integer(height) and width > 0 and height > 0 do
      %{"width" => width, "height" => height}
    end
  end

  defp image_embed(uploaded) do
    %{
      "$type" => "app.bsky.embed.images",
      "images" =>
        Enum.map(uploaded, fn item ->
          %{"alt" => item.alt, "image" => item.blob}
          |> maybe_put("aspectRatio", item.aspect_ratio)
        end)
    }
  end

  defp video_embed(item) do
    %{"$type" => "app.bsky.embed.video", "video" => item.blob, "alt" => item.alt}
    |> maybe_put("aspectRatio", item.aspect_ratio)
  end

  defp fallback_urls(all, selected) do
    selected_urls = MapSet.new(selected, & &1.url)
    all |> Enum.reject(&MapSet.member?(selected_urls, &1.url)) |> Enum.map(& &1.url)
  end

  defp trusted_local_url?(url) do
    with true <- URL.public_https_url?(url),
         %URI{host: host} when is_binary(host) <- URI.parse(url) do
      String.downcase(host) in trusted_media_hosts()
    else
      _error -> false
    end
  end

  defp trusted_media_hosts do
    endpoint_host = Pleroma.Web.Endpoint.url() |> URI.parse() |> Map.get(:host)

    configured =
      Config.get([Pleroma.ATProto, :blob_allowed_hosts], [])
      |> List.wrap()

    [endpoint_host | configured]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp response_mime_type(headers) do
    Enum.find_value(List.wrap(headers), fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == "content-type", do: normalize_mime_type(value)

      _header ->
        nil
    end)
  end

  defp normalize_mime_type(value) when is_binary(value) do
    value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp normalize_mime_type(_value), do: nil

  defp same_media_family?(left, right) do
    media_family(left) == media_family(right)
  end

  defp media_family(value), do: value |> String.split("/", parts: 2) |> hd()

  defp maximum_bytes(mime_type) when mime_type in @image_types, do: @maximum_image_bytes
  defp maximum_bytes(mime_type) when mime_type in @video_types, do: @maximum_video_bytes
  defp maximum_bytes(_mime_type), do: 0

  defp valid_blob?(
         %{
           "$type" => "blob",
           "ref" => %{"$link" => cid},
           "mimeType" => mime_type,
           "size" => size
         },
         expected_mime_type,
         expected_size
       )
       when is_binary(cid) and is_binary(mime_type) and is_integer(size) do
    mime_type == expected_mime_type and size == expected_size
  end

  defp valid_blob?(_blob, _mime_type, _size), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of atproto/blobs.ex
