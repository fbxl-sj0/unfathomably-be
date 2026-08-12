# Unfathomably BE
# ----------------
#
# File: nostr/relay_hub.ex
#
# Purpose:
#   Fan verified events to connected local relay subscribers.
#
# Responsibilities:
#   - provide unique and duplicate Registry child specifications
#   - dispatch event notifications without retaining protocol state
#
# This file intentionally does NOT match filters, persist events, or manage
# external relay connections.

defmodule Pleroma.Nostr.RelayHub do
  @socket_registry Pleroma.Nostr.SocketRegistry
  @process_registry Pleroma.Nostr.ProcessRegistry

  def child_specs do
    [
      {Registry, keys: :duplicate, name: @socket_registry},
      {Registry, keys: :unique, name: @process_registry}
    ]
  end

  def register_socket do
    Registry.register(@socket_registry, :relay_socket, nil)
  end

  def broadcast(event) do
    if Process.whereis(@socket_registry) do
      Registry.dispatch(@socket_registry, :relay_socket, fn entries ->
        Enum.each(entries, fn {pid, _value} -> send(pid, {:nostr_event, event}) end)
      end)
    end

    :ok
  end

  def process_via(key), do: {:via, Registry, {@process_registry, key}}
end

# end of nostr/relay_hub.ex
