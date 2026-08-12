# Unfathomably BE
# ----------------
#
# File: workers/nostr_relay_publish_worker.ex
#
# Purpose:
#   Deliver a signed Nostr event durably to one approved external relay.
#
# Responsibilities:
#   - keep one independently retryable job per event and relay
#   - wait for a matching NIP-20 acknowledgement
#   - retry transport and temporary relay failures with bounded backoff
#   - cancel deterministic policy and validation rejections
#
# This file intentionally does NOT sign events, select destinations, or store
# local relay data.

defmodule Pleroma.Workers.NostrRelayPublishWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "nostr",
    max_attempts: 5,
    unique: [period: 86_400, states: :incomplete]

  require Logger

  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayDelivery
  alias Pleroma.Workers.WorkerHelper

  def enqueue_delivery(event, relay_url) when is_map(event) and is_binary(relay_url) do
    __MODULE__.new(%{
      "event" => event,
      "event_id" => event["id"],
      "relay_url" => relay_url
    })
    |> Oban.insert()
  end

  def enqueue_delivery(_event, _relay_url), do: {:error, :invalid_delivery}

  @impl Oban.Worker
  def perform(%Job{args: %{"event" => event, "relay_url" => relay_url}}) do
    with {:ok, event} <- Protocol.validate_event(event) do
      case RelayDelivery.publish(relay_url, event) do
        {:ok, message} ->
          Logger.debug("Nostr relay accepted event",
            relay: relay_url,
            event_id: event["id"],
            reason: message
          )

          :ok

        {:error, {:rejected, message}} ->
          handle_rejection(relay_url, event["id"], message)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  @impl Oban.Worker
  def backoff(%Job{attempt: attempt}), do: WorkerHelper.sidekiq_backoff(attempt, 3, 10)

  defp handle_rejection(relay_url, event_id, message) do
    if temporary_rejection?(message) do
      {:error, {:relay_rejected_temporarily, message}}
    else
      Logger.warning("Nostr relay rejected event permanently",
        relay: relay_url,
        event_id: event_id,
        reason: message
      )

      {:cancel, {:relay_rejected, message}}
    end
  end

  defp temporary_rejection?(message) do
    message = String.downcase(message)

    Enum.any?(["rate-limited:", "temporarily:", "error:", "timeout:"], fn prefix ->
      String.starts_with?(message, prefix)
    end)
  end
end

# end of workers/nostr_relay_publish_worker.ex
