defmodule Pleroma.Repo.Migrations.AddLocalPublicCreateSearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:activities, ["associated_object_id(data)"],
        name: :activities_local_public_create_object_index,
        concurrently: true,
        where:
          "local = true AND data->>'type' = 'Create' AND " <>
            "'https://www.w3.org/ns/activitystreams#Public' = ANY(recipients)"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:activities, ["associated_object_id(data)"],
        name: :activities_local_public_create_object_index,
        concurrently: true
      )
    )
  end
end
