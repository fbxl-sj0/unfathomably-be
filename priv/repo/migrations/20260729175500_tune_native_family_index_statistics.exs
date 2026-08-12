# Unfathomably native discovery planner statistics
# --------------------------------------------------
#
# File: 20260729175500_tune_native_family_index_statistics.exs
#
# Purpose:
#   Keep Worlds family feeds on their family-and-recency expression index.
#
# Responsibilities:
#   - retain enough expression statistics for uncommon native families
#   - refresh partial-index cardinality after classifier and index rebuilds
#   - prevent empty family feeds from filtering every recent native object
#
# This file intentionally does not change native object classification,
# discovery eligibility, or any stored ActivityPub data.

defmodule Pleroma.Repo.Migrations.TuneNativeFamilyIndexStatistics do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    ALTER INDEX objects_native_family_recent_index
    ALTER COLUMN 1 SET STATISTICS 1000
    """)

    execute("ANALYZE objects")
  end

  def down do
    execute("""
    ALTER INDEX objects_native_family_recent_index
    ALTER COLUMN 1 SET STATISTICS -1
    """)

    execute("ANALYZE objects")
  end
end

# end of 20260729175500_tune_native_family_index_statistics.exs
