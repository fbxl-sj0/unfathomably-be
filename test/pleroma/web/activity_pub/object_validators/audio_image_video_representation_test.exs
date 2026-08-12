# Project: Unfathomably ActivityPub Test Suite
# --------------------------------------------
#
# File: audio_image_video_representation_test.exs
#
# Purpose:
#
#     Protect native media-object author and representation normalization.
#
# Responsibilities:
#
#     * select the playable representation matching the object type
#     * preserve existing attachment metadata
#     * normalize array attribution to the authoritative author
#
# This file intentionally does NOT contain:
#
#     * media downloads
#     * frontend player tests
#     * live PeerTube requests

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AudioImageVideoRepresentationTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.ObjectValidators.AudioImageVideoValidator

  require Pleroma.Constants

  test "preserves caption metadata while selecting a playable Video URL" do
    author = "https://video.example/users/alice"

    data = %{
      "id" => "https://video.example/videos/1",
      "type" => "Video",
      "attributedTo" => [
        %{"id" => "https://video.example/groups/channel", "type" => "Group"},
        %{"id" => author, "type" => "Person"}
      ],
      "to" => [Pleroma.Constants.as_public()],
      "url" => [
        %{
          "type" => "Link",
          "href" => "https://video.example/media/1.mp4",
          "mediaType" => "video/mp4",
          "height" => 720
        },
        %{
          "type" => "Link",
          "href" => "https://video.example/watch/1",
          "mediaType" => "text/html"
        }
      ],
      "attachment" => [
        %{
          "type" => "Link",
          "name" => "English captions",
          "mediaType" => "text/vtt",
          "href" => "https://video.example/captions/1.vtt"
        }
      ]
    }

    assert {:ok, video} = AudioImageVideoValidator.cast_and_apply(data)
    assert video.actor == author
    assert video.attributedTo == author
    assert length(video.attachment) == 2
    assert Enum.any?(video.attachment, &(&1.mediaType == "video/mp4"))
    assert Enum.any?(video.attachment, &(&1.mediaType == "text/vtt"))
  end
end

# end of audio_image_video_representation_test.exs
