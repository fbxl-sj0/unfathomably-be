# Unfathomably BE
# ----------------
#
# File: 20260728120000_add_nostr_bridge_tables.exs
#
# Purpose:
#   Persist bounded Nostr events and their ActivityPub bridge identities.
#
# Responsibilities:
#   - store verified event envelopes and AP mapping identifiers
#   - map Nostr profiles and relay-scoped NIP-29 groups to User records
#   - index relay subscription, replacement, and bridge lookup paths
#
# This file intentionally does NOT store private Nostr keys, open a relay
# connection, or translate protocol events.

defmodule Pleroma.Repo.Migrations.AddNostrBridgeTables do
  use Ecto.Migration

  def change do
    create table(:nostr_entities, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:pubkey, :string, null: false)
      add(:relay_url, :string)
      add(:group_id, :string)
      add(:metadata, :map, null: false, default: %{})
      add(:latest_metadata_event_id, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:nostr_entities, [:user_id]))

    create(
      unique_index(:nostr_entities, [:pubkey],
        where: "group_id IS NULL",
        name: :nostr_entities_profile_pubkey_index
      )
    )

    create(
      unique_index(:nostr_entities, [:relay_url, :group_id],
        where: "group_id IS NOT NULL",
        name: :nostr_entities_relay_group_index
      )
    )

    create(index(:nostr_entities, [:relay_url]))

    create table(:nostr_events, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:pubkey, :string, null: false)
      add(:kind, :integer, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:relay_url, :string)
      add(:local, :boolean, null: false, default: false)
      add(:replace_key, :string)
      add(:data, :map, null: false)
      add(:ap_activity_id, :uuid)
      add(:ap_object_id, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:nostr_events, [:pubkey, :kind, :created_at]))
    create(index(:nostr_events, [:kind, :created_at]))
    create(index(:nostr_events, [:relay_url, :created_at]))
    create(index(:nostr_events, [:ap_activity_id]))
    create(index(:nostr_events, [:ap_object_id]))
    create(index(:nostr_events, [:replace_key]))
    create(index(:nostr_events, ["(data->'tags')"], using: :gin))
  end
end

# end of 20260728120000_add_nostr_bridge_tables.exs
