# Unfathomably BE
# ----------------
#
# File: manifest_controller_test.exs
#
# Purpose:
#   Cover the public web-app manifest response contract.
#
# Responsibilities:
#   - prove direct browser navigation can request the JSON manifest
#   - preserve the manifest content type
#
# This file intentionally does not inspect frontend service-worker behavior.

defmodule Pleroma.Web.ManifestControllerTest do
  use Pleroma.Web.ConnCase

  test "serves the JSON manifest when a browser also accepts HTML", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/html,application/xhtml+xml")
      |> get("/manifest.json")

    manifest = json_response(conn, 200)

    assert manifest["name"]

    assert %{
             "protocol" => "web+ap",
             "url" => "/activitypub/externalInteraction?uri=%s"
           } in manifest["protocol_handlers"]

    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end
end

# end of test/pleroma/web/manifest_controller_test.exs
