# Unfathomably BE
# ----------------
#
# File: diaspora/record.ex
#
# Purpose:
#   Persist a verified diaspora* entity selected for local use.
#
# Responsibilities:
#   - retain the signed XML representation needed for public fetches
#   - map native GUIDs to local ActivityPub activities and objects
#   - preserve unknown relayable fields in the original XML
#
# This file intentionally does NOT retain decrypted transport envelopes or
# unbounded pod history.

defmodule Pleroma.Diaspora.Record do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:guid, :string, autogenerate: false}

  schema "diaspora_records" do
    field(:author, :string)
    field(:type, :string)
    field(:data, :map)
    field(:raw_xml, :string)
    field(:local, :boolean, default: false)
    field(:ap_activity_id, FlakeId.Ecto.CompatType)
    field(:ap_activity_uri, :string)
    field(:ap_object_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :guid,
      :author,
      :type,
      :data,
      :raw_xml,
      :local,
      :ap_activity_id,
      :ap_activity_uri,
      :ap_object_id
    ])
    |> validate_required([:guid, :author, :type, :data, :raw_xml])
    |> validate_format(:guid, ~r/\A[A-Za-z0-9][A-Za-z0-9_@.:-]{14,253}[A-Za-z0-9]\z/)
    |> validate_format(:author, ~r/\A[^@\s\/]+@[^@\s\/]+\z/)
    |> validate_length(:guid, max: 255)
    |> validate_length(:author, max: 320)
    |> validate_length(:type, max: 64)
    |> unique_constraint(:guid, name: :diaspora_records_pkey)
  end
end

# end of diaspora/record.ex
