# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.CreatePostArchiveImports do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:post_archive_imports) do
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:approved_by_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:file_name, :string, null: false)
      add(:content_type, :string, null: false)
      add(:file_size, :bigint, null: false, default: 0)
      add(:state, :integer, null: false, default: 8)
      add(:processed_number, :integer, null: false, default: 0)
      add(:total_items, :integer, null: false, default: 0)
      add(:imported_count, :integer, null: false, default: 0)
      add(:original_actor, :text)
      add(:error, :text)
      add(:approved_at, :naive_datetime_usec)

      timestamps()
    end

    create_if_not_exists(index(:post_archive_imports, [:user_id]))
    create_if_not_exists(index(:post_archive_imports, [:state]))
  end
end
