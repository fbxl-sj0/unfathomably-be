# Unfathomably BE
# ----------------
#
# File: workers/nostr_ingest_worker.ex
#
# Purpose:
#   Move external relay ingestion out of WebSocket transport processes.
#
# Responsibilities:
#   - deduplicate native relay echoes by event id
#   - invoke the bounded bridge ingestion path
#   - cancel deterministic protocol and policy rejections
#   - refuse events delivered by legacy ActivityPub-to-Nostr bridges
#
# This file intentionally does NOT validate events independently or manage
# relay connections.

defmodule Pleroma.Workers.NostrIngestWorker do
  # Nostr event IDs are immutable, so one accepted native relay copy is enough.
  use Pleroma.Workers.WorkerHelper,
    queue: "nostr",
    max_attempts: 3,
    unique: [period: :infinity, states: Oban.Job.states(), keys: [:event_id, :provenance]]

  alias Pleroma.Nostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Workers.NostrThreadRepairWorker

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @dedup_cache :nostr_ingest_dedup_cache

  def enqueue_event(event, relay_url) do
    if Nostr.compatibility_relay?(relay_url) do
      :ok
    else
      enqueue_native_event(event, relay_url)
    end
  end

  defp enqueue_native_event(event, relay_url) do
    provenance = "native"

    event_id = event_key(event)

    case @cachex.fetch(@dedup_cache, {provenance, event_id}, fn ->
           case insert_event_job(event, event_id, provenance, relay_url) do
             {:ok, _job} -> {:commit, :queued}
             _error -> {:ignore, :not_queued}
           end
         end) do
      {:error, _reason} ->
        insert_event_job(event, event_id, provenance, relay_url)

      _result ->
        :ok
    end

    :ok
  end

  @impl Oban.Worker
  def perform(%Job{args: %{"event" => event, "relay_url" => relay_url}}) do
    if Nostr.compatibility_relay?(relay_url) do
      {:cancel, :legacy_bridge_relay}
    else
      case Bridge.ingest_event(event, relay_url, :relay) do
        {:ok, event} ->
          NostrThreadRepairWorker.enqueue_for_event(event)
          NostrThreadRepairWorker.enqueue_waiting_children(event)
          :ok

        {:error, prefix, reason}
        when prefix in ["duplicate", "restricted", "error", "invalid"] ->
          {:cancel, {prefix, reason}}

        {:error, prefix, reason} ->
          {:error, {prefix, reason}}
      end
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  defp insert_event_job(event, event_id, provenance, relay_url) do
    __MODULE__.new(%{
      "event" => event,
      "event_id" => event_id,
      "provenance" => provenance,
      "relay_url" => relay_url
    })
    |> Oban.insert()
  end

  # Valid Nostr events already carry their immutable SHA-256 identifier. Keep a
  # deterministic fallback for malformed relay input so invalid events cannot
  # collapse onto one nil cache key before protocol validation rejects them.
  defp event_key(%{"id" => event_id})
       when is_binary(event_id) and byte_size(event_id) == 64,
       do: event_id

  defp event_key(event) do
    event
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

# end of workers/nostr_ingest_worker.ex
