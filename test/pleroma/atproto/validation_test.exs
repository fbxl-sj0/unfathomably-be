# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/validation_test.exs
#
# Purpose:
#   Verify strict AT Protocol identifier validation at the bridge boundary.
#
# Responsibilities:
#   - accept normalized blessed DIDs, NSIDs, and record keys
#   - reject did:web paths, ports, malformed collections, and unsafe keys
#   - reject query, fragment, and extra-path smuggling in record URIs
#
# This file intentionally does NOT perform identity resolution or network I/O.

defmodule Pleroma.ATProto.ValidationTest do
  use ExUnit.Case, async: true

  alias Pleroma.ATProto.Validation

  test "accepts normalized record-level AT URIs" do
    assert {:ok, "did:plc:alice", "app.bsky.feed.post", "3lexample"} =
             Validation.split_record_uri("at://did:plc:alice/app.bsky.feed.post/3lexample")

    assert Validation.valid_did?("did:web:pds.example.com")
    assert Validation.valid_handle?("alice.example.com")
    assert Validation.valid_record_key?("self")
  end

  test "rejects unsupported did:web forms and malformed repository paths" do
    refute Validation.valid_did?("did:web:pds.example.com:user")
    refute Validation.valid_did?("did:web:pds.example.com%3A8443")
    refute Validation.valid_handle?("handle.invalid")
    refute Validation.valid_record_key?(".")
    refute Validation.valid_record_key?("folder/item")

    for uri <- [
          "at://did:plc:alice/example/3lexample",
          "at://did:plc:alice/app.bsky.feed.post/folder/item",
          "at://did:plc:alice/app.bsky.feed.post/3lexample?view=1",
          "at://did:plc:alice/app.bsky.feed.post/3lexample#fragment"
        ] do
      assert {:error, :invalid_at_uri} = Validation.split_record_uri(uri)
    end
  end
end

# end of test/pleroma/atproto/validation_test.exs
