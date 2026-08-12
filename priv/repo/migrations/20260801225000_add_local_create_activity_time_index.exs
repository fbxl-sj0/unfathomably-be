# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddLocalCreateActivityTimeIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activities_local_create_inserted_at_index
    ON activities (inserted_at)
    WHERE local = true AND data->>'type' = 'Create'
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS activities_local_create_inserted_at_index
    """)
  end
end

# end of 20260801225000_add_local_create_activity_time_index.exs
