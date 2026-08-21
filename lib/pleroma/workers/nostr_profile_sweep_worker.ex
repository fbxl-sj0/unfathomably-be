# Unfathomably BE
# ----------------
#
# File: workers/nostr_profile_sweep_worker.ex
#
# Purpose:
#   Schedule bounded periodic recovery of unhydrated native Nostr profiles.
#
# Responsibilities:
#   - keep the cron job independent from per-pubkey backfill uniqueness
#   - invoke one batched metadata sweep on the slow queue
#
# This file intentionally does NOT query relays, project profile metadata, or
# manage per-identity retry state.

defmodule Pleroma.Workers.NostrProfileSweepWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "slow",
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Pleroma.Workers.NostrProfileBackfillWorker

  @impl Oban.Worker
  def perform(%Job{args: args}) when map_size(args) == 0 do
    {:ok, _count} = NostrProfileBackfillWorker.enqueue_unhydrated_profiles()
    :ok
  end

  def perform(%Job{}), do: {:cancel, :bad_request}
end

# end of workers/nostr_profile_sweep_worker.ex
