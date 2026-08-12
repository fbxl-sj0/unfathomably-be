# Unfathomably BE
# ----------------
#
# File: 20260806120000_honor_native_discovery_opt_outs.exs
#
# Purpose:
#   Keep Worlds and native search from surfacing objects whose publishers
#   explicitly disabled discovery or indexing.
#
# Responsibilities:
#   - preserve the existing shape-based native object classifier
#   - give explicit indexable=false and discoverable=false values precedence
#   - rebuild indexes whose predicates depend on the immutable SQL function
#
# This file intentionally does NOT delete objects or prevent direct resolution
# of an opted-out object by its canonical ActivityPub URL.

defmodule Pleroma.Repo.Migrations.HonorNativeDiscoveryOptOuts do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @postmarks_predicate """
  data ->> 'type' = 'Note'
  AND COALESCE(data ->> 'inReplyTo', '') = ''
  AND data ->> 'id' ~ '^https://[^/]+/m/[0-9A-Fa-f]{32}$'
  AND data ->> 'attributedTo' ~ '^https://[^/]+/u/[^/?#]+/?$'
  AND split_part(data ->> 'id', '/', 3) =
      split_part(data ->> 'attributedTo', '/', 3)
  AND data ->> 'content' ~* '<a[[:space:]][^>]*href='
  """

  @root_publication_predicate """
  data ->> 'type' IN ('Article', 'Page', 'Chapter', 'Document', 'Publication')
  AND COALESCE(data ->> 'inReplyTo', '') = ''
  AND (
    data -> 'audience' IS NULL
    OR data -> 'audience' = 'null'::jsonb
    OR data -> 'audience' = '[]'::jsonb
  )
  """

  def up do
    replace_predicate(discoverable_definition(true))
  end

  def down do
    replace_predicate(discoverable_definition(false))
  end

  defp discoverable_definition(honor_opt_outs?) do
    opt_out_guard =
      if honor_opt_outs? do
        """
        NOT (
          COALESCE(data -> 'indexable' = 'false'::jsonb, false)
          OR COALESCE(data -> 'discoverable' = 'false'::jsonb, false)
        )
        AND
        """
      else
        ""
      end

    """
    CREATE OR REPLACE FUNCTION unfathomably_native_discoverable(data jsonb)
    RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      SELECT
        #{opt_out_guard}
        (
          COALESCE((data -> '_unfathomably_native' ->> 'discoverable')::boolean, false)
          OR data ->> 'https://unfathomably.social/ns#family' IN (
            'audio', 'video', 'longform', 'photo', 'books', 'bookmarks',
            'software', 'models', 'markets', 'games', 'routes', 'culture',
            'coordination', 'publishing'
          )
          OR data ->> 'type' IN (
            'Audio', 'Commit', 'Event', 'Game', 'Image', 'Library', 'Model',
            'Push', 'Rating', 'Repository', 'Review', 'Route', 'Shelf',
            'Ticket', 'Track', 'Video', 'maid:Offer', 'maid:Request',
            'ValueFlows:Commitment', 'ValueFlows:EconomicEvent',
            'ValueFlows:Intent', 'ValueFlows:Plan', 'ValueFlows:Process',
            'ValueFlows:Proposal'
          )
          OR (
            data -> '_unfathomably_native' -> 'extensionFields' ? 'capabilities'
            AND EXISTS (
              SELECT 1
              FROM jsonb_array_elements(
                CASE jsonb_typeof(data -> 'attachment')
                  WHEN 'array' THEN data -> 'attachment'
                  ELSE '[]'::jsonb
                END
              ) AS attachment
              WHERE attachment ->> 'mediaType' LIKE 'image/%'
                OR attachment ->> 'type' = 'Image'
            )
          )
          OR data -> '_unfathomably_native' -> 'extensionFields' ?| ARRAY[
            'author', 'commentsEnabled', 'edits', 'fen', 'flohmarkt:data',
            'game', 'inReplyToBook', 'isLiveBroadcast', 'joinMode',
            'latestVersion', 'level', 'maximumAttendeeCapacity',
            'postingRestrictedToMods', 'protected', 'relatedWith',
            'resourceQuantity', 'san', 'startTime', 'subject'
          ]
          OR (#{@root_publication_predicate})
          OR (#{@postmarks_predicate})
        );
    $function$
    """
  end

  defp replace_predicate(definition) do
    execute(definition)
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_native_discovery_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_native_discovery_search_index")

    execute("""
    CREATE INDEX CONCURRENTLY objects_native_discovery_id_index
    ON objects (id DESC)
    WHERE unfathomably_native_discoverable(data)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY objects_native_discovery_search_index
    ON objects
    USING GIN (unfathomably_native_search_document(data))
    WHERE unfathomably_native_discoverable(data)
    """)
  end
end

# end of 20260806120000_honor_native_discovery_opt_outs.exs
