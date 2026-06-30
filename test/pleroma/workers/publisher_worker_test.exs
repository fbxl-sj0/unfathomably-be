# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.PublisherWorkerTest do
  use Pleroma.DataCase, async: true
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.Instances
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.PublisherWorker

  describe "backoff/1" do
    test "caps publisher retry delays at one day" do
      assert PublisherWorker.backoff(%Oban.Job{attempt: 1_000}) == 24 * 60 * 60
    end
  end

  describe "Oban job priority:" do
    setup do
      user = insert(:user)

      {:ok, post} = CommonAPI.post(user, %{status: "Regrettable post"})
      object = Object.normalize(post, fetch: false)
      {:ok, delete_data, _meta} = Builder.delete(user, object.data["id"])
      {:ok, delete, _meta} = ActivityPub.persist(delete_data, local: true)

      %{
        post: post,
        delete: delete
      }
    end

    test "Deletions are lower priority", %{delete: delete} do
      assert {:ok, %Oban.Job{priority: 3}} = Federator.publish(delete)
    end

    test "Creates are normal priority", %{post: post} do
      assert {:ok, %Oban.Job{priority: 0}} = Federator.publish(post)
    end
  end

  describe "transient activity data" do
    test "keeps embedded Undo objects across the deferred publish job" do
      activity = insert(:note_activity)

      data =
        activity.data
        |> Map.put("type", "Undo")
        |> Map.put("object", %{
          "id" => "https://remote.example/activities/like/1",
          "type" => "Like",
          "actor" => activity.actor,
          "object" => "https://remote.example/post/1"
        })

      activity = %{activity | data: data}

      assert {:ok, %Oban.Job{args: %{"activity_data" => %{"object" => %{"type" => "Like"}}}}} =
               Federator.publish(activity)
    end

    test "cancels publish jobs for missing activities" do
      activity = insert(:note_activity)
      {:ok, _activity} = Repo.delete(activity)

      job = %Oban.Job{args: %{"op" => "publish", "activity_id" => activity.id}}

      assert {:cancel, :activity_not_found} = PublisherWorker.perform(job)
    end
  end

  describe "dormant instance delivery" do
    setup do
      clear_config([:instance, :dormant_instance_timeout_days], 1)
    end

    test "cancels already queued single-recipient deliveries to dormant instances" do
      Instances.set_unreachable("dormant.example", Instances.dormant_datetime_threshold())

      job = %Oban.Job{
        args: %{
          "op" => "publish_one",
          "module" => "Elixir.Pleroma.Web.ActivityPub.Publisher",
          "params" => %{"inbox" => "https://dormant.example/inbox"}
        }
      }

      assert {:cancel, :dormant_instance} = PublisherWorker.perform(job)
    end

    test "cancels publish_one jobs with unknown modules without creating atoms" do
      job = %Oban.Job{
        args: %{
          "op" => "publish_one",
          "module" => "Elixir.Pleroma.Does.Not.Exist",
          "params" => %{"inbox" => "https://example.com/inbox"}
        }
      }

      assert {:cancel, :unknown_atom} = PublisherWorker.perform(job)
    end

    test "cancels publish_one jobs with malformed params" do
      job = %Oban.Job{
        args: %{
          "op" => "publish_one",
          "module" => "Elixir.Pleroma.Web.ActivityPub.Publisher",
          "params" => %{"totally_unknown_param" => "value"}
        }
      }

      assert {:cancel, :unknown_param} = PublisherWorker.perform(job)
    end

    test "cancels malformed publisher jobs" do
      assert {:cancel, :invalid_params} =
               PublisherWorker.perform(%Oban.Job{args: %{"op" => "publish_one"}})

      assert {:cancel, :invalid_params} =
               PublisherWorker.perform(%Oban.Job{args: %{"op" => "unknown"}})
    end
  end
end
