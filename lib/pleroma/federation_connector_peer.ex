# Unfathomably BE
# ----------------
#
# File: federation_connector_peer.ex
#
# Purpose:
#   Store administrator-approved service actors for specialised federation.
#
# Responsibilities:
#   - keep connector configuration separate from ordinary account follows
#   - retain the remote service actor selected by an administrator
#   - provide conflict-safe connector updates
#
# This file intentionally does not fetch peers or deliver activities.

defmodule Pleroma.FederationConnectorPeer do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Pleroma.Repo

  @families ~w[marketplace]

  schema "federation_connector_peers" do
    field(:actor_ap_id, :string)
    field(:enabled, :boolean, default: true)
    field(:family, :string)
    field(:scope, :map, default: %{})

    timestamps()
  end

  def changeset(peer, attrs) do
    peer
    |> cast(attrs, [:actor_ap_id, :enabled, :family, :scope])
    |> validate_required([:actor_ap_id, :enabled, :family])
    |> validate_inclusion(:family, @families)
    |> validate_format(:actor_ap_id, ~r/^https:\/\//)
    |> unique_constraint([:family, :actor_ap_id],
      name: :federation_connector_peers_family_actor_ap_id_index
    )
  end

  def list(family) when family in @families do
    __MODULE__
    |> where(family: ^family)
    |> order_by([peer], asc: peer.actor_ap_id)
    |> Repo.all()
  end

  def list(_family), do: []

  def enabled(family) when family in @families do
    __MODULE__
    |> where(family: ^family, enabled: true)
    |> order_by([peer], asc: peer.actor_ap_id)
    |> Repo.all()
  end

  def enabled(_family), do: []

  def get(id, family) when family in @families do
    __MODULE__
    |> where(id: ^id, family: ^family)
    |> Repo.one()
  end

  def get(_id, _family), do: nil

  def upsert(family, actor_ap_id, attrs \\ %{}) when family in @families do
    attrs = Map.merge(Map.new(attrs), %{actor_ap_id: actor_ap_id, enabled: true, family: family})

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:enabled, :scope, :updated_at]},
      conflict_target: [:family, :actor_ap_id],
      returning: true
    )
  end

  def delete(%__MODULE__{} = peer), do: Repo.delete(peer)
end

# end of lib/pleroma/federation_connector_peer.ex
