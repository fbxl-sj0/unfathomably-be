# Project: Unfathomably
# File: 20260725210000_add_event_object_discovery_search_index.exs
# Purpose: Add a bounded full-text index for received public Event objects.
#
# Responsibilities:
# - define the immutable document used by received-event discovery
# - index Event title, description, organizer, Place, category, and tags
#
# This migration intentionally does not backfill or refresh remote events.

defmodule Pleroma.Repo.Migrations.AddEventObjectDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_event_search_document(data jsonb)
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
          coalesce(data->>'category', ''),
          left(coalesce((data->'location')::text, ''), 4096),
          left(coalesce((data->'tag')::text, ''), 2048)
        )
      )
    $$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_event_discovery_search_index
    ON objects
    USING gin (unfathomably_event_search_document(data))
    WHERE data->>'type' = 'Event'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_event_discovery_search_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_event_search_document(jsonb)")
  end
end

# end of 20260725210000_add_event_object_discovery_search_index.exs
