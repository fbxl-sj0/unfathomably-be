defmodule Pleroma.Repo.Migrations.AddActivitiesActorTypeIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS activities_actor_type_index
    """)

    execute("""
    CREATE INDEX CONCURRENTLY activities_actor_type_index
    ON activities (actor, (data ->> 'type'::text), id DESC NULLS LAST)
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS activities_actor_type_index
    """)
  end
end

# end of 20250314153704_add_activities_actor_type_index.exs
