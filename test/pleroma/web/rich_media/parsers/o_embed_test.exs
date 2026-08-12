# Unfathomably: rich media parser tests
#
# File: o_embed_test.exs
#
# Purpose:
#   Verify that untrusted oEmbed JSON is reduced to bounded scalar fields before
#   it can enter rich-media card storage or Mastodon API responses.
#
# This file intentionally does not perform network requests. HTTP transport and
# redirect policy are covered at the shared rich-media helper boundary.

defmodule Pleroma.Web.RichMedia.Parsers.OEmbedTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.RichMedia.Parsers.OEmbed

  test "keeps bounded scalar metadata and ignores hostile field shapes" do
    data = %{
      "type" => "video",
      "title" => "  Example video  ",
      "html" => "<iframe src=\"https://video.example/embed/1\"></iframe>",
      "author_name" => %{"name" => "not a scalar"},
      "author_url" => ["https://video.example/@author"],
      "provider_name" => "Example Video",
      "provider_url" => "https://video.example",
      "thumbnail_url" => "https://video.example/thumb.jpg",
      "width" => 640,
      "height" => 360,
      "logo" => %{"url" => "https://video.example/logo.png"},
      "unknown" => %{"deep" => ["untrusted"]}
    }

    assert {:ok, normalized} = OEmbed.normalize_data(data)
    assert normalized["title"] == "Example video"
    assert normalized["provider_name"] == "Example Video"
    assert normalized["width"] == 640
    assert normalized["height"] == 360
    refute Map.has_key?(normalized, "author_name")
    refute Map.has_key?(normalized, "author_url")
    refute Map.has_key?(normalized, "logo")
    refute Map.has_key?(normalized, "unknown")
  end

  test "rejects missing embed HTML and unsupported types" do
    assert {:error, :invalid_oembed_metadata} =
             OEmbed.normalize_data(%{"type" => "video", "title" => "No embed"})

    assert {:error, :invalid_oembed_metadata} =
             OEmbed.normalize_data(%{
               "type" => "arbitrary",
               "title" => "Unknown",
               "html" => "<div>unknown</div>"
             })
  end

  test "drops unreasonable dimensions and truncates oversized text" do
    assert {:ok, normalized} =
             OEmbed.normalize_data(%{
               "type" => "rich",
               "title" => String.duplicate("x", 2_000),
               "html" => "<iframe></iframe>",
               "width" => 1_000_000,
               "height" => -1
             })

    assert String.length(normalized["title"]) == 1_000
    refute Map.has_key?(normalized, "width")
    refute Map.has_key?(normalized, "height")
  end
end

# end of o_embed_test.exs
