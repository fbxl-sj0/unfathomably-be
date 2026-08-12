# Unfathomably account discovery
#
# File: 20260729223000_add_user_directory_active_index.exs
#
# Purpose:
#   Keep the Mastodon-compatible active account directory responsive when a
#   server knows hundreds of thousands of local and remote actors.
#
# Responsibilities:
#   - add the ordering index used by the active directory query
#   - create and remove the index without blocking normal user-table writes
#
# This file intentionally does not define account discovery policy or API
# rendering behavior.

defmodule Pleroma.Repo.Migrations.AddUserDirectoryActiveIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_directory_active_index
    ON users (
      is_discoverable,
      invisible,
      last_status_at DESC NULLS LAST,
      id DESC NULLS LAST
    )
    WHERE nickname IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_directory_active_index")
  end
end

# end of 20260729223000_add_user_directory_active_index.exs
