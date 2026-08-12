# Unfathomably Mastodon API pagination
# ------------------------------------
#
# File: test/pleroma/web/controller_helper_test.exs
#
# Purpose:
#   Verify stable Link-header generation at page boundaries.
#
# Responsibilities:
#   - emit continuation links only when a complete page was returned
#   - derive the descending continuation cursor from the oldest item
#   - keep empty pages free of fabricated cursors
#
# This file intentionally does NOT test database query ordering or individual
# timeline visibility policies.

defmodule Pleroma.Web.ControllerHelperTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Pleroma.Pagination
  alias Pleroma.Web.ControllerHelper

  test "a full descending page links next from its oldest item" do
    conn = request_conn(%{"limit" => "2"})

    conn = ControllerHelper.add_link_headers(conn, [%{id: "30"}, %{id: "20"}])

    assert [header] = get_resp_header(conn, "link")
    assert header =~ "max_id=20"
    assert header =~ "rel=\"next\""
    assert header =~ "rel=\"prev\""
  end

  test "a short page has no false next cursor" do
    conn = request_conn(%{"limit" => "2"})

    conn = ControllerHelper.add_link_headers(conn, [%{id: "20"}])

    assert [header] = get_resp_header(conn, "link")
    refute header =~ "rel=\"next\""
    assert header =~ "rel=\"prev\""
  end

  test "an empty page has no Link header" do
    conn = request_conn(%{"limit" => "2"})

    conn = ControllerHelper.add_link_headers(conn, [])

    assert get_resp_header(conn, "link") == []
    assert ControllerHelper.get_pagination_fields(conn, []) == %{}
  end

  test "invalid and excessive limits resolve to safe bounds" do
    assert Pagination.page_limit(%{"limit" => "-5"}) == 20
    assert Pagination.page_limit(%{"limit" => "5000"}) == 40
  end

  defp request_conn(params) do
    conn = conn(:get, "/api/v1/timelines/home")
    %{conn | params: params}
  end
end

# end of test/pleroma/web/controller_helper_test.exs
