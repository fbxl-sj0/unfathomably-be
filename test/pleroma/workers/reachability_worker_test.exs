# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReachabilityWorkerTest do
  use Pleroma.DataCase, async: false

  import Pleroma.Factory

  alias Pleroma.Instances
  alias Pleroma.Workers.ReachabilityWorker

  setup do
    clear_config([:instance, :federation_reachability_timeout_days], 1)
  end

  test "marks instances reachable when NodeInfo answers" do
    Instances.set_unreachable("nodeinfo.example", Instances.reachability_datetime_threshold())

    Tesla.Mock.mock(fn %{url: "https://nodeinfo.example/.well-known/nodeinfo"} ->
      %Tesla.Env{status: 200, body: "{}"}
    end)

    assert {:ok, _} =
             ReachabilityWorker.perform(%Oban.Job{args: %{"domain" => "nodeinfo.example"}})

    assert Instances.reachable?("nodeinfo.example")
  end

  test "marks instances reachable when a known actor answers WebFinger" do
    insert(:user,
      local: false,
      nickname: "alice@webfinger.example",
      ap_id: "https://webfinger.example/users/alice"
    )

    Instances.set_unreachable("webfinger.example", Instances.reachability_datetime_threshold())

    Tesla.Mock.mock(fn
      %{url: "https://webfinger.example/.well-known/nodeinfo"} ->
        %Tesla.Env{status: 404, body: ""}

      %{url: "https://webfinger.example/.well-known/webfinger?resource=" <> _} ->
        %Tesla.Env{status: 200, body: "{}"}
    end)

    assert {:ok, _} =
             ReachabilityWorker.perform(%Oban.Job{args: %{"domain" => "webfinger.example"}})

    assert Instances.reachable?("webfinger.example")
  end
end
