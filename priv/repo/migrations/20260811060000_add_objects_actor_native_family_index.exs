# Unfathomably profile Worlds participation
# ------------------------------------------
#
# File: 20260811060000_add_objects_actor_native_family_index.exs
#
# Purpose:
#   Keep per-account Worlds participation summaries on an indexed object path.
#
# Responsibilities:
#   * index the actor and native-family expressions used by profile summaries
#   * restrict the index to discoverable, feed-eligible native objects
#   * build and remove the index without blocking ordinary object writes
#
# This migration intentionally does NOT classify objects differently or index
# private and conventional microblogging objects.

defmodule Pleroma.Repo.Migrations.AddObjectsActorNativeFamilyIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_actor_native_family_index
    ON objects ((data ->> 'actor'), unfathomably_native_family(data))
    WHERE unfathomably_native_discoverable(data)
      AND unfathomably_native_feed_eligible(data)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_actor_native_family_index")
  end
end

# end of 20260811060000_add_objects_actor_native_family_index.exs
