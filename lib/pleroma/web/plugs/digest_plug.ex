# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.DigestPlug do
  alias Plug.Conn

  def read_body(conn, opts) do
    digest_algorithm =
      with [digest_header] <- Conn.get_req_header(conn, "digest") do
        digest_header
        |> String.split("=", parts: 2)
        |> List.first()
      else
        _ -> "SHA-256"
      end

    unless String.downcase(digest_algorithm) == "sha-256" do
      raise ArgumentError,
        message: "invalid value for digest algorithm, got: #{digest_algorithm}"
    end

    {:ok, body, conn} = Conn.read_body(conn, opts)
    encoded_digest = :crypto.hash(:sha256, body) |> Base.encode64()
    content_digest = "sha-256=:#{encoded_digest}:"

    content_digest_valid =
      case Conn.get_req_header(conn, "content-digest") do
        [^content_digest] -> true
        _ -> false
      end

    conn =
      conn
      |> Conn.assign(:digest, "#{digest_algorithm}=#{encoded_digest}")
      |> Conn.assign(:content_digest, content_digest)
      |> Conn.assign(:content_digest_valid, content_digest_valid)

    {:ok, body, conn}
  end
end
