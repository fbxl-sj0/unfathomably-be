# Unfathomably BE
# ----------------
#
# File: 20260728153100_fix_nostr_replaceable_event_keys.exs
#
# Purpose:
#   Align persisted replacement keys with NIP-01 event semantics.
#
# Responsibilities:
#   - preserve future ordinary kind 1 and kind 2 events independently
#   - collapse duplicate kind 3 contact lists to each author's newest event
#   - assign the correct replacement key to retained contact lists
#
# This file intentionally does NOT reconstruct events removed before the
# classifier was corrected.

defmodule Pleroma.Repo.Migrations.FixNostrReplaceableEventKeys do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE nostr_events
    SET replace_key = NULL
    WHERE kind IN (1, 2)
    """)

    execute("""
    DELETE FROM nostr_events AS older
    USING nostr_events AS newer
    WHERE older.kind = 3
      AND newer.kind = 3
      AND older.pubkey = newer.pubkey
      AND (
        older.created_at < newer.created_at
        OR (older.created_at = newer.created_at AND older.id < newer.id)
      )
    """)

    execute("""
    UPDATE nostr_events
    SET replace_key = '3:' || pubkey
    WHERE kind = 3
    """)
  end

  def down do
    execute("""
    UPDATE nostr_events
    SET replace_key = NULL
    WHERE kind = 3
    """)
  end
end

# end of 20260728153100_fix_nostr_replaceable_event_keys.exs
