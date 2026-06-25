# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddGroupModeratorCountToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add_if_not_exists(:moderator_count, :integer, default: 0, null: false)
    end
  end
end
