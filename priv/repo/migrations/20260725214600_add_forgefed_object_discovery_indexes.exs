# Project: Unfathomably
# File: 20260725214600_add_forgefed_object_discovery_indexes.exs
# Purpose: Add bounded indexes for local ForgeFed discovery.
#
# Responsibilities:
# - index known ForgeFed resource actors
# - index durable forge objects and explicitly public Push activities
# - provide recent-item indexes for empty-query browsing
#
# This migration intentionally does not index private forge activity or infer
# ForgeFed support from a hostname, repository URL, or profile description.

defmodule Pleroma.Repo.Migrations.AddForgeFedObjectDiscoveryIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_forgefed_actor_search_document(
      nickname text,
      name text,
      bio text,
      ap_id text,
      actor_extensions jsonb
    )
    RETURNS tsvector
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      SELECT to_tsvector(
        'simple',
        concat_ws(
          ' ',
          coalesce(nickname, ''),
          coalesce(name, ''),
          coalesce(bio, ''),
          coalesce(ap_id, ''),
          left(coalesce(actor_extensions::text, ''), 8192)
        )
      )
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_forgefed_object_search_document(data jsonb)
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
          coalesce(data->>'hash', ''),
          coalesce(data->>'context', ''),
          coalesce(data->>'actor', ''),
          coalesce(data->>'attributedTo', ''),
          left(coalesce((data->'tag')::text, ''), 2048)
        )
      )
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_forgefed_push_search_document(data jsonb)
    RETURNS tsvector
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      SELECT to_tsvector(
        'simple',
        concat_ws(
          ' ',
          coalesce(data->>'summary', ''),
          coalesce(data->>'actor', ''),
          coalesce(data->>'attributedTo', ''),
          coalesce(data->>'context', ''),
          coalesce(data->>'target', ''),
          coalesce(data->>'hashBefore', ''),
          coalesce(data->>'hashAfter', ''),
          left(coalesce((data->'object')::text, ''), 8192)
        )
      )
    $$
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_forgefed_actor_discovery_search_index
    ON users
    USING gin (
      unfathomably_forgefed_actor_search_document(
        nickname, name, bio, ap_id, actor_extensions
      )
    )
    WHERE local = false
      AND is_active = true
      AND invisible = false
      AND actor_type IN (
        'Factory', 'PatchTracker', 'Project', 'ReleaseTracker', 'Repository',
        'Roadmap', 'Team', 'TicketTracker', 'Workflow'
      )
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_forgefed_actor_discovery_recent_index
    ON users (updated_at DESC, id)
    WHERE local = false
      AND is_active = true
      AND invisible = false
      AND actor_type IN (
        'Factory', 'PatchTracker', 'Project', 'ReleaseTracker', 'Repository',
        'Roadmap', 'Team', 'TicketTracker', 'Workflow'
      )
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_forgefed_discovery_search_index
    ON objects
    USING gin (unfathomably_forgefed_object_search_document(data))
    WHERE data->>'type' IN (
      'Approval', 'Branch', 'Commit', 'Enum', 'EnumValue', 'Field',
      'Milestone', 'Patch', 'Release', 'Review', 'Ticket',
      'TicketDependency'
    )
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_forgefed_discovery_recent_index
    ON objects (updated_at DESC, id)
    WHERE data->>'type' IN (
      'Approval', 'Branch', 'Commit', 'Enum', 'EnumValue', 'Field',
      'Milestone', 'Patch', 'Release', 'Review', 'Ticket',
      'TicketDependency'
    )
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activities_forgefed_push_discovery_search_index
    ON activities
    USING gin (unfathomably_forgefed_push_search_document(data))
    WHERE local = false AND data->>'type' = 'Push'
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activities_forgefed_push_discovery_recent_index
    ON activities (inserted_at DESC, id)
    WHERE local = false AND data->>'type' = 'Push'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS activities_forgefed_push_discovery_recent_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS activities_forgefed_push_discovery_search_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_forgefed_discovery_recent_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_forgefed_discovery_search_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_forgefed_actor_discovery_recent_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_forgefed_actor_discovery_search_index")
    execute("DROP FUNCTION IF EXISTS unfathomably_forgefed_push_search_document(jsonb)")
    execute("DROP FUNCTION IF EXISTS unfathomably_forgefed_object_search_document(jsonb)")

    execute("""
    DROP FUNCTION IF EXISTS unfathomably_forgefed_actor_search_document(
      text, text, text, text, jsonb
    )
    """)
  end
end

# end of 20260725214600_add_forgefed_object_discovery_indexes.exs
