# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/blobs_test.exs
#
# Purpose:
#   Verify bounded local-media uploads to linked AT Protocol repositories.
#
# Responsibilities:
#   - accept explicitly configured HTTPS media hosts
#   - preserve alt text and image dimensions in native Bluesky embeds
#   - verify the PDS blob descriptor against the uploaded bytes
#   - reject arbitrary attachment hosts before issuing an HTTP request
#
# This file intentionally does NOT contact a public PDS or upload live media.

defmodule Pleroma.ATProto.BlobsTest do
  use Pleroma.DataCase, async: false

  import Tesla.Mock

  alias Pleroma.ATProto.Blobs

  @body <<0xFF, 0xD8, 0xFF, 0xD9>>
  @media_url "https://media.example.com/photo.jpg"
  @pds_url "https://pds.example.com"

  setup do
    clear_config([Pleroma.ATProto, :blob_allowed_hosts], ["media.example.com"])
  end

  test "uploads trusted local images and builds a native image embed" do
    blob = %{
      "$type" => "blob",
      "ref" => %{"$link" => "bafkreiexample"},
      "mimeType" => "image/jpeg",
      "size" => byte_size(@body)
    }

    mock(fn env ->
      case {env.method, env.url} do
        {:get, @media_url} ->
          %Tesla.Env{
            status: 200,
            body: @body,
            headers: [{"content-type", "image/jpeg; charset=binary"}]
          }

        {:post, @pds_url <> "/xrpc/com.atproto.repo.uploadBlob"} ->
          assert env.body == @body
          assert {"content-type", "image/jpeg"} in env.headers
          json(%{"blob" => blob})

        _request ->
          %Tesla.Env{status: 404, body: Jason.encode!(%{"error" => "NotFound"})}
      end
    end)

    attachment = %{
      "mediaType" => "image/jpeg",
      "url" => [%{"href" => @media_url, "mediaType" => "image/jpeg"}],
      "description" => "A small test image",
      "width" => 640,
      "height" => 480
    }

    session = %{pds_url: @pds_url, authorization: {:bearer, "access-token"}}

    assert {:ok,
            %{
              "$type" => "app.bsky.embed.images",
              "images" => [
                %{
                  "alt" => "A small test image",
                  "aspectRatio" => %{"width" => 640, "height" => 480},
                  "image" => ^blob
                }
              ]
            }, []} = Blobs.prepare([attachment], session)
  end

  test "rejects arbitrary media hosts before fetching them" do
    mock(fn _env -> flunk("untrusted media must not be fetched") end)

    attachment = %{
      "mediaType" => "image/jpeg",
      "url" => [%{"href" => "https://remote.example.net/photo.jpg"}]
    }

    session = %{pds_url: @pds_url, authorization: {:bearer, "access-token"}}

    assert {:error, :atproto_blob_rejected} = Blobs.prepare([attachment], session)
  end
end

# end of test/pleroma/atproto/blobs_test.exs
