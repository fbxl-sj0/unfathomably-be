# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.PollWorkerTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase, async: false

  alias Pleroma.Workers.PollWorker

  import Pleroma.Factory

  setup do
    clear_config([:instance, :poll_limits], %{max_expiration: 365 * 24 * 60 * 60})
  end

  test "does not schedule notifications for polls beyond the configured maximum age" do
    closed =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(370 * 24 * 60 * 60, :second)
      |> NaiveDateTime.to_iso8601()

    question = insert(:question, data: %{"closed" => closed})
    activity = insert(:question_activity, question: question)

    assert {:error, ^activity} = PollWorker.schedule_poll_end(activity)

    refute_enqueued(worker: PollWorker, args: %{op: "poll_end", activity_id: activity.id})
  end
end
