# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddRemoteUserNicknameHostIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_remote_nickname_host_index
    ON users (lower(split_part(nickname, '@', 2)))
    WHERE local = false AND nickname IS NOT NULL
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS users_remote_nickname_host_index
    """)
  end
end

# end of 20260629115000_add_remote_user_nickname_host_index.exs
