# Unfathomably federated reading discovery index
# ------------------------------------------------
#
# File: 20260725193000_add_reading_discovery_search_index.exs
#
# Purpose:
#   Keep local searches over received BookWyrm-style objects bounded on large
#   federation databases.
#
# Responsibilities:
#   - define one immutable reading-object search document
#   - index only recognized reading object types
#   - include review text, quotations, books, shelves, and reader references
#
# This migration intentionally does not index private visibility, infer
# BookWyrm software from hostnames, or alter any stored ActivityPub object.

defmodule Pleroma.Repo.Migrations.AddReadingDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_reading_search_document(data jsonb)
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
        left(COALESCE(data ->> 'quote', ''), 2048) || ' ' ||
        left(COALESCE(data ->> 'inReplyToBook', ''), 2048) || ' ' ||
        left(COALESCE(data ->> 'actor', ''), 2048) || ' ' ||
        left(COALESCE(data ->> 'attributedTo', ''), 2048) || ' ' ||
        left(COALESCE(data ->> 'readingStatus', ''), 128)
      );
    $function$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_reading_discovery_search_index
    ON objects
    USING GIN (unfathomably_reading_search_document(data))
    WHERE data ->> 'type' IN (
      'Review', 'Comment', 'Quotation', 'Rating',
      'Shelf', 'BookList', 'ShelfItem', 'ListItem'
    )
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_reading_discovery_search_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_reading_search_document(jsonb)")
  end
end

# end of 20260725193000_add_reading_discovery_search_index.exs
