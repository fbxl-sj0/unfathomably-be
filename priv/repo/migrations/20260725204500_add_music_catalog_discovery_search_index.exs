# Project: Unfathomably
# File: 20260725204500_add_music_catalog_discovery_search_index.exs
# Purpose: Add a bounded full-text index for durable music catalog objects.
#
# Responsibilities:
# - define the immutable document used by music-catalog discovery
# - index only Artist, Album, Library, and Playlist objects
#
# This migration intentionally excludes transient AudioCollection envelopes.

defmodule Pleroma.Repo.Migrations.AddMusicCatalogDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_music_catalog_search_document(data jsonb)
    RETURNS tsvector
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      SELECT to_tsvector(
        'simple',
        concat_ws(
          ' ',
          coalesce(data->>'name', ''),
          coalesce(data->>'title', ''),
          coalesce(data->>'summary', ''),
          coalesce(data->>'content', ''),
          coalesce(data->>'actor', ''),
          coalesce(data->>'attributedTo', ''),
          coalesce(data->>'musicbrainzId', ''),
          coalesce(data->>'musicbrainz_id', ''),
          left(coalesce((data->'artist_credit')::text, ''), 4096),
          left(coalesce((data->'tag')::text, ''), 2048)
        )
      )
    $$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_music_catalog_discovery_search_index
    ON objects
    USING gin (unfathomably_music_catalog_search_document(data))
    WHERE data->>'type' IN ('Artist', 'Album', 'Library', 'Playlist')
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_music_catalog_discovery_search_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_music_catalog_search_document(jsonb)")
  end
end

# end of 20260725204500_add_music_catalog_discovery_search_index.exs
