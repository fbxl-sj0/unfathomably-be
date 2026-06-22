# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.ApIdNotNull do
  use Ecto.Migration

  def up do
    alter table(:users) do
      modify(:ap_id, :string, null: false)
    end
  end

  def down do
    :ok
  end
end
