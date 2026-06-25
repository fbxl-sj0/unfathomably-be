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

      assert_received {:fetch_object_from_id, @reply_1, [depth: 1]}
      assert_received {:fetch_object_from_id, @reply_2, [depth: 1]}
      refute_received {:fetch_object_from_id, @object_id, _}

      object = Object.get_by_ap_id(@object_id)
      refute object.data["replies"] == [@reply_1, @reply_2]
    end
  end
end
