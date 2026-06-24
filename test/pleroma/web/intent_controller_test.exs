# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.IntentControllerTest do
  use Pleroma.Web.ConnCase

  describe "GET /intent" do
    test "redirects Mastodon follow intents to remote interaction", %{conn: conn} do
      conn = get(conn, "/intent", %{"uri" => "web+mastodon://follow?uri=acct:alice@example.org"})

      assert redirected_to(conn) == "/authorize_interaction?uri=alice%40example.org"
    end

    test "redirects Mastodon share intents to the frontend share route", %{conn: conn} do
      conn = get(conn, "/intent", %{"uri" => "web+mastodon://share?text=hello"})

      assert redirected_to(conn) == "/share?text=hello"
    end

    test "returns not found for unsupported intent URIs", %{conn: conn} do
      conn = get(conn, "/intent", %{"uri" => "web+mastodon://unknown?uri=test"})

      assert response(conn, 404) == "Not Found"
    end

    test "returns not found for non-Mastodon URI schemes", %{conn: conn} do
      conn = get(conn, "/intent", %{"uri" => "https://example.org/"})

      assert response(conn, 404) == "Not Found"
    end
  end
end
