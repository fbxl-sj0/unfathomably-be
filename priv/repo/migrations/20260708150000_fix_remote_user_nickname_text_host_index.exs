# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.FixRemoteUserNicknameTextHostIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_remote_nickname_text_host_index
    ON users (lower(split_part(nickname::text, '@', 2)))
    WHERE local = false AND nickname IS NOT NULL
    """)

    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS users_remote_nickname_host_index
    """)
  end

  def down do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_remote_nickname_host_index
    ON users (lower(split_part(nickname, '@', 2)))
    WHERE local = false AND nickname IS NOT NULL
    """)

    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS users_remote_nickname_text_host_index
    """)
  end
end

# end of 20260708150000_fix_remote_user_nickname_text_host_index.exs
