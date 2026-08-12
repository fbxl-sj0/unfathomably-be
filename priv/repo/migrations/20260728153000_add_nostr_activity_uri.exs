# Unfathomably BE
# ----------------
#
# File: 20260728153000_add_nostr_activity_uri.exs
#
# Purpose:
#   Keep durable ActivityPub-to-Nostr mappings after transient activity rows
#   are removed by unlikes, unboosts, and unfollows.
#
# Responsibilities:
#   - add an indexed ActivityPub activity URI to stored Nostr events
#   - backfill existing outbound events from their signed proxy tags
#
# This file intentionally does NOT alter Nostr event envelopes or recreate
# deleted ActivityPub activities.

defmodule Pleroma.Repo.Migrations.AddNostrActivityUri do
  use Ecto.Migration

  def up do
    alter table(:nostr_events) do
      add(:ap_activity_uri, :text)
    end

    execute("""
    UPDATE nostr_events
    SET ap_activity_uri = (
      SELECT tag->>1
      FROM jsonb_array_elements(data->'tags') AS tag
      WHERE tag->>0 = 'proxy'
        AND tag->>2 = 'activitypub'
      LIMIT 1
    )
    WHERE ap_activity_uri IS NULL
    """)

    create(index(:nostr_events, [:ap_activity_uri]))
  end

  def down do
    drop(index(:nostr_events, [:ap_activity_uri]))

    alter table(:nostr_events) do
      remove(:ap_activity_uri)
    end
  end
end

# end of 20260728153000_add_nostr_activity_uri.exs
