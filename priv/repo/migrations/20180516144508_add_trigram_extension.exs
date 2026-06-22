# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddTrigramExtension do
  use Ecto.Migration

  def up do
    execute("create extension if not exists pg_trgm")
  end

  def down do
    execute("drop extension if exists pg_trgm")
  end
end
