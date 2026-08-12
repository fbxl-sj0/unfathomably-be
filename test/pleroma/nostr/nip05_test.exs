# Unfathomably BE
# ----------------
#
# File: test/pleroma/nostr/nip05_test.exs
#
# Purpose:
#   Exercise the non-network NIP-05 identifier security boundary.
#
# Responsibilities:
#   - accept the standard constrained identifier syntax
#   - normalize root identifiers for human display
#   - reject local, numeric, and malformed destinations
#
# This file intentionally does NOT perform network requests or treat NIP-05 as
# proof of a person's identity.

defmodule Pleroma.Nostr.NIP05Test do
  use ExUnit.Case, async: true

  alias Pleroma.Nostr.NIP05

  test "normalizes ordinary and root identifiers" do
    assert {:ok, %{display: "alice@example.com"}} =
             NIP05.parse_identifier("Alice@Example.COM")

    assert {:ok, %{display: "example.com"}} =
             NIP05.parse_identifier("_@example.com")
  end

  test "rejects unsafe or malformed identifier destinations" do
    assert {:error, :invalid_nip05} = NIP05.parse_identifier("alice@localhost")
    assert {:error, :invalid_nip05} = NIP05.parse_identifier("alice@127.0.0.1")
    assert {:error, :invalid_nip05} = NIP05.parse_identifier("alice@@example.com")
    assert {:error, :invalid_nip05} = NIP05.parse_identifier("alice@example..com")
  end
end

# end of test/pleroma/nostr/nip05_test.exs
