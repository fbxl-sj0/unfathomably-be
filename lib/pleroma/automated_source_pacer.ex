# Unfathomably: Automated source ingestion
#
# File: automated_source_pacer.ex
#
# Purpose:
#   Serialize minimum-interval reservations for automated remote sources.
#
# Responsibilities:
#   - prevent one source or host from being polled in rapid succession
#   - bound in-memory reservation state
#   - fail open if the pacing process is unavailable during startup
#
# This file intentionally does NOT fetch remote content or decide which
# remote content is relevant to local users.

defmodule Pleroma.AutomatedSourcePacer do
  @moduledoc """
  Coordinates minimum intervals between automated source operations.

  The GenServer owns all reservation state so concurrent RSS and discovery
  workers cannot race through a read-then-write cache sequence.
  """

  use GenServer

  @max_entries 10_000
  @prune_interval 1_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Reserves `key` for `interval_ms` or returns the remaining wait in milliseconds.
  """
  def reserve(_key, interval_ms) when not is_integer(interval_ms) or interval_ms <= 0,
    do: :ok

  def reserve(key, interval_ms) do
    GenServer.call(__MODULE__, {:reserve, key, interval_ms})
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(_state) do
    {:ok, %{entries: %{}, reservations: 0}}
  end

  @impl GenServer
  def handle_call({:reserve, key, interval_ms}, _from, state) do
    now = System.monotonic_time(:millisecond)
    reservations = state.reservations + 1
    entries = maybe_prune(state.entries, now, reservations)

    case Map.get(entries, key) do
      next_at when is_integer(next_at) and next_at > now ->
        {:reply, {:wait, next_at - now}, %{state | entries: entries, reservations: reservations}}

      _expired_or_missing ->
        entries = entries |> make_room(key) |> Map.put(key, now + interval_ms)
        {:reply, :ok, %{state | entries: entries, reservations: reservations}}
    end
  end

  defp maybe_prune(entries, now, reservations) do
    if map_size(entries) >= @max_entries or rem(reservations, @prune_interval) == 0 do
      Map.reject(entries, fn {_key, next_at} -> next_at <= now end)
    else
      entries
    end
  end

  defp make_room(entries, key) do
    if map_size(entries) < @max_entries or Map.has_key?(entries, key) do
      entries
    else
      {oldest_key, _next_at} = Enum.min_by(entries, fn {_entry_key, next_at} -> next_at end)
      Map.delete(entries, oldest_key)
    end
  end
end

# end of automated_source_pacer.ex
