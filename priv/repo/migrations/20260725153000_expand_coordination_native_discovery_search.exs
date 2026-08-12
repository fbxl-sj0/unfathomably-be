# Unfathomably BE
# ----------------
#
# File: 20260725153000_expand_coordination_native_discovery_search.exs
#
# Purpose:
#   Index useful ValueFlows and mutual-aid fields for local Worlds discovery.
#
# Responsibilities:
#   - extend the bounded native full-text document with coordination vocabulary
#   - rebuild the expression index after replacing its immutable function
#   - preserve the previous search definition for rollback
#
# This file intentionally does not index arbitrary JSON-LD trees, private
# objects, remote profiles, or geographic coordinates.

defmodule Pleroma.Repo.Migrations.ExpandCoordinationNativeDiscoverySearch do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    replace_search_function(coordination_definition())
  end

  def down do
    replace_search_function(previous_definition())
  end

  defp replace_search_function(definition) do
    execute(definition)
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_native_discovery_search_index")

    execute("""
    CREATE INDEX CONCURRENTLY objects_native_discovery_search_index
    ON objects USING gin (unfathomably_native_search_document(data))
    WHERE unfathomably_native_discoverable(data)
    """)
  end

  defp coordination_definition do
    search_definition("""
        left(COALESCE(data ->> 'note', ''), 2048) || ' ' ||
        left(COALESCE(data ->> 'description', ''), 2048) || ' ' ||
        left(COALESCE(data ->> 'action', ''), 256) || ' ' ||
        left(COALESCE(data ->> 'state', ''), 256) || ' ' ||
        left(COALESCE(data ->> 'status', ''), 256) || ' ' ||
        left(COALESCE(data ->> 'resourceClassifiedAs', ''), 1024) || ' ' ||
        left(COALESCE(data -> 'resourceConformsTo' ->> 'name', ''), 512) || ' ' ||
        left(COALESCE(data -> 'resourceConformsTo' ->> 'label', ''), 512) || ' ' ||
        left(COALESCE(data -> 'provider' ->> 'name', ''), 512) || ' ' ||
        left(COALESCE(data -> 'receiver' ->> 'name', ''), 512) || ' ' ||
        left(COALESCE(data -> 'eligibleLocation' ->> 'name', ''), 512) || ' ' ||
        left(COALESCE(data -> 'eligibleLocation' ->> 'address', ''), 512) || ' ' ||
        left(COALESCE(data -> 'resourceQuantity' ->> 'hasNumericalValue', ''), 128) || ' ' ||
        left(COALESCE(data -> 'resourceQuantity' -> 'hasUnit' ->> 'label', ''), 256) || ' ' ||
        left(COALESCE(data -> 'resourceQuantity' -> 'hasUnit' ->> 'symbol', ''), 128) || ' ' ||
    """)
  end

  defp previous_definition, do: search_definition("")

  defp search_definition(coordination_fields) do
    """
    CREATE OR REPLACE FUNCTION unfathomably_native_search_document(data jsonb)
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
        left(COALESCE(data ->> 'artist', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'album', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'author', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'category', ''), 256) || ' ' ||
        left(COALESCE(data ->> 'creator', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'isbn', ''), 64) || ' ' ||
        left(COALESCE(data ->> 'subject', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'subtitle', ''), 512) || ' ' ||
        left(COALESCE(data -> 'location' ->> 'name', ''), 512) || ' ' ||
        left(COALESCE(data -> 'flohmarkt:data' ->> 'name', ''), 512) || ' ' ||
        left(COALESCE(data -> 'flohmarkt:data' ->> 'location', ''), 512) || ' ' ||
        #{coordination_fields}
        left(COALESCE(data ->> 'https://unfathomably.social/ns#detail', ''), 1024) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#secondary', ''), 1024) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#artist', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#album', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#author', ''), 512) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#isbn', ''), 64) || ' ' ||
        left(COALESCE(data ->> 'https://unfathomably.social/ns#repository', ''), 1024)
      );
    $function$
    """
  end
end

# end of 20260725153000_expand_coordination_native_discovery_search.exs
