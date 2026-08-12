# Unfathomably Backend
#
# File: 20260810160000_create_federated_target_curations.exs
#
# Purpose:
#   Add reversible administrator curation for remote Worlds communities.
#
# This migration intentionally does not create follows or copy actor data.

defmodule Pleroma.Repo.Migrations.CreateFederatedTargetCurations do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:federated_target_curations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:target_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:position, :integer, null: false, default: 0)

      timestamps()
    end

    create_if_not_exists(unique_index(:federated_target_curations, [:target_id]))

    create_if_not_exists(
      index(:federated_target_curations, [:enabled, :position],
        name: :federated_target_curations_catalog_index
      )
    )

    create(
      constraint(:federated_target_curations, :federated_target_curations_position_check,
        check: "position >= 0 AND position <= 1000000"
      )
    )
  end
end

# end of priv/repo/migrations/20260810160000_create_federated_target_curations.exs
