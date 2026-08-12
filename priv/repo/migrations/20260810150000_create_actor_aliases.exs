# Unfathomably: Verified remote actor aliases
#
# File: 20260810150000_create_actor_aliases.exs
#
# Purpose:
#   Persist WebFinger handle proofs separately from canonical ActivityPub actor
#   identifiers.

defmodule Pleroma.Repo.Migrations.CreateActorAliases do
  use Ecto.Migration

  def change do
    create table(:actor_aliases) do
      add(:alias, :string, null: false)

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)

      add(:verified_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:actor_aliases, [:alias]))
    create(index(:actor_aliases, [:user_id]))
    create(index(:actor_aliases, [:verified_at]))
  end
end

# end of 20260810150000_create_actor_aliases.exs
