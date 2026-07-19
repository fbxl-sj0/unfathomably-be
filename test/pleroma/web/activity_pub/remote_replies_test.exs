# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.RemoteRepliesTest do
  use Pleroma.DataCase, async: false

  import Mock
  import Pleroma.Factory

  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.RemoteReplies

  require Pleroma.Constants

  @actor "https://forums.example/users/alice"
  @object_id "https://forums.example/posts/1"
  @context_id "https://forums.example/topic/1"
  @next_page_id "https://forums.example/topic/1?page=2"
  @reply_1 "https://forums.example/posts/2"
  @reply_2 "https://forums.example/posts/3"

  test "hydrates items from a resolvable context collection" do
    test_pid = self()

    user =
      insert(:user,
        local: false,
        ap_id: @actor,
        follower_address: @actor <> "/followers"
      )

    object =
      insert(:note,
        user: user,
        data: %{
          "id" => @object_id,
          "type" => "Note",
          "actor" => @actor,
          "attributedTo" => @actor,
          "context" => @context_id,
          "to" => [Pleroma.Constants.as_public()],
          "cc" => []
        }
      )

    with_mock Fetcher,
      fetch_and_contain_remote_object_from_id: fn
        @context_id ->
          {:ok,
           %{
             "id" => @context_id,
             "type" => "OrderedCollection",
             "orderedItems" => [@object_id, @reply_1],
             "next" => @next_page_id
           }}

        @next_page_id ->
          {:ok,
           %{
             "id" => @next_page_id,
             "type" => "OrderedCollectionPage",
             "orderedItems" => [%{"id" => @reply_2}]
           }}

        reply_id when reply_id in [@reply_1, @reply_2] ->
          {:ok,
           %{
             "id" => reply_id,
             "type" => "Note",
             "actor" => @actor,
             "attributedTo" => @actor,
             "context" => @context_id,
             "to" => [Pleroma.Constants.as_public()],
             "cc" => []
           }}
      end,
      fetch_object_from_id: fn id, opts ->
        send(test_pid, {:fetch_object_from_id, id, opts})
        {:ok, %Object{data: %{"id" => id}}}
      end do
      assert :ok = RemoteReplies.fetch_for_object(object)

      assert_received {:fetch_object_from_id, @reply_1, reply_1_opts}
      assert_received {:fetch_object_from_id, @reply_2, reply_2_opts}
      assert reply_1_opts[:depth] == 1
      assert reply_1_opts[:prefetched_data]["id"] == @reply_1
      assert reply_2_opts[:depth] == 1
      assert reply_2_opts[:prefetched_data]["id"] == @reply_2
      refute_received {:fetch_object_from_id, @object_id, _}

      object = Object.get_by_ap_id(@object_id)
      refute object.data["replies"] == [@reply_1, @reply_2]
    end
  end

  test "does not repeat a failed discovery fetch while hydrating a reply" do
    test_pid = self()

    with_mock Fetcher,
      fetch_and_contain_remote_object_from_id: fn @reply_1 ->
        send(test_pid, {:discovery_fetch, @reply_1})
        {:error, :recv_response_timeout}
      end,
      fetch_object_from_id: fn id, opts ->
        send(test_pid, {:persistence_fetch, id, opts})
        {:error, :recv_response_timeout}
      end do
      assert {:error, :recv_response_timeout} =
               RemoteReplies.fetch_thread_from_reply(@reply_1, depth: 0)

      assert_received {:discovery_fetch, @reply_1}
      refute_received {:persistence_fetch, @reply_1, _}
    end
  end
end
