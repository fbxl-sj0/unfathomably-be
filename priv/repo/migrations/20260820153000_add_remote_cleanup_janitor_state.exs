# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddRemoteCleanupJanitorState do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS janitor_states (
      name text PRIMARY KEY,
      cursor text,
      full_sweep boolean NOT NULL DEFAULT true,
      cycle_scanned bigint NOT NULL DEFAULT 0,
      cycle_deleted bigint NOT NULL DEFAULT 0,
      cycle_started_at timestamp without time zone,
      completed_at timestamp without time zone,
      last_full_sweep_at timestamp without time zone,
      inserted_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL
    )
    """)

    # UUID order follows Pleroma's sortable activity identifiers. Persisting
    # this cursor lets cleanup advance without touching retained rows merely to
    # move them out of the next candidate window.
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activities_remote_orphan_cleanup_cursor_index
    ON activities (id)
    WHERE local = false
      AND jsonb_typeof(data->'object') = 'string'
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_remote_tombstone_cleanup_index
    ON objects (updated_at, id)
    WHERE data->>'type' = 'Tombstone'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS activities_remote_orphan_cleanup_cursor_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_remote_tombstone_cleanup_index")
    execute("DROP TABLE IF EXISTS janitor_states")
  end
end

# end of 20260820153000_add_remote_cleanup_janitor_state.exs
