# Unfathomably BE
# ----------------
#
# File: 20260722040100_add_native_discovery_index.exs
#
# Purpose:
#   Give the sparse Worlds timeline an object-first discovery index.
#
# Responsibilities:
#   - classify trusted native presentation shapes inside PostgreSQL
#   - index matching object IDs in descending timeline order
#
# This file intentionally does not rewrite stored ActivityPub objects or infer
# platform identity from hostnames.

defmodule Pleroma.Repo.Migrations.AddNativeDiscoveryIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_native_discoverable(data jsonb)
    RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      SELECT
        COALESCE((data -> '_unfathomably_native' ->> 'discoverable')::boolean, false)
        OR data ->> 'https://unfathomably.social/ns#family' IN (
          'audio', 'video', 'longform', 'photo', 'books', 'bookmarks',
          'software', 'models', 'markets', 'games', 'routes', 'culture',
          'coordination', 'publishing'
        )
        OR data ->> 'type' IN (
          'Audio', 'Commit', 'Event', 'Game', 'Image', 'Library', 'Model',
          'Push', 'Rating', 'Repository', 'Review', 'Route', 'Shelf',
          'Ticket', 'Track', 'Video', 'maid:Offer', 'maid:Request',
          'ValueFlows:Commitment', 'ValueFlows:EconomicEvent',
          'ValueFlows:Intent', 'ValueFlows:Plan', 'ValueFlows:Process',
          'ValueFlows:Proposal'
        )
        OR data -> '_unfathomably_native' -> 'extensionFields' ?| ARRAY[
          'author', 'capabilities', 'commentsEnabled', 'edits', 'fen',
          'flohmarkt:data', 'game', 'inReplyToBook', 'isLiveBroadcast',
          'joinMode', 'latestVersion', 'level', 'maximumAttendeeCapacity',
          'postingRestrictedToMods', 'protected', 'relatedWith',
          'resourceQuantity', 'san', 'startTime', 'subject'
        ];
    $function$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_native_discovery_id_index
    ON objects (id DESC)
    WHERE unfathomably_native_discoverable(data)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_native_discovery_id_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_native_discoverable(jsonb)")
  end
end

# end of priv/repo/migrations/20260722040100_add_native_discovery_index.exs
