# Unfathomably BE
# ----------------
#
# File: 20260807161000_mark_managed_atproto_links.exs
#
# Purpose:
#   Distinguish local PDS identities from externally authorized accounts.
#
# Responsibilities:
#   - retain whether Unfathomably created and manages an AT Protocol account
#   - prevent two local users from claiming the same human-readable handle
#   - keep external account links on their existing behavior
#
# This file intentionally does NOT store PDS passwords or identity keys.

defmodule Pleroma.Repo.Migrations.MarkManagedAtprotoLinks do
  use Ecto.Migration

  def change do
    alter table(:atproto_links) do
      add(:managed, :boolean, null: false, default: false)
    end

    create(unique_index(:atproto_links, [:handle]))
  end
end

# end of 20260807161000_mark_managed_atproto_links.exs
