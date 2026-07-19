# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddRemoteObjectCleanupCursorIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Both remote-cache janitors advance by updated_at and id. The partial
    # predicate keeps unrelated ActivityPub objects out of the index and lets
    # retained rows move past the current cleanup window without a table scan.
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_remote_cleanup_updated_id_index
    ON objects (updated_at, id)
    WHERE data->>'type' IN ('Note', 'Article', 'Page', 'Question', 'Event', 'Audio', 'Video')
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS objects_remote_cleanup_updated_id_index
    """)
  end
end

# end of 20260715110000_add_remote_object_cleanup_cursor_index.exs
