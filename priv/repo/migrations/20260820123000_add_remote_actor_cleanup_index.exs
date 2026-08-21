# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddRemoteActorCleanupIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_remote_stale_cleanup_index
    ON users (updated_at, id)
    INCLUDE (ap_id, last_refreshed_at, last_status_at)
    WHERE local = false
      AND is_active = true
      AND COALESCE(invisible, false) = false
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_remote_stale_cleanup_index")
  end
end

# end of 20260820123000_add_remote_actor_cleanup_index.exs
