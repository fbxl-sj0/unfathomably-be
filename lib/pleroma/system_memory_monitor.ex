# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.SystemMemoryMonitor do
  @moduledoc """
  Raises a standard OTP alarm when reclaimable system memory becomes scarce.

  OTP's built-in `system_memory_high_watermark` uses strictly free memory on
  Linux. Filesystem cache is reclaimable, so database hosts can remain healthy
  while that legacy alarm stays set. `available_memory` includes memory the
  kernel can reclaim without swapping application processes.
  """

  use GenServer

  require Logger

  @alarm_name :system_memory_available_low
  @default_check_interval :timer.minutes(1)
  @default_alarm_threshold 0.10
  @default_clear_threshold 0.15

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :check_memory)

    {:ok, %{alarm?: alarm_active?(), read_error?: false}}
  end

  @impl true
  def handle_info(:check_memory, state) do
    state = check_memory(state)
    Process.send_after(self(), :check_memory, check_interval())

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{alarm?: true}) do
    :alarm_handler.clear_alarm(@alarm_name)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @doc false
  def evaluate(memory_data, alarm_active?, alarm_threshold, clear_threshold)
      when is_list(memory_data) and is_boolean(alarm_active?) do
    with {:ok, total, available} <- memory_amounts(memory_data),
         true <- valid_thresholds?(alarm_threshold, clear_threshold) do
      available_ratio = available / total

      details = [
        available_bytes: available,
        total_bytes: total,
        available_ratio: available_ratio,
        alarm_threshold: alarm_threshold,
        clear_threshold: clear_threshold
      ]

      cond do
        not alarm_active? and available_ratio <= alarm_threshold -> {:set, details}
        alarm_active? and available_ratio >= clear_threshold -> {:clear, details}
        true -> {:unchanged, details}
      end
    else
      _ -> {:error, :invalid_memory_data}
    end
  end

  def evaluate(_memory_data, _alarm_active?, _alarm_threshold, _clear_threshold),
    do: {:error, :invalid_memory_data}

  defp check_memory(state) do
    case system_memory_data() do
      {:ok, memory_data} ->
        maybe_log_recovery(state)
        apply_evaluation(memory_data, %{state | read_error?: false})

      {:error, reason} ->
        maybe_log_read_error(reason, state)
        %{state | read_error?: true}
    end
  end

  defp apply_evaluation(memory_data, state) do
    case evaluate(memory_data, state.alarm?, alarm_threshold(), clear_threshold()) do
      {:set, details} ->
        :alarm_handler.set_alarm({@alarm_name, details})

        Logger.warning("Available system memory is low",
          available_bytes: details[:available_bytes],
          total_bytes: details[:total_bytes]
        )

        %{state | alarm?: true}

      {:clear, details} ->
        :alarm_handler.clear_alarm(@alarm_name)

        Logger.info("Available system memory has recovered",
          available_bytes: details[:available_bytes],
          total_bytes: details[:total_bytes]
        )

        %{state | alarm?: false}

      {:unchanged, _details} ->
        state

      {:error, reason} ->
        maybe_log_read_error(reason, state)
        %{state | read_error?: true}
    end
  end

  defp system_memory_data do
    try do
      case :memsup.get_system_memory_data() do
        data when is_list(data) -> {:ok, data}
        data -> {:error, {:unexpected_memory_data, data}}
      end
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp memory_amounts(memory_data) do
    total = memory_value(memory_data, :system_total_memory) || memory_value(memory_data, :total_memory)

    available =
      memory_value(memory_data, :available_memory) ||
        fallback_available_memory(memory_data)

    if is_integer(total) and total > 0 and is_integer(available) and available >= 0 do
      {:ok, total, min(available, total)}
    else
      {:error, :invalid_memory_data}
    end
  end

  defp fallback_available_memory(memory_data) do
    values =
      Enum.map([:free_memory, :buffered_memory, :cached_memory], fn key ->
        memory_value(memory_data, key) || 0
      end)

    if Enum.any?(values, &(&1 > 0)), do: Enum.sum(values)
  end

  defp memory_value(memory_data, key) do
    Enum.find_value(memory_data, fn
      {^key, value} when is_integer(value) and value >= 0 -> value
      _ -> nil
    end)
  end

  defp valid_thresholds?(alarm_threshold, clear_threshold) do
    is_number(alarm_threshold) and is_number(clear_threshold) and
      alarm_threshold >= 0 and alarm_threshold < clear_threshold and clear_threshold <= 1
  end

  defp alarm_active? do
    @alarm_name in Enum.map(:alarm_handler.get_alarms(), &elem(&1, 0))
  end

  defp maybe_log_read_error(_reason, %{read_error?: true}), do: :ok

  defp maybe_log_read_error(reason, _state) do
    Logger.warning("Unable to inspect available system memory", reason: inspect(reason))
  end

  defp maybe_log_recovery(%{read_error?: true}) do
    Logger.info("Available system memory inspection has recovered")
  end

  defp maybe_log_recovery(_state), do: :ok

  defp check_interval do
    configured_integer(:check_interval, @default_check_interval, 1_000)
  end

  defp alarm_threshold do
    configured_threshold(:alarm_threshold, @default_alarm_threshold)
  end

  defp clear_threshold do
    configured_threshold(:clear_threshold, @default_clear_threshold)
  end

  defp configured_integer(key, default, minimum) do
    case Pleroma.Config.get([__MODULE__, key], default) do
      value when is_integer(value) and value >= minimum -> value
      _ -> default
    end
  end

  defp configured_threshold(key, default) do
    case Pleroma.Config.get([__MODULE__, key], default) do
      value when is_number(value) and value >= 0 and value <= 1 -> value
      _ -> default
    end
  end
end

# end of system_memory_monitor.ex
