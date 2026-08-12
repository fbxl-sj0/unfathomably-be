# Unfathomably BE
# ----------------
#
# File: nostr/relay_manager.ex
#
# Purpose:
#   Keep outbound relay subscriptions aligned with followed bridge identities.
#
# Responsibilities:
#   - discover administrator-approved relay URLs from configuration and mappings
#   - start one bounded WebSocket connection per approved relay
#   - refresh subscriptions after identity or follow changes
#   - route signed events to their destination relay processes
#
# This file intentionally does NOT parse events, authorize relay clients, or
# implement reconnect transport details.

defmodule Pleroma.Nostr.RelayManager do
  use GenServer

  alias Pleroma.Config
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection

  @supervisor Pleroma.Nostr.RelayConnectionSupervisor

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def sync_now do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :sync)
    :ok
  end

  def publish(event, relays) when is_list(relays) do
    relays
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&Nostr.allowed_relay?/1)
    |> Enum.reject(&(&1 == Nostr.relay_url()))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn relay_url, :ok ->
      case Pleroma.Workers.NostrRelayPublishWorker.enqueue_delivery(event, relay_url) do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def publish(_event, _relays), do: :ok

  @impl true
  def init(_opts) do
    send(self(), :sync)
    {:ok, %{refresh_timer: nil}}
  end

  @impl true
  def handle_cast(:sync, %{refresh_timer: nil} = state) do
    timer = Process.send_after(self(), :refresh_subscriptions, refresh_debounce())
    {:noreply, %{state | refresh_timer: timer}}
  end

  def handle_cast(:sync, state), do: {:noreply, state}

  @impl true
  def handle_info(:sync, state) do
    sync_relays(false)
    Process.send_after(self(), :sync, refresh_interval())
    {:noreply, state}
  end

  def handle_info(:refresh_subscriptions, state) do
    sync_relays(true)
    {:noreply, %{state | refresh_timer: nil}}
  end

  def ensure_connection(relay_url) do
    if Nostr.allowed_relay?(relay_url) and relay_url != Nostr.relay_url() do
      case Registry.lookup(Pleroma.Nostr.ProcessRegistry, {:relay, relay_url}) do
        [{_pid, _value}] ->
          :ok

        [] ->
          DynamicSupervisor.start_child(@supervisor, {RelayConnection, relay_url})
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp sync_relays(refresh_subscriptions?) do
    relays =
      Identity.all_relay_urls()
      |> Kernel.++(Nostr.configured_relays())
      |> Enum.map(&Protocol.normalize_relay_url/1)
      |> Enum.filter(&Nostr.allowed_relay?/1)
      |> Enum.uniq()

    Enum.each(relays, fn relay_url ->
      ensure_connection(relay_url)

      if refresh_subscriptions? do
        refresh_if_connected(relay_url)
      end
    end)
  rescue
    _ -> :ok
  end

  defp refresh_if_connected(relay_url) do
    case Registry.lookup(Pleroma.Nostr.ProcessRegistry, {:relay, relay_url}) do
      [{_pid, _value}] -> RelayConnection.refresh(relay_url)
      [] -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp refresh_interval do
    case Config.get([Nostr, :relay_refresh_interval_ms], 60_000) do
      value when is_integer(value) and value >= 5_000 -> value
      _ -> 60_000
    end
  end

  defp refresh_debounce do
    case Config.get([Nostr, :relay_refresh_debounce_ms], 1_000) do
      value when is_integer(value) and value >= 250 and value <= 10_000 -> value
      _ -> 1_000
    end
  end
end

# end of nostr/relay_manager.ex
