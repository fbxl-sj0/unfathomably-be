# Unfathomably received chess discovery index
# ---------------------------------------------
#
# File: 20260725221500_add_chess_object_discovery_search_index.exs
#
# Purpose:
#   Index the compact text surface used when searching received public chess
#   move notes.
#
# Responsibilities:
#   - restrict the index to structurally identified Note objects
#   - index move content, game URLs, and SAN notation
#   - build and remove the index without a long table lock
#
# This file intentionally does not classify objects by hostname, change stored
# chess data, or index complete game histories.

defmodule Pleroma.Repo.Migrations.AddChessObjectDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_chess_discovery_search_idx
    ON objects
    USING gin (
      to_tsvector(
        'simple',
        coalesce(data->>'content', '') || ' ' ||
        coalesce(data->>'game', '') || ' ' ||
        coalesce(data->>'san', '')
      )
    )
    WHERE data->>'type' = 'Note'
      AND jsonb_typeof(data->'game') = 'string'
      AND jsonb_typeof(data->'fen') = 'string'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_chess_discovery_search_idx")
  end
end

# end of 20260725221500_add_chess_object_discovery_search_index.exs
