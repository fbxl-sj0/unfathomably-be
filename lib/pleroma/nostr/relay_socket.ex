# Unfathomably BE
# ----------------
#
# File: nostr/relay_socket.ex
#
# Purpose:
#   Implement bounded NIP-01 relay framing for local Nostr clients.
#
# Responsibilities:
#   - manage per-connection subscriptions and CLOSE requests
#   - accept signed events through the bridge authorization boundary
#   - answer REQ and COUNT from the verified event store
#   - push newly accepted events to matching subscriptions
#
# This file intentionally does NOT perform cryptography directly, open
# outbound relay connections, or retain global subscription state.

defmodule Pleroma.Nostr.RelaySocket do
  @behaviour WebSock

  alias Pleroma.Config
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayHub
  alias Pleroma.Nostr.RelayPublisher
  alias Pleroma.Nostr.Store

  @impl true
  def init(_state) do
    RelayHub.register_socket()

    {:ok,
     %{
       subscriptions: %{},
       event_count: 0,
       event_window_started_at: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_in({payload, opcode: :text}, state) when is_binary(payload) do
    if byte_size(payload) <= max_event_bytes() do
      handle_message(Jason.decode(payload), state)
    else
      push_notice("error: message is too large", state)
    end
  end

  def handle_in({_payload, opcode: :binary}, state),
    do: push_notice("error: binary frames are not supported", state)

  @impl true
  def handle_info({:nostr_event, event}, state) do
    messages =
      state.subscriptions
      |> Enum.filter(fn {_id, filters} -> Enum.any?(filters, &Protocol.matches?(event, &1)) end)
      |> Enum.map(fn {id, _filters} -> {:text, Jason.encode!(["EVENT", id, event])} end)

    if messages == [], do: {:ok, state}, else: {:push, messages, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp handle_message({:ok, ["EVENT", event]}, state) when is_map(event) do
    event_id = event["id"] || ""

    case take_event_slot(state) do
      {:ok, state} ->
        case Bridge.ingest_event(event, Nostr.relay_url(), :client) do
          {:ok, _event} ->
            RelayPublisher.publish(event)
            push(["OK", event_id, true, ""], state)

          {:error, prefix, reason} ->
            push(["OK", event_id, false, "#{prefix}: #{reason}"], state)
        end

      {:error, state} ->
        push(["OK", event_id, false, "rate-limited: too many events"], state)
    end
  end

  defp handle_message({:ok, ["REQ", subscription_id | filters]}, state)
       when is_binary(subscription_id) and byte_size(subscription_id) in 1..64 do
    cond do
      map_size(state.subscriptions) >= max_subscriptions() and
          not Map.has_key?(state.subscriptions, subscription_id) ->
        push(["CLOSED", subscription_id, "restricted: too many subscriptions"], state)

      true ->
        case Protocol.validate_filters(filters) do
          {:ok, filters} ->
            events = Store.query(filters)

            messages =
              Enum.map(events, fn event ->
                {:text, Jason.encode!(["EVENT", subscription_id, event.data])}
              end) ++ [{:text, Jason.encode!(["EOSE", subscription_id])}]

            {:push, messages,
             %{state | subscriptions: Map.put(state.subscriptions, subscription_id, filters)}}

          _ ->
            push(["CLOSED", subscription_id, "error: invalid filter"], state)
        end
    end
  end

  defp handle_message({:ok, ["COUNT", subscription_id | filters]}, state)
       when is_binary(subscription_id) do
    case Protocol.validate_filters(filters) do
      {:ok, filters} ->
        push(["COUNT", subscription_id, %{"count" => length(Store.query(filters))}], state)

      _ ->
        push(["CLOSED", subscription_id, "error: invalid filter"], state)
    end
  end

  defp handle_message({:ok, ["CLOSE", subscription_id]}, state)
       when is_binary(subscription_id) do
    {:ok, %{state | subscriptions: Map.delete(state.subscriptions, subscription_id)}}
  end

  defp handle_message(_message, state), do: push_notice("error: invalid message", state)

  defp push_notice(message, state), do: push(["NOTICE", message], state)
  defp push(message, state), do: {:push, {:text, Jason.encode!(message)}, state}

  defp take_event_slot(state) do
    now = System.monotonic_time(:millisecond)

    state =
      if now - state.event_window_started_at >= 60_000 do
        %{state | event_count: 0, event_window_started_at: now}
      else
        state
      end

    if state.event_count < max_events_per_minute() do
      {:ok, %{state | event_count: state.event_count + 1}}
    else
      {:error, state}
    end
  end

  defp max_events_per_minute do
    case Config.get([Nostr, :max_events_per_minute], 120) do
      value when is_integer(value) and value in 1..10_000 -> value
      _ -> 120
    end
  end

  defp max_subscriptions do
    case Config.get([Nostr, :max_subscriptions], 20) do
      value when is_integer(value) and value > 0 -> value
      _ -> 20
    end
  end

  defp max_event_bytes do
    case Config.get([Nostr, :max_event_bytes], 65_536) do
      value when is_integer(value) and value > 0 -> value
      _ -> 65_536
    end
  end
end

# end of nostr/relay_socket.ex
