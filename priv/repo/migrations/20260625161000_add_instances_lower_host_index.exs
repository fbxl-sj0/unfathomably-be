defmodule Pleroma.Repo.Migrations.AddInstancesLowerHostIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS instances_lower_host_index
    ON instances (lower(host))
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS instances_lower_host_index
    """)
  end
end
