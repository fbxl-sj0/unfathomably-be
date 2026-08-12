# Unfathomably HTTP media negotiation
# ------------------------------------
#
# File: test/pleroma/web/media_type_test.exs
#
# Purpose:
#   Verify interoperable, bounded media-header parsing.
#
# Responsibilities:
#   - cover lists, parameters, separate header lines, and quality values
#   - prove malformed, oversized, and unacceptable ranges fail closed
#
# This file intentionally does NOT test controller rendering or response-body
# decoding.

defmodule Pleroma.Web.MediaTypeTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.MediaType

  @activity_types [{"application", "activity+json"}, {"application", "ld+json"}]

  test "matches allowed media types in lists with parameters" do
    assert {"application", "ld+json", params} =
             MediaType.match(
               "text/html;q=0.2, application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"; q=0.9",
               @activity_types
             )

    assert params["q"] == "0.9"
  end

  test "matches across separate header lines" do
    assert {"application", "activity+json", _params} =
             MediaType.match(
               ["text/html", "application/activity+json; charset=utf-8"],
               @activity_types
             )
  end

  test "rejects zero, malformed, and oversized ranges" do
    assert MediaType.match("application/activity+json;q=0", @activity_types) == nil
    assert MediaType.match("application/activity+json;q=invalid", @activity_types) == nil

    assert MediaType.match(
             "application/activity+json; padding=#{String.duplicate("x", 8_192)}",
             @activity_types
           ) == nil
  end
end

# end of test/pleroma/web/media_type_test.exs
