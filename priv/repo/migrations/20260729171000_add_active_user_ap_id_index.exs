# Unfathomably active actor lookup index
# ---------------------------------------
#
# File: 20260729171000_add_active_user_ap_id_index.exs
#
# Purpose:
#   Resolve active ActivityPub actors without scanning the wide users table.
#
# Responsibilities:
#   - provide a narrow active-user AP ID lookup path
#   - accelerate notification actor joins and other active-actor checks
#   - build and remove the index without blocking normal user updates
#
# This file intentionally does not change account activation state, actor
# identity, visibility policy, or notification filtering.

defmodule Pleroma.Repo.Migrations.AddActiveUserApIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_active_ap_id_index
    ON users (ap_id)
    WHERE is_active = true
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_active_ap_id_index")
  end
end

# end of 20260729171000_add_active_user_ap_id_index.exs
