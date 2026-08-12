# Unfathomably Nostr relay-list lookup index
# ------------------------------------------
#
# File: 20260729151000_add_nostr_relay_list_metadata_index.exs
#
# Purpose:
#   Keep recurring relay discovery from scanning every imported Nostr entity.
#
# Responsibilities:
#   - identify the small set of entities that carry NIP-65 relay-list metadata
#   - support immediate connector refreshes without an application cache
#   - build and remove the index without blocking normal entity ingestion
#
# This file intentionally does not select relays, change relay permissions,
# or alter imported profile metadata.

defmodule Pleroma.Repo.Migrations.AddNostrRelayListMetadataIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS nostr_entities_relay_list_metadata_index
    ON nostr_entities (id)
    WHERE (metadata -> 'relay_list') IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS nostr_entities_relay_list_metadata_index")
  end
end

# end of 20260729151000_add_nostr_relay_list_metadata_index.exs
