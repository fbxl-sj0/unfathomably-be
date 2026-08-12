# Unfathomably BE
# ----------------
#
# File: 20260812150000_add_appendable_collection_index.exs
#
# Purpose:
#   Keep FEP-400e wall membership lookups bounded on large object tables.
#
# Responsibilities:
#   - index the confirmed appendable collection identifier
#   - exclude all ordinary objects from the index
#   - build without blocking live object writes
#
# This migration intentionally does NOT index unconfirmed target claims.

defmodule Pleroma.Repo.Migrations.AddAppendableCollectionIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:objects, ["((data->'_unfathomably_appendable_collection'->>'collection'))"],
        name: :objects_appendable_collection_index,
        concurrently: true,
        where: "data ? '_unfathomably_appendable_collection'"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:objects, ["((data->'_unfathomably_appendable_collection'->>'collection'))"],
        name: :objects_appendable_collection_index,
        concurrently: true
      )
    )
  end
end

# end of 20260812150000_add_appendable_collection_index.exs
