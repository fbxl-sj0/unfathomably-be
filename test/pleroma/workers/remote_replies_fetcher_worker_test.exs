# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RemoteRepliesFetcherWorkerTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory
  import Tesla.Mock

  alias Pleroma.Instances
  alias Pleroma.Object
  alias Pleroma.Workers.RemoteFetcherWorker
  alias Pleroma.Workers.RemoteRepliesFetcherWorker

  require Pleroma.Constants

  @actor "https://remote.example/users/alice"
  @parent_id "https://remote.example/objects/parent"
  @collection_id "https://remote.example/objects/parent/replies"
  @reply_1 "https://remote.example/objects/reply-1"
  @reply_2 "https://remote.example/objects/reply-2"

  setup do
    clear_config([:activitypub, :remote_replies_collection_refresh],
      enabled: true,
      schedule: [0],
      triggered_refresh_delay: 0,
      triggered_refresh_ancestor_depth: 3,
      max_pages: 2,
      max_items: 40
    )

    user =
      insert(:user,
        local: false,
        ap_id: @actor,
        follower_address: @actor <> "/followers"
      )

    parent =
      insert(:note,
        user: user,
        data: %{
          "id" => @parent_id,
          "actor" => @actor,
          "attributedTo" => @actor,
          "to" => [Pleroma.Constants.as_public()],
          "cc" => [],
          "replies_collection" => @collection_id
        }
      )

    %{parent: parent, user: user}
  end

  test "enqueues scheduled refreshes for a remote public object", %{parent: parent} do
    clear_config([:activitypub, :remote_replies_collection_refresh],
      enabled: true,
      schedule: [0, 60],
      triggered_refresh_delay: 0,
      triggered_refresh_ancestor_depth: 3,
      max_pages: 2,
      max_items: 40
    )

    assert :ok = RemoteRepliesFetcherWorker.enqueue_for_object(parent, 1)

    assert_enqueued(
      worker: RemoteRepliesFetcherWorker,
      args: %{
        "op" => "refresh_replies",
        "object_id" => @parent_id,
        "collection_id" => @collection_id,
        "depth" => 1,
        "refresh_index" => 0
      }
    )

    assert_enqueued(
      worker: RemoteRepliesFetcherWorker,
      args: %{
        "op" => "refresh_replies",
        "object_id" => @parent_id,
        "collection_id" => @collection_id,
        "depth" => 1,
        "refresh_index" => 1
      }
    )
  end

  test "does not enqueue refreshes for a collection from another origin", %{parent: parent} do
    {:ok, parent} =
      Object.update_data(parent, %{"replies_collection" => "https://other.example/replies"})

    assert :ok = RemoteRepliesFetcherWorker.enqueue_for_object(parent, 1)
    assert all_enqueued(worker: RemoteRepliesFetcherWorker) == []
  end

  test "enqueues a debounced refresh for a known reply parent", %{parent: parent, user: user} do
    reply =
      insert(:note,
        user: user,
        data: %{
          "id" => @reply_1,
          "actor" => @actor,
          "attributedTo" => @actor,
          "to" => [Pleroma.Constants.as_public()],
          "cc" => [],
          "inReplyTo" => parent.data["id"]
        }
      )

    assert :ok = RemoteRepliesFetcherWorker.enqueue_for_reply_ancestors(reply, 2)

    assert_enqueued(
      worker: RemoteRepliesFetcherWorker,
      args: %{
        "op" => "refresh_replies",
        "object_id" => @parent_id,
        "collection_id" => @collection_id,
        "depth" => 2,
        "refresh_index" => "triggered"
      }
    )
  end

  test "fetches an advertised collection and enqueues missing replies" do
    mock(fn
      %{method: :get, url: @collection_id} ->
        activitypub_json(%{
          "id" => @collection_id,
          "type" => "OrderedCollection",
          "orderedItems" => [@reply_1, %{"id" => @reply_2}]
        })
    end)

    assert :ok =
             perform_job(RemoteRepliesFetcherWorker, %{
               "op" => "refresh_replies",
               "object_id" => @parent_id,
               "collection_id" => @collection_id,
               "depth" => 1,
               "refresh_index" => 0
             })

    assert_enqueued(
      worker: RemoteFetcherWorker,
      args: %{"op" => "fetch_remote", "id" => @reply_1, "depth" => 1, "thread" => true}
    )

    assert_enqueued(
      worker: RemoteFetcherWorker,
      args: %{"op" => "fetch_remote", "id" => @reply_2, "depth" => 1, "thread" => true}
    )
  end

  test "does not pile up duplicate fetch jobs when reply refreshes repeat" do
    mock(fn
      %{method: :get, url: @collection_id} ->
        activitypub_json(%{
          "id" => @collection_id,
          "type" => "OrderedCollection",
          "orderedItems" => [@reply_1]
        })
    end)

    args = %{
      "op" => "refresh_replies",
      "object_id" => @parent_id,
      "collection_id" => @collection_id,
      "depth" => 1,
      "refresh_index" => 0
    }

    assert :ok = perform_job(RemoteRepliesFetcherWorker, args)
    assert :ok = perform_job(RemoteRepliesFetcherWorker, args)

    assert [
             %Oban.Job{
               args: %{
                 "op" => "fetch_remote",
                 "id" => @reply_1,
                 "depth" => 1,
                 "thread" => true
               }
             }
           ] = all_enqueued(worker: RemoteFetcherWorker)
  end

  test "fetches reply ids from wrapped collection items" do
    mock(fn
      %{method: :get, url: @collection_id} ->
        activitypub_json(%{
          "id" => @collection_id,
          "type" => "OrderedCollection",
          "orderedItems" => [
            %{"type" => "Create", "object" => @reply_1},
            %{"object" => %{"id" => @reply_2}},
            %{"object" => %{"bad" => "shape"}},
            nil,
            42
          ]
        })
    end)

    assert :ok =
             perform_job(RemoteRepliesFetcherWorker, %{
               "op" => "refresh_replies",
               "object_id" => @parent_id,
               "collection_id" => @collection_id,
               "depth" => 1,
               "refresh_index" => 0
             })

    assert_enqueued(
      worker: RemoteFetcherWorker,
      args: %{"op" => "fetch_remote", "id" => @reply_1, "depth" => 1, "thread" => true}
    )

    assert_enqueued(
      worker: RemoteFetcherWorker,
      args: %{"op" => "fetch_remote", "id" => @reply_2, "depth" => 1, "thread" => true}
    )
  end

  test "cancels deleted collections instead of retrying forever" do
    mock(fn
      %{method: :get, url: @collection_id} ->
        %Tesla.Env{status: 404}
    end)

    assert {:cancel, :not_found} =
             perform_job(RemoteRepliesFetcherWorker, %{
               "op" => "refresh_replies",
               "object_id" => @parent_id,
               "collection_id" => @collection_id,
               "depth" => 1,
               "refresh_index" => 0
             })
  end

  test "cancels terminal collection fetch responses instead of retrying forever" do
    terminal_responses = [
      {400, :bad_request},
      {405, :method_not_allowed},
      {406, :not_acceptable},
      {501, :not_implemented}
    ]

    Enum.each(terminal_responses, fn {status, reason} ->
      mock(fn
        %{method: :get, url: @collection_id} ->
          %Tesla.Env{status: status}
      end)

      assert {:cancel, ^reason} =
               perform_job(RemoteRepliesFetcherWorker, %{
                 "op" => "refresh_replies",
                 "object_id" => @parent_id,
                 "collection_id" => @collection_id,
                 "depth" => 1,
                 "refresh_index" => 0
               })
    end)
  end

  test "cancels dormant-host collection fetches instead of retrying them" do
    clear_config([:instance, :dormant_instance_timeout_days], 1)
    Instances.set_unreachable("remote.example", Instances.dormant_datetime_threshold())

    assert {:cancel, :unreachable_host} =
             perform_job(RemoteRepliesFetcherWorker, %{
               "op" => "refresh_replies",
               "object_id" => @parent_id,
               "collection_id" => @collection_id,
               "depth" => 1,
               "refresh_index" => 0
             })
  end

  test "cancels malformed refresh jobs before fetching" do
    assert {:cancel, :bad_request} =
             RemoteRepliesFetcherWorker.perform(%Oban.Job{
               args: %{
                 "op" => "refresh_replies",
                 "object_id" => @parent_id,
                 "collection_id" => 42,
                 "depth" => 1,
                 "refresh_index" => 0
               }
             })

    assert {:cancel, :bad_request} =
             RemoteRepliesFetcherWorker.perform(%Oban.Job{
               args: %{
                 "op" => "refresh_replies",
                 "object_id" => @parent_id,
                 "collection_id" => @collection_id,
                 "depth" => "1",
                 "refresh_index" => 0
               }
             })

    assert {:cancel, :bad_request} =
             RemoteRepliesFetcherWorker.perform(%Oban.Job{
               args: %{"op" => "unknown_remote_replies_op"}
             })
  end

  defp activitypub_json(data) do
    %Tesla.Env{
      status: 200,
      headers: HttpRequestMock.activitypub_object_headers(),
      body: Jason.encode!(data)
    }
  end
end
