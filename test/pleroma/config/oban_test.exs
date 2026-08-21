# Unfathomably BE
# ----------------
#
# File: test/pleroma/config/oban_test.exs
#
# Purpose:
#   Verify startup repair of stale ConfigDB Oban schedules.
#
# Responsibilities:
#   - preserve operator-defined cron entries
#   - restore required native Nostr maintenance workers when Nostr is enabled
#   - leave Nostr workers absent when the integration is disabled
#
# This file intentionally does NOT start Oban or execute scheduled jobs.

defmodule Pleroma.Config.ObanTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.Config
  alias Pleroma.Config.Oban, as: ObanConfig

  test "restores required Nostr workers after a stale ConfigDB override" do
    cleanup_worker = Pleroma.Workers.Cron.ObanCleanupWorker

    clear_config([Pleroma.Nostr, :enabled], true)

    clear_config(Oban,
      repo: Pleroma.Repo,
      queues: [background: 1],
      crontab: [{"17 * * * *", cleanup_worker}]
    )

    ObanConfig.warn()

    crontab = Config.get(Oban)[:crontab]

    assert {"17 * * * *", cleanup_worker} in crontab
    assert {"*/10 * * * *", Pleroma.Workers.NostrProfileSweepWorker} in crontab
    assert {"*/30 * * * *", Pleroma.Workers.NostrCommunityDiscoveryWorker} in crontab
  end

  test "does not add native Nostr workers when Nostr is disabled" do
    clear_config([Pleroma.Nostr, :enabled], false)
    clear_config(Oban, repo: Pleroma.Repo, queues: [], crontab: [])

    ObanConfig.warn()

    assert Config.get(Oban)[:crontab] == []
  end
end

# end of test/pleroma/config/oban_test.exs
