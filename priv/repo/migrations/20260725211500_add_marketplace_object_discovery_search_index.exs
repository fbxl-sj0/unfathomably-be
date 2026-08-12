# Project: Unfathomably
# File: 20260725211500_add_marketplace_object_discovery_search_index.exs
# Purpose: Add a bounded full-text index for verified marketplace candidates.
#
# Responsibilities:
# - define the immutable document used by received-listing discovery
# - index stock Flohmarkt data and FEP-0837 Proposal attachment candidates
#
# This migration intentionally does not classify candidates without the
# application-level ownership and identifier checks.

defmodule Pleroma.Repo.Migrations.AddMarketplaceObjectDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_marketplace_search_document(data jsonb)
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
          left(coalesce((data->'flohmarkt:data')::text, ''), 4096),
          left(coalesce((data->'attachment')::text, ''), 8192),
          left(coalesce((data->'tag')::text, ''), 2048)
        )
      )
    $$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_marketplace_discovery_search_index
    ON objects
    USING gin (unfathomably_marketplace_search_document(data))
    WHERE data->>'type' = 'Note'
      AND (
        data ? 'flohmarkt:data'
        OR position('Proposal' in coalesce((data->'attachment')::text, '')) > 0
      )
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_marketplace_discovery_search_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_marketplace_search_document(jsonb)")
  end
end

# end of 20260725211500_add_marketplace_object_discovery_search_index.exs
