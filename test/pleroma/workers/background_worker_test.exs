# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.BackgroundWorkerTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Workers.BackgroundWorker

  test "discards malformed background jobs instead of retrying them" do
    assert :discard =
             BackgroundWorker.perform(%Oban.Job{
               args: %{"op" => "delete_instance", "host" => nil}
             })

    assert :discard =
             BackgroundWorker.perform(%Oban.Job{
               args: %{"op" => "move_following", "origin_id" => "", "target_id" => 1}
             })

    assert :discard =
             BackgroundWorker.perform(%Oban.Job{
               args: %{"op" => "unknown_background_op"}
             })
  end

  test "cancels background jobs for missing users instead of retrying them" do
    assert {:cancel, :user_not_found} =
             BackgroundWorker.perform(%Oban.Job{
               args: %{"op" => "delete_user", "user_id" => "not-a-real-user"}
             })

    assert {:cancel, :origin_not_found} =
             BackgroundWorker.perform(%Oban.Job{
               args: %{
                 "op" => "move_following",
                 "origin_id" => "not-a-real-origin-user",
                 "target_id" => "not-a-real-target-user"
               }
             })
  end
end

# end of background_worker_test.exs
