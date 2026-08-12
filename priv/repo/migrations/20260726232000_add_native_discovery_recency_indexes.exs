# Unfathomably native discovery recency indexes
# ------------------------------------------------
#
# File: 20260726232000_add_native_discovery_recency_indexes.exs
#
# Purpose:
#   Keep unfiltered Worlds browsing bounded on large federation databases.
#
# Responsibilities:
#   - index native objects by structural family and recency
#   - index recognized reading objects by recency
#   - let empty family and reading pages finish without scanning social posts
#
# This file intentionally does not broaden discovery eligibility, index
# private visibility, or change stored ActivityPub objects.

defmodule Pleroma.Repo.Migrations.AddNativeDiscoveryRecencyIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @reading_predicate """
  (
    (
      (
        data @> '{"type":"Review"}'::jsonb
        OR data @> '{"type":"Comment"}'::jsonb
        OR data @> '{"type":"Quotation"}'::jsonb
        OR data @> '{"type":"Rating"}'::jsonb
        OR data @> '{"type":"Article"}'::jsonb
        OR data @> '{"type":"Note"}'::jsonb
        OR data @> '{"type":"ShelfItem"}'::jsonb
        OR data @> '{"type":"ListItem"}'::jsonb
        OR data @> '{"type":"SuggestionListItem"}'::jsonb
      )
      AND (
        data ->> 'inReplyToBook' IS NOT NULL
        OR data ->> 'book' IS NOT NULL
      )
    )
    OR data @> '{"type":"Shelf"}'::jsonb
    OR data @> '{"type":"BookList"}'::jsonb
    OR data @> '{"type":"SuggestionList"}'::jsonb
  )
  """

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_native_family_recent_index
    ON objects (unfathomably_native_family(data), id DESC)
    WHERE unfathomably_native_discoverable(data)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_reading_discovery_recent_index
    ON objects (id DESC)
    WHERE #{@reading_predicate}
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_reading_discovery_recent_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_native_family_recent_index")
  end
end

# end of 20260726232000_add_native_discovery_recency_indexes.exs
