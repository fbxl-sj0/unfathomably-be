# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.CreateGroupMemberships do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:group_memberships, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:group_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:account_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:role, :string, null: false, default: "user")
      add(:state, :string, null: false, default: "active")

      timestamps()
    end

    create_if_not_exists(unique_index(:group_memberships, [:group_id, :account_id]))
    create_if_not_exists(index(:group_memberships, [:group_id, :role, :state]))
    create_if_not_exists(index(:group_memberships, [:account_id, :state]))

    create(
      constraint(:group_memberships, :group_memberships_role_check,
        check: "role IN ('owner', 'moderator', 'user')"
      )
    )

    create(
      constraint(:group_memberships, :group_memberships_state_check,
        check: "state IN ('active', 'pending', 'banned')"
      )
    )
  end
end

# end of priv/repo/migrations/20260620164000_create_group_memberships.exs
