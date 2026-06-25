# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddThreadiverseGroupMetadataToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add_if_not_exists(:outbox_address, :text)
      add_if_not_exists(:attributed_to_address, :text)
      add_if_not_exists(:is_indexable, :boolean)
      add_if_not_exists(:posting_restricted_to_mods, :boolean, default: false, null: false)
    end

    create_if_not_exists(index(:users, [:outbox_address]))
    create_if_not_exists(index(:users, [:attributed_to_address]))
  end
end
