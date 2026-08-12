# Unfathomably: local web-origin identity tests
#
# File: local_origin_test.exs
#
# Purpose:
#   Prove that recursive discovery suppression distinguishes complete origins,
#   including default and explicit ports, rather than comparing hostnames alone.
#
# This file intentionally does not exercise network transport.

defmodule Pleroma.Web.LocalOriginTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.LocalOrigin

  test "matches normalized scheme, hostname, and effective port" do
    origins = ["https://Social.Example", "https://alias.example:8443"]

    assert LocalOrigin.local_url?("https://social.example/users/alice", origins)
    assert LocalOrigin.local_url?("https://social.example.:443/inbox", origins)
    assert LocalOrigin.local_url?("https://alias.example:8443/objects/1", origins)

    refute LocalOrigin.local_url?("http://social.example/users/alice", origins)
    refute LocalOrigin.local_url?("https://social.example:8443/users/alice", origins)
    refute LocalOrigin.local_url?("https://remote.example/users/alice", origins)
  end

  test "matches WebFinger authorities without collapsing ports" do
    origins = ["https://social.example", "https://alias.example:8443"]

    assert LocalOrigin.local_webfinger_host?("social.example", origins)
    assert LocalOrigin.local_webfinger_host?("alias.example:8443", origins)

    refute LocalOrigin.local_webfinger_host?("alias.example", origins)
    refute LocalOrigin.local_webfinger_host?("remote.example", origins)
    refute LocalOrigin.local_webfinger_host?("user@social.example", origins)
  end

  test "rejects credential-bearing candidate origins" do
    refute LocalOrigin.local_url?(
             "https://user:password@social.example/private",
             ["https://social.example"]
           )
  end

  test "rejects canonical local and private address forms" do
    blocked_hosts = [
      "localhost",
      "localhost.localdomain",
      "service.internal",
      "127.0.0.1",
      "10.2.3.4",
      "169.254.10.20",
      "172.16.4.5",
      "192.168.1.8",
      "100.64.0.1",
      "0.0.0.0",
      "::1",
      "[::1]",
      "::ffff:127.0.0.1",
      "[::ffff:192.168.1.8]",
      "::127.0.0.1",
      "fc00::1",
      "fe80::1"
    ]

    Enum.each(blocked_hosts, fn host ->
      refute LocalOrigin.public_remote_host?(host), "expected #{host} to be private"
    end)
  end

  test "accepts public literal addresses and test hostnames" do
    assert LocalOrigin.public_remote_host?("8.8.8.8")
    assert LocalOrigin.public_remote_host?("2606:4700:4700::1111")
    assert LocalOrigin.public_remote_host?("::ffff:8.8.8.8")
    assert LocalOrigin.public_remote_host?("federation.example")
  end
end

# end of local_origin_test.exs
