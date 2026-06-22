# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.FaviconPlugTest do
  use Pleroma.Web.ConnCase

  @dir "test/tmp/favicon_static"

  setup do
    File.mkdir_p!(@dir)
    on_exit(fn -> File.rm_rf!(@dir) end)
  end

  describe "default favicon" do
    test "returns favicon", %{conn: conn} do
      conn = get(conn, "/favicon.png")

      assert conn.status == 200
      assert byte_size(conn.resp_body) > 0
      assert response_content_type(conn, :png)
    end

    test "returns correct cache-control", %{conn: conn} do
      conn = get(conn, "/favicon.png")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["public, max-age=86400, immutable"]
    end
  end

  describe "custom favicon" do
    setup do
      favicon_path = Path.join(@dir, "favicon.png")
      File.cp!("test/fixtures/image.png", favicon_path)
      clear_config([:instance, :static_dir], @dir)
    end

    test "returns favicon", %{conn: conn} do
      conn = get(conn, "/favicon.png")

      assert conn.status == 200
      assert byte_size(conn.resp_body) > 0
      assert response_content_type(conn, :png)
    end

    test "returns correct cache-control", %{conn: conn} do
      conn = get(conn, "/favicon.png")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["public, max-age=86400, immutable"]
    end
  end
end
