defmodule Pleroma.Repo.Migrations.AddApIdHostFunctionAndIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION ap_id_host(ap_id text)
    RETURNS text AS $$
      SELECT NULLIF(
        trim(
          trailing '.'
          from lower(split_part(substring(ap_id from '.*://([^/]*)'), ':', 1))
        ),
        ''
      )
    $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_ap_id_host_function_index
    ON users (ap_id_host(ap_id))
    WHERE ap_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_publisher_inbox_host_index
    ON oban_jobs (ap_id_host(coalesce(args #>> '{params,inbox}', args->>'inbox')))
    WHERE queue = 'federator_outgoing'
      AND worker = 'Pleroma.Workers.PublisherWorker'
      AND state IN ('available', 'scheduled', 'retryable')
      AND coalesce(args #>> '{params,inbox}', args->>'inbox') ~* '^https?://'
    """)

    create_if_not_exists(
      index(:following_relationships, [:following_id, :state],
        name: :following_relationships_following_id_state_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:following_relationships, [:following_id, :state],
        name: :following_relationships_following_id_state_index,
        concurrently: true
      )
    )

    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_publisher_inbox_host_index
    """)

    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS users_ap_id_host_function_index
    """)

    execute("""
    DROP FUNCTION IF EXISTS ap_id_host(text)
    """)
  end
end
