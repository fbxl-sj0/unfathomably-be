# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.UserRefreshWorkerTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Workers.UserRefreshWorker

  test "keeps actor refresh work bounded while allowing compatibility lookups" do
    assert UserRefreshWorker.timeout(%Oban.Job{}) == :timer.seconds(30)
  end
end

# end of test/pleroma/workers/user_refresh_worker_test.exs
