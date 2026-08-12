# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.CreateFederationConnectorPeers do
  use Ecto.Migration

  def change do
    create table(:federation_connector_peers) do
      add(:family, :string, null: false)
      add(:actor_ap_id, :text, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:scope, :map, null: false, default: %{})

      timestamps()
    end

    create(
      unique_index(:federation_connector_peers, [:family, :actor_ap_id],
        name: :federation_connector_peers_family_actor_ap_id_index
      )
    )
  end
end

# end of priv/repo/migrations/20260721153000_create_federation_connector_peers.exs
