defmodule Pleroma.Repo.Migrations.AddActivityActorHostIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS activities_actor_host_function_index
    ON activities (ap_id_host(actor))
    WHERE actor IS NOT NULL
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS activities_actor_host_function_index
    """)
  end
end

# end of 20260629103000_add_activity_actor_host_index.exs
