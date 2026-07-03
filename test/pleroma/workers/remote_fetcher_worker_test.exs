# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RemoteFetcherWorkerTest do
  use Pleroma.DataCase, async: false

  import Mock
  import Pleroma.Factory
  import Tesla.Mock

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.RemoteReplies
  alias Pleroma.Workers.RemoteFetcherWorker

  require Pleroma.Constants

  test "uses a configurable worker timeout" do
    assert RemoteFetcherWorker.timeout(%Oban.Job{}) == 30_000

    clear_config([RemoteFetcherWorker, :timeout_ms], 45_000)
    assert RemoteFetcherWorker.timeout(%Oban.Job{}) == 45_000

    clear_config([RemoteFetcherWorker, :timeout_ms], 100)
    assert RemoteFetcherWorker.timeout(%Oban.Job{}) == 1_000
  end

  test "cancels malformed remote fetch ids instead of retrying them" do
    assert {:cancel, :bad_request} =
             RemoteFetcherWorker.perform(%Oban.Job{
               args: %{
                 "op" => "fetch_remote",
                 "id" => %{"bad" => "shape"}
               }
             })

    assert {:cancel, :bad_request} =
             RemoteFetcherWorker.perform(%Oban.Job{
               args: %{"op" => "fetch_remote", "id" => ""}
             })

    assert {:cancel, :bad_request} =
             RemoteFetcherWorker.perform(%Oban.Job{
               args: %{"op" => "fetch_remote"}
             })

    assert {:cancel, :bad_request} =
             RemoteFetcherWorker.perform(%Oban.Job{
               args: %{"op" => "unknown"}
             })
  end

  test "cancels permanent remote fetch failures" do
    with_mock Fetcher, fetch_object_from_id: fn _, _ -> {:error, {:http, 404}} end do
      assert {:cancel, :not_found} =
               RemoteFetcherWorker.perform(%Oban.Job{
                 args: %{"op" => "fetch_remote", "id" => "https://remote.example/missing"}
               })
    end
  end

  test "cancels dormant-host fetches instead of retrying them" do
    with_mock Fetcher, fetch_object_from_id: fn _, _ -> {:error, :unreachable_host} end do
      assert {:cancel, :unreachable_host} =
               RemoteFetcherWorker.perform(%Oban.Job{
                 args: %{
                   "op" => "fetch_remote",
                   "id" => "https://dormant.example/objects/1"
                 }
               })
    end
  end

  test "cancels terminal remote fetch HTTP failures instead of retrying forever" do
    terminal_responses = [
      {400, :bad_request},
      {405, :method_not_allowed},
      {406, :not_acceptable},
      {501, :not_implemented}
    ]

    Enum.each(terminal_responses, fn {status, reason} ->
      with_mock Fetcher, fetch_object_from_id: fn _, _ -> {:error, {:http, status}} end do
        assert {:cancel, ^reason} =
                 RemoteFetcherWorker.perform(%Oban.Job{
                   args: %{
                     "op" => "fetch_remote",
                     "id" => "https://remote.example/terminal/#{status}"
                   }
                 })
      end
    end)
  end

  test "cancels non-ActivityPub content-type fetches" do
    with_mock Fetcher,
      fetch_object_from_id: fn _, _ -> {:error, {:content_type, "text/html; charset=utf-8"}} end do
      assert {:cancel, {:content_type, "text/html; charset=utf-8"}} =
               RemoteFetcherWorker.perform(%Oban.Job{
                 args: %{
                   "op" => "fetch_remote",
                   "id" => "https://remote.example/html-page"
                 }
               })
    end
  end

  test "cancels reaction activities whose actor or object cannot be fetched" do
    with_mock Fetcher,
      fetch_object_from_id: fn _, _ ->
        {:error, {:transmogrifier, {:error, :object_not_found}}}
      end do
      assert {:cancel, :object_not_found} =
               RemoteFetcherWorker.perform(%Oban.Job{
                 args: %{
                   "op" => "fetch_remote",
                   "id" => "https://remote.example/activities/like/1"
                 }
               })
    end
  end

  test "uses the thread resolver for thread-aware fetch jobs" do
    with_mock RemoteReplies,
      fetch_thread_from_reply: fn id, opts ->
        assert id == "https://remote.example/objects/reply"
        assert opts == [depth: 2]
        {:ok, %Object{}}
      end do
      assert :ok =
               RemoteFetcherWorker.perform(%Oban.Job{
                 args: %{
                   "op" => "fetch_remote",
                   "id" => "https://remote.example/objects/reply",
                   "depth" => 2,
                   "thread" => true
                 }
               })
    end
  end

  test "thread-aware fetch jobs import missing reply ancestors before the leaf" do
    actor = "https://remote.example/users/alice"
    root_id = "https://remote.example/objects/root"
    parent_id = "https://remote.example/objects/reply-parent"
    leaf_id = "https://remote.example/objects/reply-leaf"
    context = "https://remote.example/contexts/thread"
    public = Pleroma.Constants.as_public()

    user =
      insert(:user,
        local: false,
        ap_id: actor,
        follower_address: actor <> "/followers",
        domain: "remote.example"
      )

    root =
      insert(:note,
        user: user,
        data: %{
          "id" => root_id,
          "context" => context,
          "content" => "Root post",
          "to" => [public],
          "cc" => []
        }
      )

    insert(:note_activity,
      local: false,
      user: user,
      note: root,
      data_attrs: %{"context" => context}
    )

    mock(fn
      %{method: :get, url: ^leaf_id} ->
        activitypub_json(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => leaf_id,
          "type" => "Note",
          "actor" => actor,
          "attributedTo" => actor,
          "content" => "Leaf reply",
          "context" => context,
          "inReplyTo" => parent_id,
          "to" => [public],
          "cc" => []
        })

      %{method: :get, url: ^parent_id} ->
        activitypub_json(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => parent_id,
          "type" => "Note",
          "actor" => actor,
          "attributedTo" => actor,
          "content" => "Parent reply",
          "context" => context,
          "inReplyTo" => root_id,
          "to" => [public],
          "cc" => []
        })
    end)

    assert :ok =
             RemoteFetcherWorker.perform(%Oban.Job{
               args: %{
                 "op" => "fetch_remote",
                 "id" => leaf_id,
                 "depth" => 1,
                 "thread" => true
               }
             })

    assert %Activity{} = Activity.get_create_by_object_ap_id(parent_id)
    assert %Activity{} = Activity.get_create_by_object_ap_id(leaf_id)

    assert %Object{data: %{"inReplyTo" => ^root_id}} = Object.get_by_ap_id(parent_id)
    assert %Object{data: %{"inReplyTo" => ^parent_id}} = Object.get_by_ap_id(leaf_id)
  end

  defp activitypub_json(data) do
    %Tesla.Env{
      status: 200,
      headers: HttpRequestMock.activitypub_object_headers(),
      body: Jason.encode!(data)
    }
  end
end
