# Project: Unfathomably BE
#
# File: 20260801190000_filter_bare_audio_from_native_feeds.exs
#
# Purpose:
#   Distinguish playable or intentionally native Audio objects from legacy
#   Pleroma listening-activity envelopes in native Worlds queries.
#
# Responsibilities:
#   - Define a stable PostgreSQL eligibility predicate for native feeds.
#   - Preserve explicitly marked native objects and usable media records.
#
# This file intentionally does not classify native families or delete stored
# federation data.

defmodule Pleroma.Repo.Migrations.FilterBareAudioFromNativeFeeds do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_native_feed_eligible(data jsonb)
    RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      SELECT NOT (
        COALESCE(data ->> 'type', '') = 'Audio'
        AND NOT COALESCE(
          (data -> '_unfathomably_native' ->> 'discoverable')::boolean,
          false
        )
        AND BTRIM(COALESCE(data ->> 'https://unfathomably.social/ns#family', '')) = ''
        AND BTRIM(COALESCE(data ->> 'content', '')) = ''
        AND CASE jsonb_typeof(data -> 'attachment')
          WHEN 'array' THEN jsonb_array_length(data -> 'attachment') = 0
          ELSE true
        END
        AND COALESCE(data -> 'url', 'null'::jsonb) IN (
          'null'::jsonb,
          '""'::jsonb,
          '[]'::jsonb,
          '{}'::jsonb
        )
      );
    $function$
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS unfathomably_native_feed_eligible(jsonb)")
  end
end

# end of 20260801190000_filter_bare_audio_from_native_feeds.exs
