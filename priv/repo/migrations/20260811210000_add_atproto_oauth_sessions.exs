# Unfathomably BE
# ----------------
#
# File: 20260811210000_add_atproto_oauth_sessions.exs
#
# Purpose:
#   Persist standards-compliant AT Protocol OAuth authorization sessions.
#
# Responsibilities:
#   - distinguish legacy app-password links from DPoP-bound OAuth links
#   - retain encrypted per-session DPoP keys and OAuth refresh coordinates
#   - store short-lived, one-use PAR/PKCE callback state
#
# This file intentionally does NOT expose plaintext tokens or create any
# full-network synchronization/firehose storage.

defmodule Pleroma.Repo.Migrations.AddAtprotoOauthSessions do
  use Ecto.Migration

  def change do
    alter table(:atproto_links) do
      add(:auth_method, :string, null: false, default: "password")
      add(:oauth_issuer, :string)
      add(:oauth_scope, :text)
      add(:oauth_token_endpoint, :string)
      add(:dpop_key_ciphertext, :text)
      add(:pds_dpop_nonce, :string)
      add(:auth_dpop_nonce, :string)
    end

    create table(:atproto_oauth_requests, primary_key: false) do
      add(:state, :string, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:did, :string, null: false)
      add(:handle, :string, null: false)
      add(:pds_url, :string, null: false)
      add(:issuer, :string, null: false)
      add(:authorization_endpoint, :string, null: false)
      add(:token_endpoint, :string, null: false)
      add(:scope, :text, null: false)
      add(:pkce_verifier_ciphertext, :text, null: false)
      add(:dpop_key_ciphertext, :text, null: false)
      add(:authorization_dpop_nonce, :string, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:atproto_oauth_requests, [:user_id]))
    create(index(:atproto_oauth_requests, [:expires_at]))
  end
end

# end of 20260811210000_add_atproto_oauth_sessions.exs
