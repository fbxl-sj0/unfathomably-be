# Unfathomably BE
# ----------------
#
# File: 20260812093000_add_local_activity_context_index.exs
#
# Purpose:
#   Bound thread-retention checks performed by remote post cleanup.
#
# Responsibilities:
#   - index contexts for local activities only
#   - support preservation of any locally touched remote thread
#
# This migration intentionally does NOT index remote activity contexts or
# change the cleanup worker's conservative retention policy.

defmodule Pleroma.Repo.Migrations.AddLocalActivityContextIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:activities, ["((data->>'context'))"],
        name: :activities_local_context_index,
        concurrently: true,
        where: "local = true AND data->>'context' IS NOT NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:activities, ["((data->>'context'))"],
        name: :activities_local_context_index,
        concurrently: true
      )
    )
  end
end

# end of 20260812093000_add_local_activity_context_index.exs
