# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.CreateQuoteAuthorizations do
  use Ecto.Migration

  def change do
    create table(:quote_authorizations) do
      add(:quote_object_id, references(:objects, on_delete: :delete_all), null: false)
      add(:quoted_object_id, references(:objects, on_delete: :delete_all), null: false)
      add(:quote_actor, :text, null: false)
      add(:quoted_actor, :text, null: false)
      add(:request_ap_id, :text)
      add(:authorization_ap_id, :text)
      add(:state, :text, null: false)
      add(:policy, :text, null: false)
      add(:local, :boolean, null: false, default: false)

      timestamps()
    end

    create(unique_index(:quote_authorizations, [:quote_object_id]))
    create(index(:quote_authorizations, [:quoted_object_id, :state]))
    create(unique_index(:quote_authorizations, [:request_ap_id], where: "request_ap_id IS NOT NULL"))
  end
end

# end of 20260715123000_create_quote_authorizations.exs
