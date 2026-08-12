# Project: Unfathomably
# File: 20260725213000_add_route_object_discovery_search_index.exs
# Purpose: Add a bounded full-text index for received Wanderer trail discovery.
#
# Responsibilities:
# - define the immutable document used by local route search
# - index canonical trail candidates carrying GPX, Place, or distance metadata
#
# This migration intentionally does not classify comments, summit logs, lists,
# private objects, or arbitrary Notes that merely mention trails.

defmodule Pleroma.Repo.Migrations.AddRouteObjectDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_route_search_document(data jsonb)
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
          coalesce(data->>'summary', ''),
          coalesce(data->>'content', ''),
          coalesce(data->>'actor', ''),
          coalesce(data->>'attributedTo', ''),
          coalesce(data->>'startTime', ''),
          left(coalesce((data->'location')::text, ''), 2048),
          left(coalesce((data->'tag')::text, ''), 4096)
        )
      )
    $$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_route_discovery_search_index
    ON objects
    USING gin (unfathomably_route_search_document(data))
    WHERE data->>'type' = 'Note'
      AND data->>'id' ~ '/api/v1/trail/[^/]+$'
      AND (
        position('application/xml+gpx' in coalesce((data->'attachment')::text, '')) > 0
        OR position('application/gpx+xml' in coalesce((data->'attachment')::text, '')) > 0
        OR data->'location'->>'type' = 'Place'
        OR position('"name": "distance"' in coalesce((data->'tag')::text, '')) > 0
      )
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_route_discovery_search_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_route_search_document(jsonb)")
  end
end

# end of 20260725213000_add_route_object_discovery_search_index.exs
