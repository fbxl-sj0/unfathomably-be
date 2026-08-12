# Unfathomably local user lookup index
# -------------------------------------
#
# File: 20260729123500_add_local_user_id_index.exs
#
# Purpose:
#   Keep local-follower joins off the wide users table on large instances.
#
# Responsibilities:
#   - provide a compact index-only source of local user IDs
#   - accelerate Nostr relay subscriptions and other local-follower queries
#   - avoid low-selectivity scans through the general users_local_index
#
# This file intentionally does not change account locality, following
# relationships, or Nostr bridge eligibility.

defmodule Pleroma.Repo.Migrations.AddLocalUserIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_local_id_index
    ON users (id)
    WHERE local = true
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_local_id_index")
  end
end

# end of 20260729123500_add_local_user_id_index.exs
