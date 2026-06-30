# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ActivityPubDeadHostTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  alias Pleroma.Instances
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Workers.RemoteFetcherWorker

  test "does not enqueue pinned object fetches for dormant hosts" do
    clear_config([:instance, :dormant_instance_timeout_days], 1)

    Instances.set_unreachable("pinned-dead.example", Instances.dormant_datetime_threshold())

    ActivityPub.enqueue_pin_fetches(%{
      pinned_objects: %{
        "https://pinned-dead.example/objects/1" => DateTime.utc_now()
      }
    })

    assert all_enqueued(worker: RemoteFetcherWorker) == []
  end

  test "does not fail pinned object checks for dormant hosts" do
    clear_config([:instance, :dormant_instance_timeout_days], 1)

    Instances.set_unreachable("pinned-dead.example", Instances.dormant_datetime_threshold())

    assert :ok =
             ActivityPub.pinned_fetch_task(%{
               pinned_objects: %{
                 "https://pinned-dead.example/objects/1" => DateTime.utc_now()
               }
             })
  end

  test "ignores malformed pinned object collections" do
    assert :ok = ActivityPub.enqueue_pin_fetches(%{pinned_objects: "not a collection"})
    assert :ok = ActivityPub.pinned_fetch_task(%{pinned_objects: "not a collection"})
  end
end

# end of activity_pub_dead_host_test.exs
