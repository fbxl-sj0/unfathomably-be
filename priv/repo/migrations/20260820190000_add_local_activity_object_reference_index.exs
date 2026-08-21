# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddLocalActivityObjectReferenceIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Retention checks only need references made by local activities. Without
    # this partial index PostgreSQL probes the multi-gigabyte global activity
    # index for every cleanup candidate and filters remote matches afterward.
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activities_local_object_reference_index
    ON activities (associated_object_id(data))
    WHERE local = true AND associated_object_id(data) IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS activities_local_object_reference_index")
  end
end

# end of 20260820190000_add_local_activity_object_reference_index.exs
