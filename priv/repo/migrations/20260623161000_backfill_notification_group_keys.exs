# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.BackfillNotificationGroupKeys do
  use Ecto.Migration

  def up do
    Pleroma.MigrationHelper.NotificationBackfill.fill_in_notification_group_keys()
  end

  def down do
  end
end
