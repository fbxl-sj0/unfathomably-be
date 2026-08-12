# Unfathomably BE
# ----------------
#
# File: diaspora/entity.ex
#
# Purpose:
#   Map a diaspora* identity to its local ActivityPub projection user.
#
# Responsibilities:
#   - retain verified discovery and public-key material
#   - index diaspora* IDs and GUIDs independently
#   - expose the public and private delivery coordinates for a pod identity
#
# This file intentionally does NOT parse hCards, verify envelopes, or deliver
# federation messages.

defmodule Pleroma.Diaspora.Entity do
  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.User

  @primary_key {:id, FlakeId.Ecto.CompatType, autogenerate: true}

  schema "diaspora_entities" do
    field(:diaspora_id, :string)
    field(:guid, :string)
    field(:pod_url, :string)
    field(:profile_url, :string)
    field(:receive_url, :string)
    field(:public_key, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [
      :user_id,
      :diaspora_id,
      :guid,
      :pod_url,
      :profile_url,
      :receive_url,
      :public_key,
      :metadata
    ])
    |> validate_required([:user_id, :diaspora_id, :guid, :pod_url, :public_key])
    |> validate_format(:diaspora_id, ~r/\A[^@\s\/]+@[^@\s\/]+\z/)
    |> validate_format(:guid, ~r/\A[A-Za-z0-9][A-Za-z0-9_@.:-]{14,253}[A-Za-z0-9]\z/)
    |> validate_length(:diaspora_id, max: 320)
    |> validate_length(:guid, max: 255)
    |> validate_length(:pod_url, max: 2_048)
    |> validate_length(:profile_url, max: 2_048)
    |> validate_length(:receive_url, max: 2_048)
    |> validate_length(:public_key, max: 65_535)
    |> unique_constraint(:user_id)
    |> unique_constraint(:diaspora_id)
    |> unique_constraint(:guid)
  end
end

# end of diaspora/entity.ex
