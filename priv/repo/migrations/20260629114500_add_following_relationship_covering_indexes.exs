# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddFollowingRelationshipCoveringIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:following_relationships, [:following_id, :state, :follower_id],
        name: :following_relationships_following_state_follower_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:following_relationships, [:follower_id, :state, :following_id],
        name: :following_relationships_follower_state_following_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:following_relationships, [:follower_id, :state, :following_id],
        name: :following_relationships_follower_state_following_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:following_relationships, [:following_id, :state, :follower_id],
        name: :following_relationships_following_state_follower_index,
        concurrently: true
      )
    )
  end
end

# end of 20260629114500_add_following_relationship_covering_indexes.exs
