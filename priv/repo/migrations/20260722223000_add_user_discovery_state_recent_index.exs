# Unfathomably user discovery query support
# ------------------------------------------
#
# File: 20260722223000_add_user_discovery_state_recent_index.exs
#
# Purpose:
#   Keep bounded group and source discovery from scanning the full users table
#   when requesting recently updated, visible remote actors.
#
# Responsibilities:
#   - index the stable actor-state predicates used by discovery catalogs
#   - preserve updated_at ordering inside each state partition
#   - build and remove the index without blocking the live users table
#
# This file intentionally does not classify platforms or alter user records.

defmodule Pleroma.Repo.Migrations.AddUserDiscoveryStateRecentIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_discovery_state_recent_index
    ON users (local, is_active, invisible, updated_at DESC)
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS users_discovery_state_recent_index
    """)
  end
end

# end of 20260722223000_add_user_discovery_state_recent_index.exs
