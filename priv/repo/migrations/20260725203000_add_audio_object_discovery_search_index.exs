# Project: Unfathomably
# File: 20260725203000_add_audio_object_discovery_search_index.exs
# Purpose: Add a bounded full-text index for received Audio objects.
#
# Responsibilities:
# - define the immutable document used by received-audio discovery
# - index only normalized ActivityStreams Audio objects
#
# This migration intentionally does not fetch or rewrite federated media.

defmodule Pleroma.Repo.Migrations.AddAudioObjectDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_audio_search_document(data jsonb)
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
          left(coalesce((data->'artist_credit')::text, ''), 4096),
          left(coalesce((data->'album')::text, ''), 4096),
          left(coalesce((data->'tag')::text, ''), 2048)
        )
      )
    $$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_audio_discovery_search_index
    ON objects
    USING gin (unfathomably_audio_search_document(data))
    WHERE data->>'type' = 'Audio'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_audio_discovery_search_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_audio_search_document(jsonb)")
  end
end

# end of 20260725203000_add_audio_object_discovery_search_index.exs
