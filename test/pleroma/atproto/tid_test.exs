# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/tid_test.exs
#
# Purpose:
#   Verify deterministic AT Protocol record keys at the publishing boundary.
#
# Responsibilities:
#   - require the current 13-character sortable-base32 TID syntax
#   - keep retries for one ActivityPub activity idempotent
#
# This file intentionally does NOT contact a PDS or create database records.

defmodule Pleroma.ATProto.TIDTest do
  use ExUnit.Case, async: true

  alias Pleroma.Activity
  alias Pleroma.ATProto.Publisher

  test "derives a stable, lexicon-valid TID from an activity" do
    activity = %Activity{
      id: "0000019f-f861-be1b-1648-5ca5382f0000",
      data: %{"id" => "https://social.example/activities/example"},
      inserted_at: ~N[2026-08-12 23:49:43.123456]
    }

    rkey = Publisher.deterministic_rkey(activity)

    assert rkey == Publisher.deterministic_rkey(activity)
    assert Regex.match?(~r/^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}$/, rkey)
  end
end

# end of test/pleroma/atproto/tid_test.exs
