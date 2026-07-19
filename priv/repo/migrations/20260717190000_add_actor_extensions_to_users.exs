# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddActorExtensionsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add_if_not_exists(:actor_extensions, :map, default: %{}, null: false)
    end
  end
end

# end of priv/repo/migrations/20260717190000_add_actor_extensions_to_users.exs
