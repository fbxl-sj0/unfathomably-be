# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.BuilderTest do
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.CommonAPI.ActivityDraft
  use Pleroma.DataCase

  import Pleroma.Factory

  require Pleroma.Constants

  describe "note/1" do
    test "returns note data" do
      user = insert(:user)
      note = insert(:note)
      user2 = insert(:user)
      user3 = insert(:user)

      draft = %ActivityDraft{
        user: user,
        to: [user2.ap_id],
        context: "2hu",
        content_html: "<h1>This is :moominmamma: note</h1>",
        in_reply_to: note.id,
        tags: [name: "jimm"],
        summary: "test summary",
        cc: [user3.ap_id],
        extra: %{"custom_tag" => "test"}
      }

      expected = %{
        "actor" => user.ap_id,
        "attachment" => [],
        "cc" => [user3.ap_id],
        "content" => "<h1>This is :moominmamma: note</h1>",
        "context" => "2hu",
        "sensitive" => false,
        "summary" => "test summary",
        "tag" => ["jimm"],
        "to" => [user2.ap_id],
        "type" => "Note",
        "custom_tag" => "test"
      }

      assert {:ok, ^expected, []} = Builder.note(draft)
    end

    test "quote post" do
      user = insert(:user)
      note = insert(:note)

      draft = %ActivityDraft{
        user: user,
        context: "2hu",
        content_html: "<h1>This is :moominmamma: note</h1>",
        quote_post: note,
        extra: %{}
      }

      expected = %{
        "actor" => user.ap_id,
        "attachment" => [],
        "content" => "<h1>This is :moominmamma: note</h1>",
        "context" => "2hu",
        "sensitive" => false,
        "type" => "Note",
        "quoteUrl" => note.data["id"],
        "cc" => [],
        "summary" => nil,
        "tag" => [],
        "to" => []
      }

      assert {:ok, ^expected, []} = Builder.note(draft)
    end
  end

  describe "emoji_react/3" do
    test "does not crash when the target object has malformed addressing" do
      actor = insert(:user)

      object = %Pleroma.Object{
        data: %{
          "id" => "https://remote.example/objects/bad-addressing",
          "actor" => "https://remote.example/users/missing",
          "type" => "Note",
          "to" => nil,
          "cc" => %{"bad" => "shape"}
        }
      }

      assert {:ok, data, []} = Builder.emoji_react(actor, object, "\u{1F44D}")
      assert data["type"] == "EmojiReact"
      assert data["object"] == object.data["id"]
      assert data["to"] == [object.data["actor"]]
      assert data["cc"] == []
    end
  end

  describe "undo/2" do
    test "embeds vote activities so remote community software can validate UndoVote" do
      actor = insert(:user)

      like =
        insert(:like_activity,
          data_attrs: %{
            "actor" => actor.ap_id,
            "audience" => ["https://lemmy.example/c/main"],
            "to" => ["https://lemmy.example/u/poster"],
            "cc" => ["https://www.w3.org/ns/activitystreams#Public"]
          }
        )

      {:ok, data, []} = Builder.undo(actor, like)

      assert data["type"] == "Undo"
      assert data["object"] == like.data
      assert data["audience"] == ["https://lemmy.example/c/main"]
    end

    test "keeps non-vote Undo objects as activity ids" do
      actor = insert(:user)
      follow = insert(:follow_activity)

      {:ok, data, []} = Builder.undo(actor, follow)

      assert data["type"] == "Undo"
      assert data["object"] == follow.data["id"]
      refute Map.has_key?(data, "audience")
    end
  end

  describe "delete/2" do
    test "keeps empty summary markers for group moderator removals" do
      actor = insert(:user)
      object = insert(:note, user: actor)

      assert {:ok, data, []} = Builder.delete(actor, object.data["id"], summary: "")

      assert data["type"] == "Delete"
      assert data["summary"] == ""
    end

    test "keeps group context when deleting group-addressed objects" do
      actor = insert(:user)
      group = insert(:user, actor_type: "Group", local: true)

      {:ok, object} =
        Pleroma.Object.create(%{
          "id" => "https://remote.example/objects/group-reply-delete",
          "actor" => actor.ap_id,
          "type" => "Note",
          "to" => [Pleroma.Constants.as_public()],
          "cc" => [group.ap_id],
          "audience" => group.ap_id
        })

      assert {:ok, data, []} = Builder.delete(actor, object.data["id"])

      assert data["type"] == "Delete"
      assert data["object"] == object.data["id"]
      assert data["audience"] == group.ap_id
      assert data["cc"] == [group.ap_id]
    end

    test "does not crash when the deleted object has malformed addressing" do
      actor = insert(:user)
      mentioned = insert(:user)

      {:ok, object} =
        Pleroma.Object.create(%{
          "id" => "https://remote.example/objects/delete-with-bad-addressing",
          "actor" => "https://remote.example/users/alice",
          "type" => "Note",
          "to" => %{"bad" => "shape"},
          "cc" => [mentioned.ap_id, nil, %{"id" => "https://ignored.example/users/bob"}]
        })

      assert {:ok, data, []} = Builder.delete(actor, object.data["id"])
      assert data["type"] == "Delete"
      assert data["object"] == object.data["id"]
      assert data["to"] == [mentioned.ap_id]
    end
  end
end
