# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.TuneRetentionTableAutovacuum do
  use Ecto.Migration

  def up do
    # PostgreSQL's default 20 percent threshold would allow more than thirteen
    # million dead activity rows before vacuuming this installation. Retention
    # cleanup needs predictable thresholds so reclaimed pages become reusable
    # throughout a long bounded sweep rather than only after it finishes.
    execute("""
    ALTER TABLE activities SET (
      autovacuum_vacuum_scale_factor = 0.002,
      autovacuum_vacuum_threshold = 100000,
      autovacuum_analyze_scale_factor = 0.001,
      autovacuum_analyze_threshold = 50000,
      autovacuum_vacuum_cost_limit = 1000,
      autovacuum_vacuum_cost_delay = 2,
      toast.autovacuum_vacuum_scale_factor = 0.01,
      toast.autovacuum_vacuum_threshold = 5000
    )
    """)

    execute("""
    ALTER TABLE objects SET (
      autovacuum_vacuum_scale_factor = 0.01,
      autovacuum_vacuum_threshold = 50000,
      autovacuum_analyze_scale_factor = 0.005,
      autovacuum_analyze_threshold = 25000,
      autovacuum_vacuum_cost_limit = 1000,
      autovacuum_vacuum_cost_delay = 2,
      toast.autovacuum_vacuum_scale_factor = 0.01,
      toast.autovacuum_vacuum_threshold = 5000
    )
    """)
  end

  def down do
    execute("""
    ALTER TABLE activities RESET (
      autovacuum_vacuum_scale_factor,
      autovacuum_vacuum_threshold,
      autovacuum_analyze_scale_factor,
      autovacuum_analyze_threshold,
      autovacuum_vacuum_cost_limit,
      autovacuum_vacuum_cost_delay,
      toast.autovacuum_vacuum_scale_factor,
      toast.autovacuum_vacuum_threshold
    )
    """)

    execute("""
    ALTER TABLE objects RESET (
      autovacuum_vacuum_scale_factor,
      autovacuum_vacuum_threshold,
      autovacuum_analyze_scale_factor,
      autovacuum_analyze_threshold,
      autovacuum_vacuum_cost_limit,
      autovacuum_vacuum_cost_delay,
      toast.autovacuum_vacuum_scale_factor,
      toast.autovacuum_vacuum_threshold
    )
    """)
  end
end

# end of 20260820210000_tune_retention_table_autovacuum.exs
