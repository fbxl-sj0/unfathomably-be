# Unfathomably BE database migration
# -----------------------------------
#
# File: 20260722173000_add_public_remote_group_catalog_index.exs
#
# Purpose:
#   Keep the anonymous Worlds projection of public remote Group actors bounded
#   and fast on federation-heavy databases.
#
# Responsibilities:
#   - index active, visible, remote ActivityPub Group actors by recency
#   - leave private, local, inactive, and non-Group accounts out of the index
#
# This file intentionally does not alter actor data, membership records, or
# federation relationships.

defmodule Pleroma.Repo.Migrations.AddPublicRemoteGroupCatalogIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_public_remote_group_recent_index
    ON users (updated_at DESC)
    WHERE local = false
      AND is_active = true
      AND invisible = false
      AND actor_type = 'Group'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_public_remote_group_recent_index")
  end
end

# end of 20260722173000_add_public_remote_group_catalog_index.exs
