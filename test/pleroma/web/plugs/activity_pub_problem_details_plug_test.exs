# Unfathomably ActivityPub error response tests
# ----------------------------------------------
#
# File: activity_pub_problem_details_plug_test.exs
#
# Purpose:
#   Cover the ActivityPub-only Problem Details response boundary.
#
# Responsibilities:
#   - prove structured errors become Problem Details documents
#   - prove successful responses are not rewritten
#   - prove HTTP 410 Tombstone representations remain ActivityStreams objects
#
# This file intentionally does not exercise controller routing or Mastodon API
# error formats.

defmodule Pleroma.Web.Plugs.ActivityPubProblemDetailsPlugTest do
  use Pleroma.Web.ConnCase, async: true

  alias Pleroma.Web.Plugs.ActivityPubProblemDetailsPlug

  test "formats structured ActivityPub errors as Problem Details", %{conn: conn} do
    conn =
      conn
      |> Map.put(:request_path, "/users/missing/outbox")
      |> ActivityPubProblemDetailsPlug.call([])
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{"error" => "Actor not found"}))

    assert ["application/problem+json; charset=utf-8"] =
             get_resp_header(conn, "content-type")

    assert %{
             "type" => "about:blank",
             "title" => "Not Found",
             "status" => 404,
             "detail" => "Actor not found",
             "instance" => "/users/missing/outbox",
             "metadata" => %{"error" => "Actor not found"}
           } = Jason.decode!(conn.resp_body)
  end

  test "preserves ActivityStreams Tombstones", %{conn: conn} do
    body =
      Jason.encode!(%{
        "id" => "https://example.test/objects/deleted",
        "type" => "Tombstone"
      })

    conn =
      conn
      |> ActivityPubProblemDetailsPlug.call([])
      |> put_resp_content_type("application/activity+json")
      |> send_resp(410, body)

    assert conn.resp_body == body

    assert ["application/activity+json; charset=utf-8"] =
             get_resp_header(conn, "content-type")
  end

  test "does not rewrite successful ActivityPub responses", %{conn: conn} do
    body = Jason.encode!(%{"type" => "Person"})

    conn =
      conn
      |> ActivityPubProblemDetailsPlug.call([])
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, body)

    assert conn.resp_body == body

    assert ["application/activity+json; charset=utf-8"] =
             get_resp_header(conn, "content-type")
  end
end

# end of activity_pub_problem_details_plug_test.exs
