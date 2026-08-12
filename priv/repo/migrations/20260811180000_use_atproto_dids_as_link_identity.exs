# Unfathomably AT Protocol link identity
# --------------------------------------
#
# File: 20260811180000_use_atproto_dids_as_link_identity.exs
#
# Purpose:
#   Keep durable AT Protocol account links keyed by DID rather than handle.
#
# Responsibilities:
#   - remove the uniqueness rule from the mutable human-readable handle
#   - retain an ordinary handle index for account-state lookups
#
# This migration intentionally does NOT merge links, change encrypted sessions,
# or weaken the existing unique DID and local-user constraints.

defmodule Pleroma.Repo.Migrations.UseAtprotoDidsAsLinkIdentity do
  use Ecto.Migration

  def up do
    drop_if_exists(unique_index(:atproto_links, [:handle]))
    create(index(:atproto_links, [:handle]))
  end

  def down do
    drop_if_exists(index(:atproto_links, [:handle]))
    create(unique_index(:atproto_links, [:handle]))
  end
end

# end of 20260811180000_use_atproto_dids_as_link_identity.exs
