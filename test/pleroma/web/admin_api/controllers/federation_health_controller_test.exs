# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.AdminAPI.FederationHealthControllerTest do
  use Pleroma.Web.ConnCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.Instances
  alias Pleroma.Workers.PublisherWorker

  setup do
    clear_config([:instance, :federation_reachability_timeout_days], 1)
    clear_config([:instance, :dormant_instance_timeout_days], 183)

    admin = insert(:user, is_admin: true)
    token = insert(:oauth_admin_token, user: admin)

    conn =
      build_conn()
      |> assign(:user, admin)
      |> assign(:token, token)

    {:ok, %{conn: conn}}
  end

  test "shows queue and unreachable remote instance health", %{conn: conn} do
    Instances.set_unreachable("maybe-back.example", Instances.reachability_datetime_threshold())
    Instances.set_unreachable("dead.example", Instances.dormant_datetime_threshold())

    insert_delivery_job("https://dead.example/inbox", state: "retryable")
    insert_delivery_job("https://active.example/inbox", state: "retryable")
    insert_delivery_job("https://maybe-back.example/inbox", state: "scheduled")

    response =
      conn
      |> get("/api/v1/pleroma/admin/federation/health")
      |> json_response(200)

    assert response["instances"]["unreachable"] == 2
    assert response["instances"]["consistently_unreachable"] == 2
    assert response["instances"]["dormant"] == 1

    assert response["outgoing"]["pending"] == 3
    assert response["outgoing"]["blocked_by_unreachable"] == 2
    assert response["outgoing"]["blocked_by_dormant"] == 1

    assert %{"host" => "dead.example", "dormant" => true} =
             Enum.find(response["unreachable_instances"], &(&1["host"] == "dead.example"))

    assert %{"name" => "federator_outgoing", "total" => 3, "states" => states} =
             Enum.find(response["queues"], &(&1["name"] == "federator_outgoing"))

    assert %{"state" => "retryable", "count" => 2} =
             Enum.find(states, &(&1["state"] == "retryable"))
  end

  defp insert_delivery_job(inbox, opts) do
    state = Keyword.fetch!(opts, :state)

    {:ok, job} =
      PublisherWorker.new(%{
        "op" => "publish_one",
        "module" => "Elixir.Pleroma.Web.ActivityPub.Publisher",
        "params" => %{
          "inbox" => inbox,
          "json" => "{}",
          "id" => "https://local.example/activity"
        }
      })
      |> Ecto.Changeset.put_change(:state, state)
      |> Oban.insert()

    job
  end
end
