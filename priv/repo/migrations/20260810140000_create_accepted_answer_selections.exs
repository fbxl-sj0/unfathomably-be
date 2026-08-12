# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.CreateAcceptedAnswerSelections do
  use Ecto.Migration

  def change do
    create table(:accepted_answer_selections) do
      add(:root_object_id, references(:objects, on_delete: :delete_all), null: false)
      add(:answer_object_id, references(:objects, on_delete: :delete_all), null: false)
      add(:actor, :text, null: false)
      add(:activity_id, :text, null: false)

      timestamps()
    end

    create(unique_index(:accepted_answer_selections, [:root_object_id]))
    create(index(:accepted_answer_selections, [:answer_object_id]))
    create(index(:accepted_answer_selections, [:activity_id]))
  end
end

# end of 20260810140000_create_accepted_answer_selections.exs
