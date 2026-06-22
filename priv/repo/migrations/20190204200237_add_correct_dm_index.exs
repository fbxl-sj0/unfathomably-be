# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddCorrectDMIndex do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    drop_if_exists(
      index(:activities, ["activity_visibility(actor, recipients, data)"],
        name: :activities_visibility_index
      )
    )

    create(
      index(:activities, ["activity_visibility(actor, recipients, data)", "id DESC NULLS LAST"],
        name: :activities_visibility_index,
        concurrently: true,
        where: "data->>'type' = 'Create'"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:activities, ["activity_visibility(actor, recipients, data)", "id DESC"],
        name: :activities_visibility_index,
        concurrently: true,
        where: "data->>'type' = 'Create'"
      )
    )
  end
end
