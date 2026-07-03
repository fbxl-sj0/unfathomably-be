# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.CommonAPI.ActivityDraftTest do
  use Pleroma.DataCase

  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.CommonAPI.ActivityDraft

  import Pleroma.Factory

  describe "create/2 for group posts" do
    test "uses Page for top-level group roots" do
      user = insert(:user)
      group = insert(:user, actor_type: "Group")

      assert {:ok, draft} =
               ActivityDraft.create(user, %{
                 status: "This is the body that should federate as a group post.",
                 spoiler_text: "A Lemmy-style thread title",
                 group_id: group.id,
                 visibility: "public"
               })

      assert draft.object["type"] == "Page"
      assert draft.object["name"] == "A Lemmy-style thread title"
      assert draft.object["summary"] == "A Lemmy-style thread title"
      assert draft.object["content"] =~ "This is the body"
      assert draft.object["audience"] == group.ap_id
      refute Map.has_key?(draft.object, "inReplyTo")
    end

    test "keeps group replies as Notes" do
      user = insert(:user)
      group = insert(:user, actor_type: "Group")

      {:ok, root} =
        CommonAPI.post(user, %{
          status: "A root post",
          spoiler_text: "Root title",
          group_id: group.id,
          visibility: "public"
        })

      assert root.object.data["type"] == "Page"
      assert root.object.data["name"] == "Root title"

      assert {:ok, draft} =
               ActivityDraft.create(user, %{
                 status: "A reply that should remain a comment.",
                 group_id: group.id,
                 in_reply_to_status_id: root.id,
                 visibility: "public"
               })

      assert draft.object["type"] == "Note"
      assert draft.object["audience"] == group.ap_id
      assert draft.object["inReplyTo"] == root.object.data["id"]
      refute Map.has_key?(draft.object, "name")
    end
  end

  test "create/2 with a quote post" do
    user = insert(:user)
    another_user = insert(:user)

    {:ok, direct} = CommonAPI.post(user, %{status: ".", visibility: "direct"})
    {:ok, private} = CommonAPI.post(user, %{status: ".", visibility: "private"})
    {:ok, unlisted} = CommonAPI.post(user, %{status: ".", visibility: "unlisted"})
    {:ok, local} = CommonAPI.post(user, %{status: ".", visibility: "local"})
    {:ok, public} = CommonAPI.post(user, %{status: ".", visibility: "public"})

    {:error, _} = ActivityDraft.create(user, %{status: "nice", quote_id: direct.id})
    {:ok, _} = ActivityDraft.create(user, %{status: "nice", quote_id: private.id})
    {:error, _} = ActivityDraft.create(another_user, %{status: "nice", quote_id: private.id})
    {:ok, _} = ActivityDraft.create(user, %{status: "nice", quote_id: unlisted.id})
    {:ok, _} = ActivityDraft.create(another_user, %{status: "nice", quote_id: unlisted.id})
    {:ok, _} = ActivityDraft.create(user, %{status: "nice", quote_id: local.id})
    {:ok, _} = ActivityDraft.create(another_user, %{status: "nice", quote_id: local.id})
    {:ok, _} = ActivityDraft.create(user, %{status: "nice", quote_id: public.id})
    {:ok, _} = ActivityDraft.create(another_user, %{status: "nice", quote_id: public.id})
  end
end
