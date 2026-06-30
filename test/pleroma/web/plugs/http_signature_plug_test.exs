# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.HTTPSignaturePlugTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.StubbedHTTPSignaturesMock, as: HTTPSignaturesMock
  alias Pleroma.Web.Plugs.HTTPSignaturePlug

  import Mox
  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]

  test "it call HTTPSignatures to check validity if the actor sighed it" do
    params = %{"actor" => "http://mastodon.example.org/users/admin"}
    conn = build_conn(:get, "/doesntmattter", params)

    expect(HTTPSignaturesMock, :validate_conn, fn _ -> true end)

    conn =
      conn
      |> put_req_header(
        "signature",
        "keyId=\"http://mastodon.example.org/users/admin#main-key"
      )
      |> put_format("activity+json")
      |> HTTPSignaturePlug.call(%{})

    assert conn.assigns.valid_signature == true
    assert conn.halted == false
  end

  describe "requires a signature when `authorized_fetch_mode` is enabled" do
    setup do
      clear_config([:activitypub, :authorized_fetch_mode], true)

      params = %{"actor" => "http://mastodon.example.org/users/admin"}
      conn = build_conn(:get, "/doesntmattter", params) |> put_format("activity+json")

      [conn: conn]
    end

    test "when signature header is present", %{conn: conn} do
      expect(HTTPSignaturesMock, :validate_conn, 2, fn _ -> false end)

      conn =
        conn
        |> put_req_header(
          "signature",
          "keyId=\"http://mastodon.example.org/users/admin#main-key"
        )
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == false
      assert conn.halted == true
      assert conn.status == 401
      assert conn.state == :sent
      assert conn.resp_body == "Request not signed"

      expect(HTTPSignaturesMock, :validate_conn, fn _ -> true end)

      conn =
        conn
        |> recycle()
        |> put_format("activity+json")
        |> put_req_header(
          "signature",
          "keyId=\"http://mastodon.example.org/users/admin#main-key"
        )
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == true
      assert conn.halted == false
    end

    test "halts the connection when `signature` header is not present", %{conn: conn} do
      conn = HTTPSignaturePlug.call(conn, %{})
      assert conn.assigns[:valid_signature] == nil
      assert conn.halted == true
      assert conn.status == 401
      assert conn.state == :sent
      assert conn.resp_body == "Request not signed"
    end

    test "does not raise when a valid signature maps to a malformed actor id", %{conn: conn} do
      conn =
        conn
        |> assign(:valid_signature, true)
        |> assign(:actor_id, "https://%")
        |> HTTPSignaturePlug.call(%{})

      refute conn.halted
    end
  end
end
