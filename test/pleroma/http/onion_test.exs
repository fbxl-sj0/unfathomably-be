# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.OnionTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.HTTP.Onion

  import Pleroma.Tests.Helpers, only: [clear_config: 2]

  setup do
    clear_config(Onion,
      enabled: false,
      socks_port: 9050,
      connect_timeout: 15_000,
      recv_timeout: 30_000
    )

    :ok
  end

  test "leaves ordinary HTTP destinations unchanged" do
    options = [pool: :federation]

    assert {:ok, ^options} = Onion.route(URI.parse("https://example.com/object"), options)
  end

  test "fails closed when onion transport is disabled" do
    uri = URI.parse("http://#{valid_onion_service()}/object")

    assert {:error, :onion_transport_disabled} = Onion.route(uri, [])
  end

  test "rejects a syntactically plausible address with an invalid v3 checksum" do
    uri = URI.parse("http://#{String.duplicate("a", 56)}.onion/object")

    assert {:error, :invalid_onion_host} = Onion.route(uri, [])
  end

  test "forces valid onion destinations through the isolated loopback proxy" do
    clear_config(Onion,
      enabled: true,
      socks_port: 19_050,
      connect_timeout: 20_000,
      recv_timeout: 40_000
    )

    uri = URI.parse("https://media.#{valid_onion_service()}/object")

    assert {:ok, options} =
             Onion.route(uri,
               proxy: {:socks5, {192, 0, 2, 1}, 1080},
               pool: :federation,
               retry: 4
             )

    assert options[:proxy] == {:socks5, {127, 0, 0, 1}, 19_050}
    assert options[:pool] == :onion
    assert options[:connect_timeout] == 20_000
    assert options[:recv_timeout] == 40_000
    assert options[:retry] == 0
  end

  test "rejects invalid local proxy configuration" do
    clear_config(Onion, enabled: true, socks_port: 70_000)

    uri = URI.parse("http://#{valid_onion_service()}/object")

    assert {:error, :invalid_onion_transport_config} = Onion.route(uri, [])
  end

  defp valid_onion_service do
    public_key = :crypto.strong_rand_bytes(32)
    version = <<3>>

    checksum =
      :crypto.hash(:sha3_256, ".onion checksum" <> public_key <> version)
      |> binary_part(0, 2)

    Base.encode32(public_key <> checksum <> version, case: :lower, padding: false) <> ".onion"
  end
end

# End of Pleroma.HTTP.OnionTest.
