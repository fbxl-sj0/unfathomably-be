# Project: Unfathomably ActivityPub compatibility
#
# File: live_video_metadata_test.exs
#
# Purpose: Cover bounded PeerTube-style scheduled live video metadata.
#
# Responsibilities:
#   * retain a same-origin embed URL and parseable schedule times
#   * discard cross-origin embeds and malformed or excessive schedules
#
# This file intentionally does not fetch a player, stream, or schedule URL.

defmodule Pleroma.Web.ActivityPub.ObjectValidators.LiveVideoMetadataTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.ObjectValidators.AudioImageVideoValidator

  test "retains bounded live video metadata" do
    schedules =
      for day <- 1..6 do
        %{"startDate" => "2026-08-0#{day}T18:00:00Z", "ignored" => String.duplicate("x", 20)}
      end

    assert {:ok, video} =
             valid_video(%{
               "embedUrl" => "https://video.example/videos/embed/abc",
               "isLiveBroadcast" => true,
               "schedules" => schedules ++ [%{"startDate" => "not-a-date"}]
             })
             |> AudioImageVideoValidator.cast_and_apply()

    assert video.embedUrl == "https://video.example/videos/embed/abc"
    assert video.isLiveBroadcast
    assert length(video.schedules) == 4
    assert Enum.all?(video.schedules, &Map.has_key?(&1, "startDate"))
    refute Enum.any?(video.schedules, &Map.has_key?(&1, "ignored"))
  end

  test "rejects a cross-origin live video embed" do
    assert {:ok, video} =
             valid_video(%{"embedUrl" => "https://tracker.example/embed/abc"})
             |> AudioImageVideoValidator.cast_and_apply()

    assert is_nil(video.embedUrl)
  end

  defp valid_video(extra) do
    Map.merge(
      %{
        "actor" => "https://video.example/accounts/alice",
        "attachment" => [
          %{
            "type" => "Video",
            "mediaType" => "video/mp4",
            "url" => "https://video.example/static/abc.mp4"
          }
        ],
        "attributedTo" => "https://video.example/accounts/alice",
        "cc" => [],
        "context" => "https://video.example/videos/watch/abc",
        "id" => "https://video.example/videos/watch/abc",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "type" => "Video",
        "url" => "https://video.example/videos/watch/abc"
      },
      extra
    )
  end
end

# end of live_video_metadata_test.exs
