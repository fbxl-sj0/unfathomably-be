# Unfathomably BE
# ----------------
#
# File: 20260722213000_add_native_discovery_search_index.exs
#
# Purpose:
#   Make locally cached native objects searchable by their useful metadata.
#
# Responsibilities:
#   - build a bounded full-text document from common specialized object fields
#   - index only objects already accepted by native discovery
#   - support concurrent installation on live federation databases
#
# This file intentionally does NOT index arbitrary JSON values, remote actor
# profiles, or infer search terms from hostnames.

defmodule Pleroma.Repo.Migrations.AddNativeDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_native_search_document(data jsonb)
    RETURNS tsvector
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      SELECT to_tsvector(
        'simple',
        left(COALESCE(data ->> 'name', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'title', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'summary', ''), 2048) || ' ' ||
        left(COALESCE(data ->> 'content', ''), 4096) || ' ' ||
        left(COALESCE(data ->> 'artist', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'album', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'author', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'category', ''), 256) || ' ' ||
        left(COALESCE(data ->> 'creator', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'isbn', ''), 64) || ' ' ||
        left(COALESCE(data ->> 'subject', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'subtitle', ''), 512) || ' ' ||
        left(COALESCE(data -> 'location' ->> 'name', ''), 512) || ' ' ||
        left(COALESCE(data -> 'flohmarkt:data' ->> 'name', ''), 512) || ' ' ||
        left(COALESCE(data -> 'flohmarkt:data' ->> 'location', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#detail', ''), 1024) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#secondary', ''), 1024) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#artist', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#album', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#author', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#isbn', ''), 64) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#repository', ''), 1024)
      );
    $function$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_native_discovery_search_index
    ON objects USING gin (unfathomably_native_search_document(data))
    WHERE unfathomably_native_discoverable(data)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_native_discovery_search_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_native_search_document(jsonb)")
  end
end

# end of priv/repo/migrations/20260722213000_add_native_discovery_search_index.exs
