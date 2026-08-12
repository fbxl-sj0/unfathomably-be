# Unfathomably native book library
# ---------------------------------
#
# File: 20260722170000_create_book_shelf_entries.exs
#
# Purpose:
#
#   Store each local user's current reading shelf and optional progress for a
#   canonical federated book or edition.
#
# Responsibilities:
#
#   * enforce one current shelf per user and book URI
#   * retain a small presentation snapshot for useful library rendering
#   * index shelf views without scanning unrelated native objects
#
# This file intentionally does NOT contain federation or API behavior.

defmodule Pleroma.Repo.Migrations.CreateBookShelfEntries do
  use Ecto.Migration

  def change do
    create table(:book_shelf_entries) do
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:book_uri, :text, null: false)
      add(:shelf, :string, null: false)
      add(:progress, :integer)
      add(:progress_mode, :string)
      add(:presentation, :map, null: false, default: %{})

      timestamps()
    end

    create(unique_index(:book_shelf_entries, [:user_id, :book_uri]))
    create(index(:book_shelf_entries, [:user_id, :shelf, :updated_at]))

    create(
      constraint(:book_shelf_entries, :book_shelf_entries_shelf_check,
        check: "shelf IN ('to-read', 'reading', 'read', 'stopped-reading')"
      )
    )

    create(
      constraint(:book_shelf_entries, :book_shelf_entries_progress_mode_check,
        check: "progress_mode IS NULL OR progress_mode IN ('page', 'percent')"
      )
    )

    create(
      constraint(:book_shelf_entries, :book_shelf_entries_progress_check,
        check:
          "progress IS NULL OR (progress >= 0 AND (progress_mode <> 'percent' OR progress <= 100))"
      )
    )
  end
end

# end of 20260722170000_create_book_shelf_entries.exs
