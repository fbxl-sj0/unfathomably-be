# Unfathomably BE
# ----------------
#
# File: atproto/oauth_request.ex
#
# Purpose:
#   Persist one short-lived AT Protocol OAuth authorization attempt.
#
# Responsibilities:
#   - bind an unguessable OAuth state value to one local user and expected DID
#   - retain encrypted PKCE and DPoP secrets across the browser redirect
#   - expire abandoned requests promptly
#
# This file intentionally does NOT store access tokens, process callbacks, or
# authorize repository operations.

defmodule Pleroma.ATProto.OAuthRequest do
  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.User

  @primary_key false

  schema "atproto_oauth_requests" do
    field(:state, :string, primary_key: true)
    field(:did, :string)
    field(:handle, :string)
    field(:pds_url, :string)
    field(:issuer, :string)
    field(:authorization_endpoint, :string)
    field(:token_endpoint, :string)
    field(:scope, :string)
    field(:pkce_verifier_ciphertext, :string)
    field(:dpop_key_ciphertext, :string)
    field(:authorization_dpop_nonce, :string)
    field(:expires_at, :utc_datetime_usec)

    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :state,
      :user_id,
      :did,
      :handle,
      :pds_url,
      :issuer,
      :authorization_endpoint,
      :token_endpoint,
      :scope,
      :pkce_verifier_ciphertext,
      :dpop_key_ciphertext,
      :authorization_dpop_nonce,
      :expires_at
    ])
    |> validate_required([
      :state,
      :user_id,
      :did,
      :handle,
      :pds_url,
      :issuer,
      :authorization_endpoint,
      :token_endpoint,
      :scope,
      :pkce_verifier_ciphertext,
      :dpop_key_ciphertext,
      :authorization_dpop_nonce,
      :expires_at
    ])
    |> validate_length(:state, min: 32, max: 128)
    |> validate_length(:did, max: 2_048)
    |> validate_length(:handle, max: 253)
    |> validate_length(:scope, max: 4_096)
    |> unique_constraint(:state, name: :atproto_oauth_requests_pkey)
  end
end

# end of atproto/oauth_request.ex
