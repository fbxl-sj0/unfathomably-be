# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.CreateFeatureAuthorizations do
  use Ecto.Migration

  def change do
    create table(:feature_authorizations) do
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:requester_actor, :text, null: false)
      add(:collection_uri, :text, null: false)
      add(:request_ap_id, :text, null: false)

      timestamps(updated_at: false)
    end

    create(unique_index(:feature_authorizations, [:user_id, :collection_uri]))
    create(unique_index(:feature_authorizations, [:request_ap_id]))
  end
end

# end of 20260812120000_create_feature_authorizations.exs
