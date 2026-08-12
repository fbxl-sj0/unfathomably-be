# Unfathomably: remote media representation normalization tests
#
# File: audio_image_video_attachment_test.exs
#
# Purpose:
#   Prove that media objects select bounded, typed HTTP representations without
#   crashing on malformed peer-controlled URL entries.
#
# This file intentionally does not perform remote network requests.

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AudioImageVideoAttachmentTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.ObjectValidators.AudioImageVideoValidator

  test "selects valid media and page representations from a mixed URL list" do
    assert {:ok, video} =
             valid_video(%{
               "url" => [
                 nil,
                 %{"href" => "javascript:alert(1)", "mediaType" => "video/mp4"},
                 %{
                   "href" => "https://video.example/media/watch.mp4",
                   "mediaType" => "video/mp4"
                 },
                 %{
                   "href" => "https://video.example/watch/1",
                   "mediaType" => "text/html"
                 }
               ]
             })
             |> AudioImageVideoValidator.cast_and_apply()

    assert video.url == "https://video.example/watch/1"
    assert [%{mediaType: "video/mp4"}] = video.attachment
  end

  test "rejects a media object with no safe media representation without crashing" do
    assert {:error, _changeset} =
             valid_video(%{
               "url" => [
                 %{"href" => "data:video/mp4;base64,AAAA", "mediaType" => "video/mp4"},
                 %{"href" => "https://video.example/watch/1", "mediaType" => 42}
               ]
             })
             |> AudioImageVideoValidator.cast_and_apply()
  end

  defp valid_video(extra) do
    Map.merge(
      %{
        "actor" => "https://video.example/accounts/alice",
        "attributedTo" => "https://video.example/accounts/alice",
        "cc" => [],
        "context" => "https://video.example/watch/1",
        "id" => "https://video.example/watch/1",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "type" => "Video"
      },
      extra
    )
  end
end

# end of audio_image_video_attachment_test.exs
