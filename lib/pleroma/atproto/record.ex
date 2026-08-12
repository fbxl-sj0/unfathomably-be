# Unfathomably BE
# ----------------
#
# File: atproto/record.ex
#
# Purpose:
#   Persist an AT Protocol record selected for the local working set.
#
# Responsibilities:
#   - retain strong-reference URI and CID pairs
#   - record the source that made an object locally relevant
#   - map native records to their ActivityPub projections
#
# This file intentionally does NOT implement a Merkle Search Tree, CAR store,
# relay cursor, or full-network archive.

defmodule Pleroma.ATProto.Record do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:uri, :string, autogenerate: false}

  schema "atproto_records" do
    field(:cid, :string)
    field(:author_did, :string)
    field(:collection, :string)
    field(:rkey, :string)
    field(:data, :map)
    field(:source, :string)
    field(:local, :boolean, default: false)
    field(:ap_activity_id, FlakeId.Ecto.CompatType)
    field(:ap_activity_uri, :string)
    field(:ap_object_id, :string)
    field(:indexed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :uri,
      :cid,
      :author_did,
      :collection,
      :rkey,
      :data,
      :source,
      :local,
      :ap_activity_id,
      :ap_activity_uri,
      :ap_object_id,
      :indexed_at
    ])
    |> validate_required([
      :uri,
      :cid,
      :author_did,
      :collection,
      :rkey,
      :data,
      :source,
      :indexed_at
    ])
    |> validate_format(
      :uri,
      ~r/\Aat:\/\/did:(plc|web):[^\/]+\/[a-z][A-Za-z0-9.-]*\/[A-Za-z0-9._~:-]+\z/
    )
    |> validate_format(:author_did, ~r/\Adid:(plc|web):[A-Za-z0-9._:%-]+\z/)
    |> validate_length(:uri, max: 2_048)
    |> validate_length(:cid, max: 256)
    |> validate_length(:collection, max: 253)
    |> validate_length(:rkey, max: 512)
    |> validate_length(:source, max: 32)
    |> unique_constraint(:uri, name: :atproto_records_pkey)
  end
end

# end of atproto/record.ex
