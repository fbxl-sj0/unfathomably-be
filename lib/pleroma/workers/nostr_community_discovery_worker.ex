# Unfathomably BE
# ----------------
#
# File: workers/nostr_community_discovery_worker.ex
#
# Purpose:
#   Refresh the bounded catalogue of active Nostr communities.
#
# Responsibilities:
#   - run NIP-29 and NIP-72 discovery outside web requests
#   - prevent overlapping relay catalogue scans
#   - keep deterministic relay failures from retrying aggressively
#
# This file intentionally does NOT define protocol validation, ranking, or
# relay transport behavior.

defmodule Pleroma.Workers.NostrCommunityDiscoveryWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "nostr",
    max_attempts: 1,
    unique: [period: 1_800, states: Oban.Job.states()]

  alias Pleroma.Nostr.CommunityDiscovery

  @impl Oban.Worker
  def perform(%Job{}) do
    CommunityDiscovery.refresh()
  end
end

# end of workers/nostr_community_discovery_worker.ex
