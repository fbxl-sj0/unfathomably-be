# Unfathomably notification pagination index
# -------------------------------------------
#
# File: 20260729170000_add_notification_type_pagination_index.exs
#
# Purpose:
#   Keep notification type filters on the same ordered index path used for
#   cursor pagination.
#
# Responsibilities:
#   - locate one user's notifications by type without scanning unrelated rows
#   - preserve descending notification ID pagination
#   - build and remove the index without blocking normal notification writes
#
# This file intentionally does not change notification data, visibility
# filtering, grouping, or API response behavior.

defmodule Pleroma.Repo.Migrations.AddNotificationTypePaginationIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS notifications_user_id_type_id_desc_nulls_last_index
    ON notifications (user_id, type, id DESC NULLS LAST)
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS notifications_user_id_type_id_desc_nulls_last_index
    """)
  end
end

# end of 20260729170000_add_notification_type_pagination_index.exs
