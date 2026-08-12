# Unfathomably BE
# ----------------
#
# File: nostr/relay_delivery.ex
#
# Purpose:
#   Deliver one signed Nostr event and wait for the relay's NIP-20 result.
#
# Responsibilities:
#   - validate the relay and signed event before opening a socket
#   - send exactly one EVENT frame
#   - return the matching OK acceptance or rejection to the caller
#   - bound connection and acknowledgement waiting time
#
# This file intentionally does NOT choose relays, retry delivery, or persist
# events. Those responsibilities belong to the publisher and Oban worker.

defmodule Pleroma.Nostr.RelayDelivery do
  use WebSockex

  alias Pleroma.Config
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Protocol

  def publish(relay_url, event) do
    relay_url = Protocol.normalize_relay_url(relay_url)

    with true <- is_binary(relay_url) and Nostr.allowed_relay?(relay_url),
         true <- relay_url != Nostr.relay_url(),
         {:ok, event} <- Protocol.validate_event(event),
         {:ok, session} <- start_session(relay_url, event) do
      await_result(session, timeout_ms())
    else
      false -> {:error, :relay_not_allowed}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_delivery}
    end
  rescue
    error -> {:error, {:delivery_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def handle_connect(_connection, state) do
    send(self(), :publish_event)
    {:ok, state}
  end

  def handle_info(:publish_event, state) do
    frame = Jason.encode!(["EVENT", state.event])
    {:reply, {:text, frame}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  def handle_frame({:text, payload}, %{event: %{"id" => expected_id}} = state)
      when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, ["OK", event_id, accepted, message]}
      when event_id == expected_id and is_boolean(accepted) and is_binary(message) ->
        state = finish(state, acknowledgement(accepted, message))
        {:close, state}

      _other ->
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  def handle_disconnect(status, state) do
    state =
      if state.finished do
        state
      else
        finish(state, {:error, {:disconnected, inspect(status.reason)}})
      end

    {:ok, state}
  end

  defp start_session(relay_url, event) do
    reference = make_ref()

    state = %{
      caller: self(),
      event: event,
      finished: false,
      reference: reference
    }

    case WebSockex.start(relay_url, __MODULE__, state,
           async: true,
           handle_initial_conn_failure: true
         ) do
      {:ok, pid} -> {:ok, {pid, reference}}
      error -> error
    end
  end

  defp await_result({pid, reference}, timeout) do
    monitor = Process.monitor(pid)

    receive do
      {:nostr_relay_result, ^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:connection_closed, reason}}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :shutdown)
        {:error, :relay_timeout}
    end
  end

  defp finish(%{finished: true} = state, _result), do: state

  defp finish(state, result) do
    send(state.caller, {:nostr_relay_result, state.reference, result})
    %{state | finished: true}
  end

  defp acknowledgement(true, message), do: {:ok, message}

  defp acknowledgement(false, message) do
    if String.starts_with?(String.downcase(message), "duplicate:") do
      {:ok, message}
    else
      {:error, {:rejected, message}}
    end
  end

  defp timeout_ms do
    case Config.get([Pleroma.Nostr, :relay_publish_timeout_ms], 10_000) do
      timeout when is_integer(timeout) and timeout in 1_000..60_000 -> timeout
      _invalid -> 10_000
    end
  end
end

# end of nostr/relay_delivery.ex
