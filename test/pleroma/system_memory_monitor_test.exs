# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.SystemMemoryMonitorTest do
  use ExUnit.Case, async: true

  alias Pleroma.SystemMemoryMonitor

  describe "evaluate/4" do
    test "sets an alarm when available memory reaches the low threshold" do
      memory = [system_total_memory: 1_000, available_memory: 100]

      assert {:set, details} = SystemMemoryMonitor.evaluate(memory, false, 0.10, 0.15)
      assert details[:available_bytes] == 100
    end

    test "uses hysteresis before clearing an active alarm" do
      assert {:unchanged, _details} =
               SystemMemoryMonitor.evaluate(memory_at(0.12), true, 0.10, 0.15)

      assert {:clear, _details} =
               SystemMemoryMonitor.evaluate(memory_at(0.15), true, 0.10, 0.15)
    end

    test "falls back to free and reclaimable cache fields" do
      memory = [
        total_memory: 1_000,
        free_memory: 20,
        buffered_memory: 10,
        cached_memory: 570
      ]

      assert {:unchanged, details} =
               SystemMemoryMonitor.evaluate(memory, false, 0.10, 0.15)

      assert details[:available_bytes] == 600
    end

    test "rejects malformed memory measurements and thresholds" do
      assert {:error, :invalid_memory_data} =
               SystemMemoryMonitor.evaluate([], false, 0.10, 0.15)

      assert {:error, :invalid_memory_data} =
               SystemMemoryMonitor.evaluate(memory_at(0.50), false, 0.20, 0.10)
    end
  end

  defp memory_at(available_ratio) do
    [system_total_memory: 1_000, available_memory: round(1_000 * available_ratio)]
  end
end

# end of system_memory_monitor_test.exs
