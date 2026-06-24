# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.RSSFeedRefreshWorker do
  @moduledoc """
  Schedules refresh jobs for followed RSS and Atom sources.
  """

  use Oban.Worker, queue: "background", max_attempts: 1

  alias Pleroma.RSSFeed

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, RSSFeed.schedule_refreshes()}
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)
end
