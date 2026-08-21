# Unfathomably BE
# ----------------
#
# File: workers/nostr_nip05_verification_worker.ex
#
# Purpose:
#   Verify an optional NIP-05 profile claim without delaying Nostr hydration.
#
# Responsibilities:
#   - deduplicate verification by profile event
#   - perform the bounded HTTPS proof lookup on the slow queue
#   - discard results when newer profile metadata replaced the claim
#
# This file intentionally does NOT trust an unverified identifier, fetch Nostr
# relay events, or modify core profile fields directly.

defmodule Pleroma.Workers.NostrNIP05VerificationWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "slow",
    max_attempts: 1,
    unique: [period: 604_800, states: Oban.Job.states(), keys: [:entity_id, :event_id]]

  alias Pleroma.Nostr.Identity

  def enqueue_verification(entity_id, event_id, claim)
      when is_binary(entity_id) and is_binary(event_id) and is_binary(claim) and claim != "" do
    %{"entity_id" => entity_id, "event_id" => event_id, "claim" => claim}
    |> new()
    |> Oban.insert()

    :ok
  end

  def enqueue_verification(_entity_id, _event_id, _claim), do: :ok

  @impl Oban.Worker
  def perform(%Job{
        args: %{"entity_id" => entity_id, "event_id" => event_id, "claim" => claim}
      }) do
    Identity.verify_nip05(entity_id, event_id, claim)
  end

  def perform(%Job{}), do: {:cancel, :bad_request}
end

# end of workers/nostr_nip05_verification_worker.ex
