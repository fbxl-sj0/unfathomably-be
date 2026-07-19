# Pleroma: A lightweight social networking server
# SPDX-FileCopyrightText: 2026 Unfathomably Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.MessageSignaturesTest do
  use ExUnit.Case, async: true

  alias Pleroma.HTTP.MessageSignatures
  alias Pleroma.Keys
  alias Pleroma.Web.Endpoint

  defp signed_conn(body, opts \\ []) do
    {:ok, pem} = Keys.generate_rsa_pem()
    {:ok, private_key, public_key} = Keys.keys_from_pem(pem)
    digest = MessageSignatures.content_digest(body)
    path = Keyword.get(opts, :path, "/inbox")
    scheme = Endpoint.url() |> URI.parse() |> Map.fetch!(:scheme)
    target_uri = "#{scheme}://example.com#{path}"

    {:ok, signature_headers} =
      MessageSignatures.sign(
        private_key,
        "https://remote.example/users/alice#main-key",
        "POST",
        target_uri,
        %{"content-digest" => digest},
        Keyword.take(opts, [:created])
      )

    req_headers =
      [
        {"host", "example.com"},
        {"content-digest", digest}
      ] ++
        Enum.map(signature_headers, fn {name, value} ->
          {String.downcase(name), value}
        end)

    conn = %Plug.Conn{
      assigns: %{content_digest_valid: Keyword.get(opts, :digest_valid, true)},
      method: "POST",
      request_path: path,
      query_string: "",
      req_headers: req_headers
    }

    {conn, public_key}
  end

  test "signs and validates an RFC 9421 ActivityPub request" do
    {conn, public_key} = signed_conn("{}")

    assert MessageSignatures.validate(conn, public_key)

    assert MessageSignatures.key_id(conn) ==
             {:ok, "https://remote.example/users/alice#main-key"}
  end

  test "rejects a signature when the parsed body digest did not match" do
    {conn, public_key} = signed_conn("{}", digest_valid: false)

    refute MessageSignatures.validate(conn, public_key)
  end

  test "rejects signatures outside the replay window" do
    created = System.system_time(:second) - :timer.hours(2) |> div(1000)
    {conn, public_key} = signed_conn("{}", created: created)

    refute MessageSignatures.validate(conn, public_key)
  end

  test "rejects duplicate signature labels" do
    {conn, public_key} = signed_conn("{}")
    [signature_input] = Plug.Conn.get_req_header(conn, "signature-input")

    conn =
      Plug.Conn.put_req_header(
        conn,
        "signature-input",
        signature_input <> "," <> signature_input
      )

    refute MessageSignatures.validate(conn, public_key)
  end
end

# end of message_signatures_test.exs
