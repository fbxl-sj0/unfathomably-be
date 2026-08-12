# Unfathomably BE
# ----------------
#
# File: 20260722203000_add_native_discovery_family_function.exs
#
# Purpose:
#   Classify validated native ActivityPub objects by their structural family.
#
# Responsibilities:
#   - honor explicit Unfathomably family metadata
#   - classify concrete object types and bounded extension shapes
#   - support family-specific Worlds pagination without hostname inference
#
# This file intentionally does NOT crawl remote servers, inspect display text,
# or infer product identity from domains.

defmodule Pleroma.Repo.Migrations.AddNativeDiscoveryFamilyFunction do
  use Ecto.Migration

  def up do
    execute("""
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
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS unfathomably_native_family(jsonb)")
  end
end

# end of priv/repo/migrations/20260722203000_add_native_discovery_family_function.exs
