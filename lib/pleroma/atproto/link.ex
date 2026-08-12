# Unfathomably BE
# ----------------
#
# File: atproto/link.ex
#
# Purpose:
#   Store one local user's authorized AT Protocol PDS session.
#
# Responsibilities:
#   - associate one local user with one external DID
#   - retain encrypted access and refresh tokens
#   - retain encrypted DPoP material for OAuth-authorized sessions
#   - validate the public session coordinates needed for token refresh
#
# This file intentionally does NOT retain account passwords, decrypt tokens, or
# make authenticated requests.

defmodule Pleroma.ATProto.Link do
  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.User

  @primary_key {:id, FlakeId.Ecto.CompatType, autogenerate: true}

  schema "atproto_links" do
    field(:did, :string)
    field(:handle, :string)
    field(:pds_url, :string)
    field(:access_token_ciphertext, :string)
    field(:refresh_token_ciphertext, :string)
    field(:session_updated_at, :utc_datetime_usec)
    field(:managed, :boolean, default: false)
    field(:auth_method, :string, default: "password")
    field(:oauth_issuer, :string)
    field(:oauth_scope, :string)
    field(:oauth_token_endpoint, :string)
    field(:dpop_key_ciphertext, :string)
    field(:pds_dpop_nonce, :string)
    field(:auth_dpop_nonce, :string)

    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :user_id,
      :did,
      :handle,
      :pds_url,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :session_updated_at,
      :managed,
      :auth_method,
      :oauth_issuer,
      :oauth_scope,
      :oauth_token_endpoint,
      :dpop_key_ciphertext,
      :pds_dpop_nonce,
      :auth_dpop_nonce
    ])
    |> validate_required([
      :user_id,
      :did,
      :handle,
      :pds_url,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :session_updated_at,
      :managed,
      :auth_method
    ])
    |> validate_inclusion(:auth_method, ["password", "oauth"])
    |> validate_oauth_fields()
    |> validate_change(:did, &validate_did/2)
    |> validate_change(:handle, &validate_handle/2)
    |> validate_length(:did, max: 2_048)
    |> validate_length(:handle, max: 253)
    |> validate_length(:pds_url, max: 2_048)
    |> unique_constraint(:user_id)
    |> unique_constraint(:did)
  end

  defp validate_did(:did, did) do
    if Pleroma.ATProto.Validation.valid_did?(did), do: [], else: [did: "is not a valid AT DID"]
  end

  defp validate_handle(:handle, handle) do
    if Pleroma.ATProto.Validation.valid_handle?(handle),
      do: [],
      else: [handle: "is not a valid AT handle"]
  end

  defp validate_oauth_fields(changeset) do
    if get_field(changeset, :auth_method) == "oauth" do
      validate_required(changeset, [
        :oauth_issuer,
        :oauth_scope,
        :oauth_token_endpoint,
        :dpop_key_ciphertext
      ])
    else
      changeset
    end
  end
end

# end of atproto/link.ex
