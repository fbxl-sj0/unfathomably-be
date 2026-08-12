# Unfathomably BE
# ----------------
#
# File: 20260725170000_expand_publishing_native_discovery.exs
#
# Purpose:
#   Make structurally reliable alien publishing objects locally discoverable.
#
# Responsibilities:
#   - recognize the documented Postmarks bookmark Note shape
#   - admit root Article, Page, Chapter, Document, and Publication objects
#   - exclude replies and group-audience pages from publishing discovery
#   - rebuild native recency and full-text indexes after predicate changes
#
# This file intentionally does NOT infer software from a hostname, classify
# arbitrary Notes as bookmarks, crawl outboxes, or expose private objects.

defmodule Pleroma.Repo.Migrations.ExpandPublishingNativeDiscovery do
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
    execute(family_definition(@postmarks_predicate))

    execute(
      discoverable_definition("""
      OR (#{@root_publication_predicate})
      OR (#{@postmarks_predicate})
      """)
    )

    rebuild_indexes()
  end

  def down do
    execute(family_definition(""))
    execute(discoverable_definition(""))
    rebuild_indexes()
  end

  defp family_definition(postmarks_predicate) do
    postmarks_clause =
      case String.trim(postmarks_predicate) do
        "" -> ""
        predicate -> "WHEN #{predicate} THEN 'bookmarks'"
      end

    """
    CREATE OR REPLACE FUNCTION unfathomably_native_family(data jsonb)
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      WITH normalized AS (
        SELECT
          data ->> 'https://unfathomably.social/ns#family' AS explicit_family,
          data ->> 'type' AS raw_type,
          lower(regexp_replace(COALESCE(data ->> 'type', ''), '^.*[/#:]', '')) AS short_type,
          data -> '_unfathomably_native' -> 'extensionFields' AS extension_fields,
          CASE jsonb_typeof(data -> 'attachment')
            WHEN 'array' THEN data -> 'attachment'
            WHEN 'object' THEN jsonb_build_array(data -> 'attachment')
            ELSE '[]'::jsonb
          END AS attachments
      )
      SELECT CASE
        WHEN explicit_family = 'software' THEN 'development'
        WHEN explicit_family = 'markets' THEN 'marketplace'
        WHEN explicit_family IN (
          'audio', 'video', 'longform', 'photo', 'books', 'bookmarks',
          'groups', 'events', 'development', 'models', 'marketplace',
          'games', 'routes', 'culture', 'coordination', 'publishing'
        ) THEN explicit_family
        WHEN raw_type IN (
          'pair:Project',
          'http://virtual-assembly.org/ontologies/pair#Project',
          'maid:Offer',
          'maid:Request',
          'https://mutual-aid.app/ns/core#Offer',
          'https://mutual-aid.app/ns/core#Request'
        ) OR raw_type LIKE 'ValueFlows:%'
          OR raw_type LIKE 'https://w3id.org/valueflows#%' THEN 'coordination'
        WHEN extension_fields ? 'relatedWith' THEN 'culture'
        WHEN extension_fields ?& ARRAY['fen', 'game'] THEN 'games'
        WHEN extension_fields ? 'flohmarkt:data'
          OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(attachments) AS attachment
            WHERE lower(regexp_replace(COALESCE(attachment ->> 'type', ''), '^.*[/#:]', '')) = 'proposal'
          ) THEN 'marketplace'
        WHEN short_type = 'note'
          AND data ->> 'id' ~ '/api/v1/(trail|summit-log|comment|list)/'
          AND (
            extension_fields ? 'startTime'
            OR data -> 'location' ->> 'type' = 'Place'
            OR jsonb_array_length(attachments) > 0
            OR jsonb_typeof(data -> 'tag') IN ('array', 'object')
          ) THEN 'routes'
        #{postmarks_clause}
        WHEN EXISTS (
          SELECT 1
          FROM jsonb_array_elements(attachments) AS attachment
          WHERE attachment ->> 'mediaType' LIKE 'model/%'
            OR attachment ->> 'mediaType' IN (
              'application/sla', 'application/vnd.ms-pki.stl'
            )
        ) THEN 'models'
        WHEN extension_fields ? 'capabilities'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(attachments) AS attachment
            WHERE attachment ->> 'mediaType' LIKE 'image/%'
              OR attachment ->> 'type' = 'Image'
          ) THEN 'photo'
        WHEN short_type IN ('album', 'audio', 'podcastepisode', 'track') THEN 'audio'
        WHEN short_type IN ('video', 'livestream') THEN 'video'
        WHEN short_type IN ('article', 'page') THEN 'longform'
        WHEN short_type = 'image' THEN 'photo'
        WHEN short_type IN (
          'author', 'book', 'booklist', 'edition', 'quotation', 'rating',
          'review', 'shelf', 'work'
        ) THEN 'books'
        WHEN short_type IN ('group', 'question') THEN 'groups'
        WHEN short_type = 'event' THEN 'events'
        WHEN short_type IN (
          'branch', 'commit', 'issue', 'mergerrequest', 'patch', 'project',
          'proposal', 'push', 'repository', 'ticket', 'ticketdependency'
        ) THEN 'development'
        WHEN short_type IN ('model', 'threedmodel') THEN 'models'
        WHEN short_type = 'game' THEN 'games'
        WHEN short_type = 'route' THEN 'routes'
        WHEN short_type IN ('chapter', 'document', 'publication') THEN 'publishing'
        ELSE NULL
      END
      FROM normalized;
    $function$
    """
  end

  defp discoverable_definition(extra_predicates) do
    """
    CREATE OR REPLACE FUNCTION unfathomably_native_discoverable(data jsonb)
    RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      SELECT
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
        #{extra_predicates};
    $function$
    """
  end

  defp rebuild_indexes do
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

# end of 20260725170000_expand_publishing_native_discovery.exs
