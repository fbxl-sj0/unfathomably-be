# Unfathomably: frontend asset path compatibility tests
#
# File: frontend_asset_path_plug_test.exs
#
# Purpose:
#   Prove that malformed nested Vite dependency paths recover without changing
#   unrelated request paths.
#
# This file intentionally does not test static-file contents.

defmodule Pleroma.Web.Plugs.FrontendAssetPathPlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Pleroma.Web.Plugs.FrontendAssetPathPlug

  test "normalizes a duplicated JavaScript dependency prefix" do
    conn = conn(:get, "/packs/js/packs/js/example.js")

    assert %Plug.Conn{
             path_info: ["packs", "js", "example.js"],
             request_path: "/packs/js/example.js"
           } =
             FrontendAssetPathPlug.call(conn, [])
  end

  test "normalizes a duplicated asset dependency prefix" do
    conn = conn(:get, "/packs/js/packs/assets/example.css")

    assert %Plug.Conn{
             path_info: ["packs", "assets", "example.css"],
             request_path: "/packs/assets/example.css"
           } =
             FrontendAssetPathPlug.call(conn, [])
  end

  test "leaves ordinary frontend and API paths unchanged" do
    for path <- ["/packs/js/example.js", "/api/v1/instance", "/packs/js/packs/other/file"] do
      conn = conn(:get, path)

      assert FrontendAssetPathPlug.call(conn, []).path_info == conn.path_info
    end
  end
end

# end of frontend_asset_path_plug_test.exs
