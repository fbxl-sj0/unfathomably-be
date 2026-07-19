# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddActorTypesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add_if_not_exists(:actor_types, {:array, :text}, default: [], null: false)
    end
  end
end

# end of priv/repo/migrations/20260717163000_add_actor_types_to_users.exs
