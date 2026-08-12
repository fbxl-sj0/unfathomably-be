# Unfathomably: notification persistence integrity
#
# File: 20260810120000_enforce_notification_event_uniqueness.exs
#
# Purpose:
#   Ensure that one ActivityPub activity can create at most one notification
#   for a particular local user, including during concurrent delivery races.
#
# This migration intentionally does not change notification grouping or the
# notification type enum. Those are presentation concerns rather than event
# identity concerns.

defmodule Pleroma.Repo.Migrations.EnforceNotificationEventUniqueness do
  use Ecto.Migration

  @index_name :notifications_user_id_activity_id_index

  def up do
    # Federation workers may attempt the same delivery at the same time. Hold
    # writes while historical duplicates are merged and the invariant becomes
    # enforceable, otherwise a new duplicate could enter between cleanup and
    # index creation.
    execute("LOCK TABLE notifications IN SHARE ROW EXCLUSIVE MODE")

    # If any copy was still unread, keep the surviving notification unread.
    # This avoids losing a pending notification merely because another copy was
    # marked read during earlier duplicate processing.
    execute("""
    WITH duplicate_state AS (
      SELECT
        user_id,
        activity_id,
        COALESCE(bool_and(seen), false) AS seen
      FROM notifications
      WHERE activity_id IS NOT NULL
      GROUP BY user_id, activity_id
      HAVING count(*) > 1
    )
    UPDATE notifications AS notification
    SET seen = duplicate_state.seen
    FROM duplicate_state
    WHERE notification.user_id = duplicate_state.user_id
      AND notification.activity_id = duplicate_state.activity_id
    """)

    execute("""
    WITH ranked_notifications AS (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY user_id, activity_id
          ORDER BY inserted_at DESC NULLS LAST, id DESC
        ) AS duplicate_rank
      FROM notifications
      WHERE activity_id IS NOT NULL
    )
    DELETE FROM notifications AS notification
    USING ranked_notifications
    WHERE notification.id = ranked_notifications.id
      AND ranked_notifications.duplicate_rank > 1
    """)

    create(unique_index(:notifications, [:user_id, :activity_id], name: @index_name))
  end

  def down do
    drop_if_exists(index(:notifications, [:user_id, :activity_id], name: @index_name))
  end
end

# end of 20260810120000_enforce_notification_event_uniqueness.exs
