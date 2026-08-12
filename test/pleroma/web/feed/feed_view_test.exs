# Unfathomably BE
# ----------------
#
# File: feed/feed_view_test.exs
#
# Purpose:
#   Cover media-description selection for RSS and Atom feed output.
#
# Responsibilities:
#   - prefer ActivityStreams summary alt text over an attachment label
#   - retain name as a compatibility fallback
#   - reject blank values before choosing a description
#
# This file intentionally does NOT test feed routing or XML serialization.

defmodule Pleroma.Web.Feed.FeedViewTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.Feed.FeedView

  test "prefers a nonblank summary and falls back to name" do
    assert FeedView.attachment_description(%{
             "summary" => "Detailed alternative text",
             "name" => "camera-file.jpg"
           }) == "Detailed alternative text"

    assert FeedView.attachment_description(%{
             "summary" => "  ",
             "name" => "Fallback description"
           }) == "Fallback description"

    assert FeedView.attachment_description(%{}) == ""
  end
end

# end of feed/feed_view_test.exs
