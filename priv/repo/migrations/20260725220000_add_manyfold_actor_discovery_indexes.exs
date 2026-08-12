# Project: Unfathomably
# File: 20260725220000_add_manyfold_actor_discovery_indexes.exs
# Purpose: Add bounded indexes for locally known Manyfold actors.
#
# Responsibilities:
# - index f3di model, creator, and collection actors for full-text search
# - provide a recent-actor index for empty-query browsing
#
# This migration intentionally does not index compatibility Notes, model
# binaries, or profiles guessed to be Manyfold from their hostname.

defmodule Pleroma.Repo.Migrations.AddManyfoldActorDiscoveryIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION unfathomably_manyfold_actor_search_document(
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
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_manyfold_actor_discovery_search_index
    ON users
    USING gin (
      unfathomably_manyfold_actor_search_document(
        nickname, name, bio, ap_id, actor_extensions
      )
    )
    WHERE local = false
      AND is_active = true
      AND invisible = false
      AND coalesce(
        actor_extensions->>'f3di:concreteType',
        actor_extensions->>'concreteType',
        actor_extensions->>'http://purl.org/f3di/ns#concreteType'
      ) IN ('3DModel', 'Collection', 'Creator')
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_manyfold_actor_discovery_recent_index
    ON users (updated_at DESC, id)
    WHERE local = false
      AND is_active = true
      AND invisible = false
      AND coalesce(
        actor_extensions->>'f3di:concreteType',
        actor_extensions->>'concreteType',
        actor_extensions->>'http://purl.org/f3di/ns#concreteType'
      ) IN ('3DModel', 'Collection', 'Creator')
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_manyfold_actor_discovery_recent_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_manyfold_actor_discovery_search_index")

    execute("""
    DROP FUNCTION IF EXISTS unfathomably_manyfold_actor_search_document(
      text, text, text, text, jsonb
    )
    """)
  end
end

# end of 20260725220000_add_manyfold_actor_discovery_indexes.exs
