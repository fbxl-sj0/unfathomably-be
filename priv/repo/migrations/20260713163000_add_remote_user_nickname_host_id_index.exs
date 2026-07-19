# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddRemoteUserNicknameHostIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # The host is the leading key for peer enumeration. The id suffix also
    # satisfies the deterministic first-actor lookup used by reachability
    # probes without forcing PostgreSQL back to an ordered primary-key scan.
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_remote_nickname_text_host_id_index
    ON users (lower(split_part(nickname::text, '@', 2)), id)
    WHERE local = false AND nickname IS NOT NULL
    """)

    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS users_remote_nickname_text_host_index
    """)
  end

  def down do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_remote_nickname_text_host_index
    ON users (lower(split_part(nickname::text, '@', 2)))
    WHERE local = false AND nickname IS NOT NULL
    """)

    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS users_remote_nickname_text_host_id_index
    """)
  end
end
