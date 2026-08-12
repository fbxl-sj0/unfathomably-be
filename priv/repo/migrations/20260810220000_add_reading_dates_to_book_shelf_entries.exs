# Unfathomably native book library
# ---------------------------------
#
# File: 20260810220000_add_reading_dates_to_book_shelf_entries.exs
#
# Purpose:
#
#   Record the start and finish of the current reading lifecycle.
#
# This migration intentionally does NOT create reading activities or alter
# federated shelf collection identifiers.

defmodule Pleroma.Repo.Migrations.AddReadingDatesToBookShelfEntries do
  use Ecto.Migration

  def change do
    alter table(:book_shelf_entries) do
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
    end

    create(
      constraint(:book_shelf_entries, :book_shelf_entries_reading_dates_order,
        check: "finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at"
      )
    )
  end
end

# end of 20260810220000_add_reading_dates_to_book_shelf_entries.exs
