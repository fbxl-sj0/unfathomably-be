# Unfathomably BE
# ----------------
#
# File: nostr/event.ex
#
# Purpose:
#   Represent verified Nostr event envelopes and their ActivityPub mappings.
#
# Responsibilities:
#   - define indexed event identity, relay, and replacement fields
#   - retain the exact verified wire map for relay responses
#   - map bridge events to canonical ActivityPub activities and objects
#
# This file intentionally does NOT validate signatures, authorize relay
# clients, or translate event semantics.

defmodule Pleroma.Nostr.Event do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "nostr_events" do
    field(:pubkey, :string)
    field(:kind, :integer)
    field(:created_at, :utc_datetime_usec)
    field(:relay_url, :string)
    field(:local, :boolean, default: false)
    field(:replace_key, :string)
    field(:data, :map)
    field(:ap_activity_id, FlakeId.Ecto.CompatType)
    field(:ap_activity_uri, :string)
    field(:ap_object_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :pubkey,
      :kind,
      :created_at,
      :relay_url,
      :local,
      :replace_key,
      :data,
      :ap_activity_id,
      :ap_activity_uri,
      :ap_object_id
    ])
    |> validate_required([:id, :pubkey, :kind, :created_at, :data])
    |> validate_format(:id, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:pubkey, ~r/^[0-9a-f]{64}$/)
    |> validate_number(:kind, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
    |> unique_constraint(:id, name: :nostr_events_pkey)
  end
end

# end of nostr/event.ex
