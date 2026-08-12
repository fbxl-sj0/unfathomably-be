# Unfathomably Backend
#
# File: 20260810130000_create_aggregate_feed_memberships.exs
#
# Purpose:
#   Add normalized storage for communities selected by aggregate Feed actors.
#
# This migration intentionally does not alter following relationships.

defmodule Pleroma.Repo.Migrations.CreateAggregateFeedMemberships do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:aggregate_feed_memberships, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:feed_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)

      add(:community_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)

      timestamps()
    end

    create_if_not_exists(unique_index(:aggregate_feed_memberships, [:feed_id, :community_id]))

    create_if_not_exists(index(:aggregate_feed_memberships, [:community_id]))
  end
end

# end of priv/repo/migrations/20260810130000_create_aggregate_feed_memberships.exs
