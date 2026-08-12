# Unfathomably BE
# ----------------
#
# File: atproto/identity.ex
#
# Purpose:
#   Map a remote AT Protocol DID to its local ActivityPub projection user.
#
# Responsibilities:
#   - validate stable DID, handle, PDS, and profile metadata fields
#   - retain the last bounded synchronization time for followed identities
#   - provide indexed associations used by selective timeline ingestion
#
# This file intentionally does NOT resolve DIDs, call an AppView, or hold PDS
# credentials.

defmodule Pleroma.ATProto.Identity do
  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.User

  @primary_key {:id, FlakeId.Ecto.CompatType, autogenerate: true}

  schema "atproto_identities" do
    field(:did, :string)
    field(:handle, :string)
    field(:pds_url, :string)
    field(:metadata, :map, default: %{})
    field(:last_synced_at, :utc_datetime_usec)

    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:user_id, :did, :handle, :pds_url, :metadata, :last_synced_at])
    |> validate_required([:user_id, :did])
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

  defp validate_handle(:handle, nil), do: []

  defp validate_handle(:handle, handle) do
    if Pleroma.ATProto.Validation.valid_handle?(handle),
      do: [],
      else: [handle: "is not a valid AT handle"]
  end
end

# end of atproto/identity.ex
