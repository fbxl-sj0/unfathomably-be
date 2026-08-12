# Unfathomably BE
# ----------------
#
# File: atproto/media.ex
#
# Purpose:
#   Convert bounded Bluesky AppView embeds into ActivityPub attachments.
#
# Responsibilities:
#   - retain image, video, and external-card presentation data
#   - accept only public HTTPS references returned by the configured AppView
#   - cap attachment counts and text sizes
#
# This file intentionally does NOT download blobs, proxy media, or interpret
# arbitrary third-party embed types.

defmodule Pleroma.ATProto.Media do
  alias Pleroma.ATProto.URL

  @max_attachments 16

  def put_attachments(object, post) when is_map(object) do
    case attachments(post) do
      [] -> object
      attachments -> Map.put(object, "attachment", attachments)
    end
  end

  def attachments(%{"embed" => %{} = embed}) do
    embed
    |> candidates()
    |> Enum.take(@max_attachments)
    |> Enum.flat_map(&attachment/1)
  end

  def attachments(_post), do: []

  defp candidates(%{"images" => images}) when is_list(images), do: Enum.map(images, &{:image, &1})

  defp candidates(%{"media" => media} = embed) when is_map(media) do
    candidates(media) ++ candidates(Map.drop(embed, ["media"]))
  end

  defp candidates(%{"playlist" => _url} = video), do: [{:video, video}]
  defp candidates(%{"external" => %{} = external}), do: [{:external, external}]
  defp candidates(_embed), do: []

  defp attachment({:image, image}) do
    with url when is_binary(url) <- image["fullsize"] || image["thumb"],
         true <- URL.public_https_url?(url) do
      link = %{"href" => url, "mediaType" => "image/*"} |> put_dimensions(image["aspectRatio"])

      [
        %{
          "type" => "Document",
          "mediaType" => "image/*",
          "name" => bounded_text(image["alt"], 1_500),
          "url" => [link]
        }
      ]
    else
      _ -> []
    end
  end

  defp attachment({:video, video}) do
    with url when is_binary(url) <- video["playlist"],
         true <- URL.public_https_url?(url) do
      [
        %{
          "type" => "Document",
          "mediaType" => "application/vnd.apple.mpegurl",
          "name" => bounded_text(video["alt"], 1_500),
          "url" => [%{"href" => url, "mediaType" => "application/vnd.apple.mpegurl"}]
        }
      ]
    else
      _ -> []
    end
  end

  defp attachment({:external, external}) do
    with url when is_binary(url) <- external["uri"],
         true <- URL.public_https_url?(url) do
      [
        %{
          "type" => "Link",
          "href" => url,
          "name" => bounded_text(external["title"], 300),
          "summary" => bounded_text(external["description"], 1_500)
        }
      ]
    else
      _ -> []
    end
  end

  defp put_dimensions(link, %{"width" => width, "height" => height})
       when width in 1..32_768 and height in 1..32_768 do
    Map.merge(link, %{"width" => width, "height" => height})
  end

  defp put_dimensions(link, _aspect_ratio), do: link

  defp bounded_text(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp bounded_text(_value, _limit), do: nil
end

# end of atproto/media.ex
