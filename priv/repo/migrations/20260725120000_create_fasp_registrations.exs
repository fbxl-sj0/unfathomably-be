# Unfathomably FASP registration storage
# ---------------------------------------
#
# File: 20260725120000_create_fasp_registrations.exs
#
# Purpose:
#   Persist trust-on-first-contact registration requests from Fediverse
#   Auxiliary Service Providers.
#
# Responsibilities:
#   - retain provider and per-provider server identities
#   - keep encrypted local private keys separate from public registration data
#   - enforce unique message-signature key identifiers
#   - record explicit administrator approval or rejection
#
# This migration intentionally does not activate capabilities or share content.

defmodule Pleroma.Repo.Migrations.CreateFaspRegistrations do
  use Ecto.Migration

  def change do
    create table(:fasp_registrations) do
      add(:name, :string, null: false)
      add(:base_url, :text, null: false)
      add(:provider_server_id, :string, null: false)
      add(:provider_public_key, :binary, null: false)
      add(:fasp_id, :string, null: false)
      add(:local_public_key, :binary, null: false)
      add(:local_private_key_ciphertext, :text, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:provider_info, :map, null: false, default: %{})
      add(:active_capabilities, {:array, :map}, null: false, default: [])
      add(:approved_at, :utc_datetime_usec)
      add(:rejected_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:fasp_registrations, [:base_url]))
    create(unique_index(:fasp_registrations, [:provider_server_id]))
    create(unique_index(:fasp_registrations, [:fasp_id]))
    create(index(:fasp_registrations, [:state, :inserted_at]))

    create(
      constraint(:fasp_registrations, :fasp_registrations_state_constraint,
        check: "state IN ('pending', 'accepted', 'rejected')"
      )
    )
  end
end

# end of 20260725120000_create_fasp_registrations.exs
