# Unfathomably BE
# ----------------
#
# File: nostr/relay_connection.ex
#
# Purpose:
#   Maintain a bounded client WebSocket to one approved external Nostr relay.
#
# Responsibilities:
#   - subscribe only to mapped profiles and NIP-29 groups
#   - enqueue verified-size relay events for normal bridge ingestion
#   - publish bridge-signed events to the selected relay
#   - reconnect after transport loss without affecting ActivityPub
#
# This file intentionally does NOT decide which relays are approved, translate
# events, or expose a local relay endpoint.

defmodule Pleroma.Nostr.RelayConnection do
  use WebSockex

  require Logger

  alias Pleroma.Config
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.RelayHub
  alias Pleroma.Workers.NostrIngestWorker

  def child_spec(relay_url) do
    %{
      id: {__MODULE__, relay_url},
      start: {__MODULE__, :start_link, [relay_url]},
      restart: :permanent
    }
  end

  def start_link(relay_url) do
    WebSockex.start_link(
      relay_url,
      __MODULE__,
      %{relay_url: relay_url, subscription_count: 0, requests: %{}},
      name: via(relay_url),
      async: true
    )
  end

  def publish(relay_url, event), do: WebSockex.cast(via(relay_url), {:publish, event})
  def refresh(relay_url), do: WebSockex.cast(via(relay_url), :refresh)

  def request(relay_url, subscription_id, filters, recipient, timeout_ms)
      when is_binary(subscription_id) and is_list(filters) and is_pid(recipient) and
             is_integer(timeout_ms) do
    filters = Enum.filter(filters, &is_map/1)

    if filters == [] do
      {:error, :empty_filters}
    else
      WebSockex.cast(
        via(relay_url),
        {:request, subscription_id, filters, recipient, timeout_ms}
      )
    end
  rescue
    _ -> {:error, :not_connected}
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  def request(_relay_url, _subscription_id, _filters, _recipient, _timeout_ms),
    do: {:error, :bad_request}

  @impl true
  def handle_connect(_connection_status, state) do
    Logger.info("Nostr relay connected to #{state.relay_url}", relay: state.relay_url)
    send(self(), :subscribe)

    {:ok, %{state | subscription_count: 0, requests: %{}}}
  end

  @impl true
  def handle_frame({:text, payload}, state) when is_binary(payload) do
    if byte_size(payload) <= max_event_bytes() do
      case Jason.decode(payload) do
        {:ok, ["EVENT", subscription_id, event]}
        when is_binary(subscription_id) and is_map(event) ->
          case Map.get(state.requests, subscription_id) do
            %{recipient: recipient} ->
              send(
                recipient,
                {:nostr_relay_event, state.relay_url, subscription_id, event}
              )

            nil ->
              NostrIngestWorker.enqueue_event(event, state.relay_url)
          end

        {:ok, ["EOSE", subscription_id]} when is_binary(subscription_id) ->
          case Map.get(state.requests, subscription_id) do
            %{recipient: recipient} ->
              send(
                recipient,
                {:nostr_relay_eose, state.relay_url, subscription_id, :complete}
              )

              send(self(), {:close_request, subscription_id, :complete})

            nil ->
              :ok
          end

        {:ok, ["CLOSED", subscription_id, reason]}
        when is_binary(subscription_id) and is_binary(reason) ->
          case Map.get(state.requests, subscription_id) do
            %{recipient: recipient} ->
              send(
                recipient,
                {:nostr_relay_eose, state.relay_url, subscription_id, {:closed, reason}}
              )

              send(self(), {:drop_request, subscription_id})

            nil ->
              Logger.debug("Nostr relay subscription closed",
                relay: state.relay_url,
                subscription: subscription_id,
                reason: reason
              )
          end

        {:ok, ["OK", event_id, true, message]}
        when is_binary(event_id) and is_binary(message) ->
          Logger.debug("Nostr relay accepted event",
            relay: state.relay_url,
            event_id: event_id,
            reason: message
          )

        {:ok, ["OK", event_id, false, message]}
        when is_binary(event_id) and is_binary(message) ->
          Logger.warning("Nostr relay rejected event",
            relay: state.relay_url,
            event_id: event_id,
            reason: message
          )

        {:ok, ["AUTH", challenge]} when is_binary(challenge) ->
          Logger.debug("Nostr relay offered optional client authentication",
            relay: state.relay_url
          )

        {:ok, ["NOTICE", message]} when is_binary(message) ->
          Logger.debug("Nostr relay notice", relay: state.relay_url, reason: message)

        _other ->
          :ok
      end
    end

    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:publish, event}, state) do
    {:reply, {:text, Jason.encode!(["EVENT", event])}, state}
  end

  def handle_cast({:request, subscription_id, filters, recipient, timeout_ms}, state) do
    state = drop_request(state, subscription_id)
    timeout_ms = timeout_ms |> max(250) |> min(10_000)
    timer = Process.send_after(self(), {:close_request, subscription_id, :timeout}, timeout_ms)

    request = %{recipient: recipient, timer: timer}
    requests = Map.put(state.requests, subscription_id, request)
    frame = Jason.encode!(["REQ", subscription_id] ++ filters)

    {:reply, {:text, frame}, %{state | requests: requests}}
  end

  def handle_cast(:refresh, state) do
    {:ok, schedule_subscriptions(state)}
  end

  @impl true
  def handle_info(:subscribe, state) do
    {:ok, schedule_subscriptions(state)}
  end

  def handle_info({:close_subscription, subscription_id}, state) do
    {:reply, {:text, Jason.encode!(["CLOSE", subscription_id])}, state}
  end

  def handle_info({:subscribe_filter, subscription_id, filter}, state) do
    {:reply, {:text, Jason.encode!(["REQ", subscription_id, filter])}, state}
  end

  def handle_info({:close_request, subscription_id, reason}, state) do
    case Map.pop(state.requests, subscription_id) do
      {nil, _requests} ->
        {:ok, state}

      {%{recipient: recipient, timer: timer}, requests} ->
        Process.cancel_timer(timer)

        if reason == :timeout do
          send(
            recipient,
            {:nostr_relay_eose, state.relay_url, subscription_id, :timeout}
          )
        end

        {:reply, {:text, Jason.encode!(["CLOSE", subscription_id])},
         %{state | requests: requests}}
    end
  end

  def handle_info({:drop_request, subscription_id}, state) do
    {:ok, drop_request(state, subscription_id)}
  end

  @impl true
  def handle_disconnect(status, state) do
    Enum.each(state.requests, fn {subscription_id, %{recipient: recipient, timer: timer}} ->
      Process.cancel_timer(timer)

      send(
        recipient,
        {:nostr_relay_eose, state.relay_url, subscription_id, :disconnected}
      )
    end)

    Logger.debug("Nostr relay disconnected from #{state.relay_url}: #{inspect(status)}",
      relay: state.relay_url,
      reason: inspect(status)
    )

    {:reconnect, %{state | requests: %{}}}
  end

  defp schedule_subscriptions(state) do
    if state.subscription_count > 0 do
      Enum.each(0..(state.subscription_count - 1), fn index ->
        send(self(), {:close_subscription, subscription_id(index)})
      end)
    end

    filters = Bridge.filters_for_relay(state.relay_url)

    filters
    |> Enum.with_index()
    |> Enum.each(fn {filter, index} ->
      send(self(), {:subscribe_filter, subscription_id(index), filter})
    end)

    %{state | subscription_count: length(filters)}
  end

  defp subscription_id(index), do: "unfathomably-#{index}"

  defp drop_request(state, subscription_id) do
    case Map.pop(state.requests, subscription_id) do
      {nil, _requests} ->
        state

      {%{timer: timer}, requests} ->
        Process.cancel_timer(timer)
        %{state | requests: requests}
    end
  end

  defp via(relay_url), do: RelayHub.process_via({:relay, relay_url})

  defp max_event_bytes do
    case Config.get([Pleroma.Nostr, :max_event_bytes], 65_536) do
      value when is_integer(value) and value > 0 -> value
      _ -> 65_536
    end
  end
end

# end of nostr/relay_connection.ex
