# Unfathomably native protocol projection location
# -------------------------------------------------
#
# File: 20260811090000_mark_native_protocol_projections_remote.exs
#
# Purpose:
#   Correct the location of activities imported from non-ActivityPub protocols.
#
# Responsibilities:
#   * identify activities through their durable bridge-record mappings
#   * keep imported Nostr, ATProto, and diaspora* work off local timelines
#
# This migration intentionally does NOT alter the projection users. Those users
# remain locally hosted ActivityPub actors so the server can sign and serve the
# projection, while account APIs classify their represented identities remote.

defmodule Pleroma.Repo.Migrations.MarkNativeProtocolProjectionsRemote do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE activities AS activity
    SET local = FALSE
    FROM (
      SELECT ap_activity_id FROM nostr_events WHERE ap_activity_id IS NOT NULL
      UNION
      SELECT ap_activity_id FROM atproto_records WHERE ap_activity_id IS NOT NULL
      UNION
      SELECT ap_activity_id FROM diaspora_records WHERE ap_activity_id IS NOT NULL
    ) AS projection
    WHERE activity.id = projection.ap_activity_id
      AND activity.local = TRUE
    """)
  end

  def down do
    execute("""
    UPDATE activities AS activity
    SET local = TRUE
    FROM (
      SELECT ap_activity_id FROM nostr_events WHERE ap_activity_id IS NOT NULL
      UNION
      SELECT ap_activity_id FROM atproto_records WHERE ap_activity_id IS NOT NULL
      UNION
      SELECT ap_activity_id FROM diaspora_records WHERE ap_activity_id IS NOT NULL
    ) AS projection
    WHERE activity.id = projection.ap_activity_id
      AND activity.local = FALSE
    """)
  end
end

# end of 20260811090000_mark_native_protocol_projections_remote.exs
