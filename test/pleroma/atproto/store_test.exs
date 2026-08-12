# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/store_test.exs
#
# Purpose:
#   Verify parsing at:// strong-reference identifiers without network access.
#
# Responsibilities:
#   - accept valid DID, collection, and record-key components
#   - reject incomplete and non-AT identifiers
#
# This file intentionally does NOT write records or call an AppView.

defmodule Pleroma.ATProto.StoreTest do
  use ExUnit.Case, async: true

  alias Pleroma.ATProto.Store

  test "splits a post URI into its strong-reference components" do
    assert {:ok, "did:plc:alice", "app.bsky.feed.post", "3lexample"} =
             Store.split_uri("at://did:plc:alice/app.bsky.feed.post/3lexample")
  end

  test "rejects incomplete and non-AT identifiers" do
    assert {:error, :invalid_at_uri} = Store.split_uri("https://bsky.app/profile/alice")
    assert {:error, :invalid_at_uri} = Store.split_uri("at://did:plc:alice/app.bsky.feed.post")

    assert {:error, :invalid_at_uri} =
             Store.split_uri("at://did:plc:alice/app.bsky.feed.post/folder/item")

    assert {:error, :invalid_at_uri} =
             Store.split_uri("at://did:web:example.com:user/app.bsky.feed.post/3lexample")
  end
end

# end of test/pleroma/atproto/store_test.exs
