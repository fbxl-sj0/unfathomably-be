# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.SetFormatPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Pleroma.Web.Plugs.SetFormatPlug

  test "set format from params" do
    conn =
      :get
      |> conn("/cofe?_format=json")
      |> SetFormatPlug.call([])

    assert %{format: "json"} == conn.assigns
  end

  test "set format from header" do
    conn =
      :get
      |> conn("/cofe")
      |> put_private(:phoenix_format, "xml")
      |> SetFormatPlug.call([])

    assert %{format: "xml"} == conn.assigns
  end

  test "doesn't set format" do
    conn =
      :get
      |> conn("/cofe")
      |> SetFormatPlug.call([])

    refute conn.assigns[:format]
  end

  test "varies negotiated responses on Accept" do
    conn =
      :get
      |> conn("/cofe")
      |> SetFormatPlug.call([])
      |> send_resp(200, "")

    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "preserves existing response variation" do
    conn =
      :get
      |> conn("/cofe")
      |> put_resp_header("vary", "Authorization, Signature")
      |> SetFormatPlug.call([])
      |> send_resp(200, "")

    assert get_resp_header(conn, "vary") == ["Authorization, Signature, Accept"]
  end

  test "selects ActivityPub from a parameterized Accept list" do
    conn =
      :get
      |> conn("/cofe")
      |> put_private(:phoenix_format, "html")
      |> put_req_header(
        "accept",
        "text/html;q=0, application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\";q=0.8"
      )
      |> SetFormatPlug.call([])

    assert conn.assigns.format == "activity+json"
  end

  test "does not select an explicitly unacceptable ActivityPub range" do
    conn =
      :get
      |> conn("/cofe")
      |> put_private(:phoenix_format, "html")
      |> put_req_header("accept", "application/activity+json;q=0, text/html;q=1")
      |> SetFormatPlug.call([])

    assert conn.assigns.format == "html"
  end
end
