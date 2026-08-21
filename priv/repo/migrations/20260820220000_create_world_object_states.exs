# Unfathomably Worlds workspace state
# -----------------------------------
#
# File: 20260820220000_create_world_object_states.exs
#
# Purpose:
#   Store private-by-default user workflow state for native federated objects.
#
# Responsibilities:
#   - enforce one workspace entry per user and object URI
#   - support efficient family, state, and public profile views
#   - remove workspace entries when their local user is deleted
#
# This file intentionally does not create ActivityPub activities or timelines.

defmodule Pleroma.Repo.Migrations.CreateWorldObjectStates do
  use Ecto.Migration

  def change do
    create table(:world_object_states) do
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:object_uri, :text, null: false)
      add(:family, :string, null: false)
      add(:state, :string, null: false)
      add(:progress, :float)
      add(:progress_total, :float)
      add(:progress_unit, :string)
      add(:rating, :integer)
      add(:note, :text)
      add(:public, :boolean, null: false, default: false)
      add(:presentation, :map, null: false, default: %{})
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)

      timestamps()
    end

    create(unique_index(:world_object_states, [:user_id, :object_uri]))
    create(index(:world_object_states, [:user_id, :family, :state, :updated_at]))
    create(index(:world_object_states, [:user_id, :family, :updated_at], where: "public"))
  end
end

# end of 20260820220000_create_world_object_states.exs
