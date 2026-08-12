# Unfathomably BookWyrm identity discovery index
# ------------------------------------------------
#
# File: 20260725214500_add_book_identity_discovery_index.exs
#
# Purpose:
#   Let received reading activity be found by the metadata of its referenced
#   BookWyrm work or edition without scanning the complete object table.
#
# Responsibilities:
#   - define one immutable search document for cached Book, Edition, and Work
#   - index titles, identifiers, subjects, authors, publishers, and languages
#   - keep the index limited to recognized BookWyrm bibliographic types
#
# This migration intentionally does not index reading visibility, fetch remote
# catalogues, merge editions, or infer that similarly named books are equal.

defmodule Pleroma.Repo.Migrations.AddBookIdentityDiscoveryIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_book_search_document(data jsonb)
    RETURNS tsvector
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      SELECT to_tsvector(
        'simple',
        left(COALESCE(data ->> 'title', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'subtitle', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'description', ''), 4096) || ' ' ||
        left(COALESCE(data ->> 'isbn10', ''), 64) || ' ' ||
        left(COALESCE(data ->> 'isbn13', ''), 64) || ' ' ||
        left(COALESCE(data ->> 'openlibraryKey', ''), 128) || ' ' ||
        left(COALESCE((data -> 'authors')::text, ''), 4096) || ' ' ||
        left(COALESCE((data -> 'subjects')::text, ''), 4096) || ' ' ||
        left(COALESCE((data -> 'publishers')::text, ''), 2048) || ' ' ||
        left(COALESCE((data -> 'languages')::text, ''), 1024)
      );
    $function$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_book_identity_discovery_search_index
    ON objects
    USING GIN (unfathomably_book_search_document(data))
    WHERE data ->> 'type' IN ('Book', 'Edition', 'Work')
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_book_identity_discovery_search_index")

    execute("DROP FUNCTION IF EXISTS unfathomably_book_search_document(jsonb)")
  end
end

# end of 20260725214500_add_book_identity_discovery_index.exs
