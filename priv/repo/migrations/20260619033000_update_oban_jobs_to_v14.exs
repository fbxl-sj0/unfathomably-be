# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.UpdateObanJobsToV14 do
  use Ecto.Migration

  def up, do: Oban.Migrations.up(version: 14)

  def down, do: Oban.Migrations.down(version: 11)
end
