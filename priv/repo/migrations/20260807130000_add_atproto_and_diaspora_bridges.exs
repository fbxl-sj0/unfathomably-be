# Unfathomably BE
# ----------------
#
# File: 20260807130000_add_atproto_and_diaspora_bridges.exs
#
# Purpose:
#   Persist the bounded working sets used by the AT Protocol and diaspora*
#   bridges.
#
# Responsibilities:
#   - map remote protocol identities onto local ActivityPub projection users
#   - retain only records selected by follows, explicit opens, and interactions
#   - keep encrypted AT Protocol PDS sessions separate from public identity data
#   - map native records to the ActivityPub activities created for the UI
#
# This file intentionally does NOT store an AT Protocol firehose, a complete
# repository mirror, diaspora* private message plaintext, or user passwords.

defmodule Pleroma.Repo.Migrations.AddAtprotoAndDiasporaBridges do
  use Ecto.Migration

  def change do
    create table(:atproto_identities, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:did, :string, null: false)
      add(:handle, :string)
      add(:pds_url, :string)
      add(:metadata, :map, null: false, default: %{})
      add(:last_synced_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:atproto_identities, [:user_id]))
    create(unique_index(:atproto_identities, [:did]))
    create(index(:atproto_identities, [:handle]))

    create table(:atproto_links, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:did, :string, null: false)
      add(:handle, :string, null: false)
      add(:pds_url, :string, null: false)
      add(:access_token_ciphertext, :text, null: false)
      add(:refresh_token_ciphertext, :text, null: false)
      add(:session_updated_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:atproto_links, [:user_id]))
    create(unique_index(:atproto_links, [:did]))

    create table(:atproto_records, primary_key: false) do
      add(:uri, :string, primary_key: true)
      add(:cid, :string, null: false)
      add(:author_did, :string, null: false)
      add(:collection, :string, null: false)
      add(:rkey, :string, null: false)
      add(:data, :map, null: false)
      add(:source, :string, null: false)
      add(:local, :boolean, null: false, default: false)
      add(:ap_activity_id, :uuid)
      add(:ap_activity_uri, :string)
      add(:ap_object_id, :string)
      add(:indexed_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:atproto_records, [:author_did, :indexed_at]))
    create(index(:atproto_records, [:collection, :indexed_at]))
    create(index(:atproto_records, [:ap_activity_id]))
    create(index(:atproto_records, [:ap_activity_uri]))
    create(index(:atproto_records, [:ap_object_id]))

    create table(:diaspora_entities, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:diaspora_id, :string, null: false)
      add(:guid, :string, null: false)
      add(:pod_url, :string, null: false)
      add(:profile_url, :string)
      add(:receive_url, :string)
      add(:public_key, :text, null: false)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:diaspora_entities, [:user_id]))
    create(unique_index(:diaspora_entities, [:diaspora_id]))
    create(unique_index(:diaspora_entities, [:guid]))
    create(index(:diaspora_entities, [:pod_url]))

    create table(:diaspora_records, primary_key: false) do
      add(:guid, :string, primary_key: true)
      add(:author, :string, null: false)
      add(:type, :string, null: false)
      add(:data, :map, null: false)
      add(:raw_xml, :text, null: false)
      add(:local, :boolean, null: false, default: false)
      add(:ap_activity_id, :uuid)
      add(:ap_activity_uri, :string)
      add(:ap_object_id, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:diaspora_records, [:author, :inserted_at]))
    create(index(:diaspora_records, [:type, :inserted_at]))
    create(index(:diaspora_records, [:ap_activity_id]))
    create(index(:diaspora_records, [:ap_activity_uri]))
    create(index(:diaspora_records, [:ap_object_id]))
  end
end

# end of 20260807130000_add_atproto_and_diaspora_bridges.exs
