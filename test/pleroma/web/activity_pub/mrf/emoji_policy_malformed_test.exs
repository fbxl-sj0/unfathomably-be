# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.EmojiPolicyMalformedTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.MRF.EmojiPolicy

  require Pleroma.Constants

  setup do
    clear_config([:mrf_emoji], %{
      remove_url: [],
      remove_shortcode: [],
      federated_timeline_removal_url: [],
      federated_timeline_removal_shortcode: []
    })
  end

  test "normalizes map-shaped tags and malformed emoji maps while removing blocked emoji" do
    blocked_url = "https://blocked.example/emoji.png"

    clear_config([:mrf_emoji, :remove_url], [blocked_url])

    activity = %{
      "type" => "Create",
      "object" => %{
        "type" => "Note",
        "tag" => %{
          "type" => "Emoji",
          "name" => ":blocked:",
          "icon" => %{"url" => blocked_url}
        },
        "emoji" => %{
          "blocked" => blocked_url,
          "malformed" => nil
        }
      },
      "to" => [Pleroma.Constants.as_public()],
      "cc" => []
    }

    assert {:ok, filtered} = EmojiPolicy.filter(activity)
    assert filtered["object"]["tag"] == []
    assert filtered["object"]["emoji"] == %{}
  end

  test "normalizes malformed recipients when removing emoji from federated timelines" do
    blocked_url = "https://blocked.example/emoji.png"
    public = Pleroma.Constants.as_public()

    clear_config([:mrf_emoji, :federated_timeline_removal_url], [blocked_url])

    activity = %{
      "type" => "Create",
      "object" => %{
        "type" => "Note",
        "tag" => [
          %{
            "type" => "Emoji",
            "name" => ":blocked:",
            "icon" => %{"url" => blocked_url}
          },
          nil,
          42
        ],
        "emoji" => %{}
      },
      "to" => [%{"id" => public}, nil, %{"href" => "https://example.com/users/alice"}],
      "cc" => %{"id" => "https://example.com/users/bob"}
    }

    assert {:ok, filtered} = EmojiPolicy.filter(activity)
    assert filtered["to"] == ["https://example.com/users/alice"]
    assert filtered["cc"] == [public, "https://example.com/users/bob"]
  end
end

# end of emoji_policy_malformed_test.exs
