# Unfathomably BE
# ----------------
#
# File: workers/nostr_proxy_reconcile_worker.ex
#
# Purpose:
#   Collapse dual ActivityPub and Nostr delivery of one discussion item onto
#   the canonical ActivityPub activity.
#
# Responsibilities:
#   - find a stored Nostr event by its signed NIP-48 ActivityPub proxy URI
#   - defer reconciliation until the incoming ActivityPub transaction commits
#   - deduplicate concurrent relay and ActivityPub arrival races by event ID
#
# This file intentionally does NOT trust proxy tags without identity
# verification, fetch arbitrary proxy URLs, or publish protocol events.

defmodule Pleroma.Workers.NostrProxyReconcileWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "nostr",
    max_attempts: 1,
    unique: [period: 300, states: Oban.Job.states(), keys: [:event_id]]

  alias Pleroma.Activity
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Store

  def enqueue_activity(%Activity{data: %{"id" => activity_uri}})
      when is_binary(activity_uri) do
    case Store.get_by_ap_activity_uri(activity_uri) do
      %Pleroma.Nostr.Event{id: event_id} ->
        __MODULE__.new(%{"event_id" => event_id}, schedule_in: 1)
        |> Oban.insert()

      _ ->
        :ok
    end

    :ok
  end

  def enqueue_activity(_activity), do: :ok

  @impl Oban.Worker
  def perform(%Job{args: %{"event_id" => event_id}}) when is_binary(event_id) do
    Bridge.reconcile_activitypub_proxy(event_id)
  end

  def perform(%Job{}), do: {:cancel, :bad_request}
end

# end of workers/nostr_proxy_reconcile_worker.ex
