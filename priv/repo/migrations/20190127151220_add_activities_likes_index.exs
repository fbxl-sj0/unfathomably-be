# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddActivitiesLikesIndex do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(
      index(:activities, ["((data #> '{\"object\",\"likes\"}'))"],
        concurrently: true,
        name: :activities_likes,
        using: :gin
      )
    )
  end
end
