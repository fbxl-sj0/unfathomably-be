# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.TuneHotTableAutovacuum do
  use Ecto.Migration

  @tables [
    {"activities", 1_000, 0.02, 1_000, 0.01},
    {"following_relationships", 500, 0.05, 500, 0.02},
    {"counter_cache", 250, 0.05, 250, 0.02},
    {"instances", 250, 0.05, 250, 0.02},
    {"nostr_entities", 25, 0.05, 25, 0.02},
    {"notifications", 10, 0.10, 10, 0.05},
    {"markers", 5, 0.10, 5, 0.05}
  ]

  def up do
    Enum.each(@tables, fn {table, vacuum_threshold, vacuum_scale, analyze_threshold,
                           analyze_scale} ->
      execute("""
      ALTER TABLE #{table} SET (
        autovacuum_vacuum_threshold = #{vacuum_threshold},
        autovacuum_vacuum_scale_factor = #{vacuum_scale},
        autovacuum_analyze_threshold = #{analyze_threshold},
        autovacuum_analyze_scale_factor = #{analyze_scale}
      )
      """)
    end)
  end

  def down do
    execute("""
    ALTER TABLE activities SET (
      autovacuum_vacuum_threshold = 50000,
      autovacuum_vacuum_scale_factor = 0.02,
      autovacuum_analyze_threshold = 50000,
      autovacuum_analyze_scale_factor = 0.01
    )
    """)

    Enum.each(@tables -- [{"activities", 1_000, 0.02, 1_000, 0.01}], fn {table, _, _, _, _} ->
      execute("""
      ALTER TABLE #{table} RESET (
        autovacuum_vacuum_threshold,
        autovacuum_vacuum_scale_factor,
        autovacuum_analyze_threshold,
        autovacuum_analyze_scale_factor
      )
      """)
    end)
  end
end

# end of 20260802130000_tune_hot_table_autovacuum.exs
