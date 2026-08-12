# Unfathomably remote identity proofs
# ------------------------------------
#
# File: 20260810170000_add_identity_proofs_to_users.exs
#
# Purpose:
#   Store the bounded set of verified FEP-c390 statements advertised by an
#   ActivityPub actor.
#
# This migration intentionally does not create identity ownership, account
# merge, migration, or uniqueness semantics from those signed claims.

defmodule Pleroma.Repo.Migrations.AddIdentityProofsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add_if_not_exists(:identity_proofs, {:array, :map}, default: [], null: false)
    end
  end
end

# end of priv/repo/migrations/20260810170000_add_identity_proofs_to_users.exs
