# Unfathomably BE
# ----------------
#
# File: 20260722180000_tighten_native_discovery_index.exs
#
# Purpose:
#   Keep the Worlds discovery index aligned with native presentations exposed
#   by the Mastodon API.
#
# Responsibilities:
#   - require actual image media before classifying generic capability-bearing
#     notes as photographs
#   - rebuild the partial index after changing its immutable predicate
#
# This file intentionally does NOT infer a platform family from a hostname or
# promote ordinary social notes into specialized objects.

defmodule Pleroma.Repo.Migrations.TightenNativeDiscoveryIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    replace_predicate("""
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
        OR (
          data -> '_unfathomably_native' -> 'extensionFields' ? 'capabilities'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
              CASE jsonb_typeof(data -> 'attachment')
                WHEN 'array' THEN data -> 'attachment'
                ELSE '[]'::jsonb
              END
            ) AS attachment
            WHERE attachment ->> 'mediaType' LIKE 'image/%'
              OR attachment ->> 'type' = 'Image'
          )
        )
        OR data -> '_unfathomably_native' -> 'extensionFields' ?| ARRAY[
          'author', 'commentsEnabled', 'edits', 'fen', 'flohmarkt:data',
          'game', 'inReplyToBook', 'isLiveBroadcast', 'joinMode',
          'latestVersion', 'level', 'maximumAttendeeCapacity',
          'postingRestrictedToMods', 'protected', 'relatedWith',
          'resourceQuantity', 'san', 'startTime', 'subject'
        ];
    $function$
    """)
  end

  def down do
    replace_predicate("""
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
  end

  defp replace_predicate(definition) do
    execute(definition)
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_native_discovery_id_index")

    execute("""
    CREATE INDEX CONCURRENTLY objects_native_discovery_id_index
    ON objects (id DESC)
    WHERE unfathomably_native_discoverable(data)
    """)
  end
end

# end of priv/repo/migrations/20260722180000_tighten_native_discovery_index.exs
