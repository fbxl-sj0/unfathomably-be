# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.HTTPSignaturePlugTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Signature
  alias Pleroma.StubbedHTTPSignaturesMock, as: HTTPSignaturesMock
  alias Pleroma.Web.Plugs.HTTPSignaturePlug

  import ExUnit.CaptureLog
  import Mox
  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]

  defp put_valid_legacy_signature(conn, key_id) do
    conn
    |> put_req_header("date", Signature.signed_date())
    |> put_req_header(
      "signature",
      ~s|keyId="#{key_id}",algorithm="rsa-sha256",headers="(request-target) host date",signature="dGVzdA=="|
    )
  end

  test "logs activity context when a signing key is temporarily unavailable" do
    conn =
      build_conn(:post, "/inbox", %{
        "actor" => "https://remote.example/users/alice",
        "id" => "https://remote.example/activities/1",
        "type" => "Create"
      })
      |> put_format("activity+json")
      |> assign(:signature_error, :key_unavailable)
      |> assign(:actor_id, "https://remote.example/users/alice")

    log =
      capture_log(fn ->
        conn = HTTPSignaturePlug.call(conn, %{})

        assert conn.halted
        assert conn.status == 503
        assert conn.resp_body == "Signing key temporarily unavailable"
      end)

    assert log =~ "Signing key temporarily unavailable"
    assert log =~ "claimed_actor=\"https://remote.example/users/alice\""
    assert log =~ "activity_id=\"https://remote.example/activities/1\""
  end

  test "logs activity context when a malformed signature is rejected" do
    conn =
      build_conn(:post, "/inbox", %{
        "actor" => "https://remote.example/users/alice",
        "id" => "https://remote.example/activities/malformed",
        "type" => "Create"
      })
      |> put_format("activity+json")
      |> assign(:signature_error, :malformed_signature)
      |> assign(:actor_id, "https://remote.example/users/alice")

    log =
      capture_log(fn ->
        conn = HTTPSignaturePlug.call(conn, %{})

        assert conn.halted
        assert conn.status == 400
        assert conn.resp_body == "Malformed HTTP Signature"
      end)

    assert log =~ "Malformed HTTP Signature"
    assert log =~ "reason=:malformed_signature"
    assert log =~ "claimed_actor=\"https://remote.example/users/alice\""
    assert log =~ "activity_id=\"https://remote.example/activities/malformed\""
  end

  test "acknowledges an unavailable-key self-delete for an unknown actor" do
    actor = "https://remote.example/users/deleted"

    conn =
      build_conn(:post, "/inbox", %{
        "actor" => actor,
        "id" => actor <> "#delete",
        "object" => actor,
        "type" => "Delete"
      })
      |> put_format("activity+json")
      |> assign(:signature_error, :key_unavailable)
      |> assign(:actor_id, actor)
      |> HTTPSignaturePlug.call(%{})

    assert conn.halted
    assert conn.status == 202
    assert conn.resp_body == "Delete acknowledged for unknown actor"
  end

  test "does not acknowledge an unavailable-key Delete for another object" do
    actor = "https://remote.example/users/deleted"

    conn =
      build_conn(:post, "/inbox", %{
        "actor" => actor,
        "id" => actor <> "#delete",
        "object" => "https://remote.example/users/someone-else",
        "type" => "Delete"
      })
      |> put_format("activity+json")
      |> assign(:signature_error, :key_unavailable)
      |> assign(:actor_id, actor)
      |> HTTPSignaturePlug.call(%{})

    assert conn.halted
    assert conn.status == 503
    assert conn.resp_body == "Signing key temporarily unavailable"
  end

  test "it call HTTPSignatures to check validity if the actor sighed it" do
    params = %{"actor" => "http://mastodon.example.org/users/admin"}
    conn = build_conn(:get, "/doesntmattter", params)

    expect(HTTPSignaturesMock, :validate_conn, fn _ -> true end)

    conn =
      conn
      |> put_valid_legacy_signature("http://mastodon.example.org/users/admin#main-key")
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
        |> put_valid_legacy_signature("http://mastodon.example.org/users/admin#main-key")
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
        |> put_valid_legacy_signature("http://mastodon.example.org/users/admin#main-key")
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

  describe "hybrid authorized fetch" do
    setup do
      clear_config([:activitypub, :authorized_fetch_mode], :essential)
      :ok
    end

    test "allows an unsigned actor root only as a restricted representation" do
      conn =
        build_conn(:get, "/users/alice")
        |> put_format("activity+json")
        |> HTTPSignaturePlug.call(%{})

      refute conn.halted
      assert conn.assigns.authorized_fetch_redacted
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "vary") == ["Accept, Authorization, Signature"]
    end

    test "continues to require signatures for objects and actor collections" do
      for path <- ["/objects/123", "/users/alice/outbox", "/users/alice/followers"] do
        conn =
          build_conn(:get, path)
          |> put_format("activity+json")
          |> HTTPSignaturePlug.call(%{})

        assert conn.halted
        assert conn.status == 401
        assert conn.resp_body == "Request not signed"
      end
    end

    test "returns the full representation marker for a valid signed actor fetch" do
      expect(HTTPSignaturesMock, :validate_conn, fn _ -> true end)

      conn =
        build_conn(:get, "/users/alice")
        |> put_format("activity+json")
        |> put_valid_legacy_signature("http://mastodon.example.org/users/admin#main-key")
        |> HTTPSignaturePlug.call(%{})

      refute conn.halted
      assert conn.assigns.valid_signature
      refute conn.assigns[:authorized_fetch_redacted]
    end
  end
end
