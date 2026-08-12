# Unfathomably BE
# ----------------
#
# File: nostr/entity.ex
#
# Purpose:
#   Map Nostr identities and relay-scoped groups to User records.
#
# Responsibilities:
#   - define the bridge identity schema
#   - validate profile, local actor, and NIP-29 group mappings
#   - retain bounded relay metadata used by discovery and synchronization
#
# This file intentionally does NOT create users, fetch relay events, or store
# private keys.

defmodule Pleroma.Nostr.Entity do
  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.User

  @kinds ~w(local_actor local_group mirror_profile mirror_group)
  @primary_key {:id, FlakeId.Ecto.CompatType, autogenerate: true}

  schema "nostr_entities" do
    field(:kind, :string)
    field(:pubkey, :string)
    field(:relay_url, :string)
    field(:group_id, :string)
    field(:metadata, :map, default: %{})
    field(:latest_metadata_event_id, :string)

    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [
      :user_id,
      :kind,
      :pubkey,
      :relay_url,
      :group_id,
      :metadata,
      :latest_metadata_event_id
    ])
    |> validate_required([:user_id, :kind, :pubkey])
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:pubkey, ~r/^[0-9a-f]{64}$/)
    |> validate_length(:relay_url, max: 2_048)
    |> validate_length(:group_id, max: 512)
    |> unique_constraint(:user_id)
    |> unique_constraint(:pubkey, name: :nostr_entities_profile_pubkey_index)
    |> unique_constraint([:relay_url, :group_id], name: :nostr_entities_relay_group_index)
  end
end

# end of nostr/entity.ex
