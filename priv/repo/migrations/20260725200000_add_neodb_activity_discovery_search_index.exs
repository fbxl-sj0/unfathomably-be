# Project: Unfathomably
# File: 20260725200000_add_neodb_activity_discovery_search_index.exs
# Purpose: Add a bounded full-text index for received NeoDB cultural activity.
#
# Responsibilities:
# - define the immutable document used by the discovery query
# - index objects carrying NeoDB-style relatedWith relationships
#
# This migration intentionally does not alter or backfill federated objects.

defmodule Pleroma.Repo.Migrations.AddNeoDBActivityDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_neodb_search_document(data jsonb)
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
          left(coalesce((data->'relatedWith')::text, ''), 8192),
          left(coalesce((data->'tag')::text, ''), 4096)
        )
      )
    $$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_neodb_activity_discovery_search_index
    ON objects
    USING gin (unfathomably_neodb_search_document(data))
    WHERE data ? 'relatedWith'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_neodb_activity_discovery_search_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_neodb_search_document(jsonb)")
  end
end

# end of 20260725200000_add_neodb_activity_discovery_search_index.exs
