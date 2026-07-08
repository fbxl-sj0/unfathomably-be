# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Gun.ConnTest do
  use Pleroma.DataCase, async: false

  import Mox

  alias Pleroma.Gun.Conn

  setup :verify_on_exit!

  setup do
    original = System.get_env("SSL_CERT_FILE")

    on_exit(fn ->
      if is_nil(original) do
        System.delete_env("SSL_CERT_FILE")
      else
        System.put_env("SSL_CERT_FILE", original)
      end
    end)
  end

  test "uses SSL_CERT_FILE for HTTPS connection CA verification when provided" do
    System.put_env("SSL_CERT_FILE", "/tmp/unfathomably-smoke-ca.pem")

    expect(Pleroma.GunMock, :open, fn _host, _port, opts ->
      assert get_in(opts, [:tls_opts, :cacertfile]) == "/tmp/unfathomably-smoke-ca.pem"
      {:error, :stop}
    end)

    assert {:error, :stop} = Conn.open(URI.parse("https://example.com/"), [])
  end
end
