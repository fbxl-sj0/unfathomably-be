# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/bridge_test.exs
#
# Purpose:
#   Verify display-safe projection of Bluesky AppView posts.
#
# Responsibilities:
#   - retain ordinary post text without alteration
#   - provide a canonical display fallback for media-only posts
#
# This file intentionally does NOT contact an AppView or write projected posts.

defmodule Pleroma.ATProto.BridgeTest do
  use ExUnit.Case, async: true

  alias Pleroma.ATProto.Bridge

  @uri "at://did:plc:alice/app.bsky.feed.post/3lexample"

  test "retains ordinary post text" do
    post = %{
      "uri" => @uri,
      "author" => %{"handle" => "alice.example"},
      "record" => %{"text" => "ordinary post"}
    }

    assert Bridge.display_text(post) == "ordinary post"
  end

  test "uses the canonical post URL when a media-only post has no text" do
    post = %{
      "uri" => @uri,
      "author" => %{"handle" => "alice.example"},
      "record" => %{"text" => "  \n"},
      "embed" => %{"images" => [%{"fullsize" => "https://cdn.bsky.app/image.jpg"}]}
    }

    assert Bridge.display_text(post) ==
             "https://bsky.app/profile/alice.example/post/3lexample"
  end
end

# end of test/pleroma/atproto/bridge_test.exs
