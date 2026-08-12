# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CommonFixesTest do
  use Pleroma.DataCase, async: true

  require Pleroma.Constants

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes

  import Pleroma.Factory

  describe "fix_quote_url/1" do
    test "does not treat BookWyrm quotation text as an object reference" do
      quotation = %{
        "id" => "https://books.example/user/alice/quotation/123",
        "type" => "Quotation",
        "quote" => "A passage from the book."
      }

      assert ^quotation = CommonFixes.fix_quote_url(quotation)
      refute Map.has_key?(CommonFixes.fix_quote_url(quotation), "quoteUrl")
    end

    test "continues to normalize Hubzilla quote object references" do
      quote_url = "https://social.example/objects/quoted"

      fixed =
        CommonFixes.fix_quote_url(%{
          "id" => "https://hub.example/item/123",
          "type" => "Note",
          "quote" => quote_url
        })

      assert fixed["quoteUrl"] == quote_url
    end

    test "normalizes an FEP-e232 quote Link tag" do
      quote_url = "https://remote.example/objects/quoted"

      fixed =
        CommonFixes.fix_quote_url(%{
          "tag" => [
            %{
              "type" => "Link",
              "mediaType" => "application/activity+json",
              "rel" => ["alternate", "https://misskey-hub.net/ns#_misskey_quote"],
              "href" => quote_url
            }
          ]
        })

      assert fixed["quoteUrl"] == quote_url
    end

    test "does not treat an unrelated ActivityPub Link tag as a quote" do
      data = %{
        "tag" => [
          %{
            "type" => "Link",
            "mediaType" => "application/activity+json",
            "rel" => "alternate",
            "href" => "https://remote.example/objects/unrelated"
          }
        ]
      }

      assert ^data = CommonFixes.fix_quote_url(data)
    end
  end

  describe "fix_activity_addressing/1" do
    test "normalizes embedded actor objects before recipient fixing" do
      user = insert(:user, local: false)

      activity = %{
        "id" => "https://remote.example/activities/1",
        "type" => "Like",
        "actor" => %{"id" => user.ap_id, "type" => "Person"},
        "to" => ["Public"],
        "cc" => []
      }

      fixed = CommonFixes.fix_activity_addressing(activity)

      assert fixed["actor"] == user.ap_id
      assert Pleroma.Constants.as_public() in fixed["to"]
    end

    test "leaves unknown malformed actors for validation instead of raising" do
      activity = %{
        "id" => "https://remote.example/activities/2",
        "type" => "Like",
        "actor" => %{"type" => "Person"},
        "to" => ["Public"],
        "cc" => []
      }

      assert ^activity = CommonFixes.fix_activity_addressing(activity)
    end
  end

  describe "fix_object_action_recipients/2" do
    test "normalizes malformed to values before removing the object actor" do
      actor = "https://remote.example/users/alice"

      data = %{
        "type" => "Like",
        "actor" => actor,
        "to" => %{"id" => actor}
      }

      object = %Object{data: %{"actor" => actor}}

      assert %{"to" => []} = CommonFixes.fix_object_action_recipients(data, object)
    end

    test "normalizes malformed to values before adding the object actor" do
      actor = "https://remote.example/users/alice"
      object_actor = "https://remote.example/users/bob"
      existing = "https://remote.example/users/carol"

      data = %{
        "type" => "Like",
        "actor" => actor,
        "to" => [%{"href" => existing}, nil, %{"bad" => "shape"}]
      }

      object = %Object{data: %{"actor" => object_actor}}

      assert %{"to" => to} = CommonFixes.fix_object_action_recipients(data, object)
      assert Enum.sort(to) == Enum.sort([existing, object_actor])
    end

    test "leaves recipients unchanged when the target object has no actor" do
      data = %{
        "actor" => "https://lemmy.example/u/alice",
        "object" => "https://lemmy.example/post/1",
        "to" => [],
        "type" => "EmojiReact"
      }

      object = %Object{
        data: %{
          "deleted" => "2026-07-02T07:31:16Z",
          "formerType" => "Page",
          "id" => "https://lemmy.example/post/1",
          "type" => "Tombstone"
        }
      }

      assert ^data = CommonFixes.fix_object_action_recipients(data, object)
    end
  end

  describe "fix_activity_context/2" do
    test "uses the object id as context when the object has no explicit context" do
      data = %{
        "id" => "https://lemmy.world/activities/announce/like/1",
        "type" => "Like",
        "actor" => "https://remote.example/users/alice",
        "object" => "https://lemmy.example/post/1",
        "to" => [],
        "cc" => []
      }

      object = %Object{
        data: %{
          "id" => "https://lemmy.example/post/1",
          "type" => "Tombstone",
          "deleted" => "2026-06-29T10:44:17.964389Z"
        }
      }

      assert %{"context" => "https://lemmy.example/post/1"} =
               CommonFixes.fix_activity_context(data, object)
    end
  end

  describe "fix_object_defaults/1" do
    test "leaves malformed attributedTo values for validation instead of raising" do
      data = %{
        "id" => "https://remote.example/objects/1",
        "type" => "Note",
        "attributedTo" => %{"type" => "Person"},
        "to" => ["Public"],
        "cc" => [%{"id" => "https://remote.example/users/alice/followers"}]
      }

      fixed = CommonFixes.fix_object_defaults(data)

      assert fixed["context"] == data["id"]
      assert Pleroma.Constants.as_public() in fixed["to"]
      assert "https://remote.example/users/alice/followers" in fixed["cc"]
    end

    test "normalizes recipients even when the attributed actor is unknown" do
      data = %{
        "id" => "https://unknown-actor.example/objects/1",
        "type" => "Note",
        "attributedTo" => "https://unknown-actor.example/users/alice",
        "to" => [%{"href" => "Public"}],
        "cc" => [%{"id" => "https://unknown-actor.example/users/alice/followers"}]
      }

      fixed = CommonFixes.fix_object_defaults(data)

      assert fixed["to"] == [Pleroma.Constants.as_public()]
      assert fixed["cc"] == ["https://unknown-actor.example/users/alice/followers"]
    end

    test "inherits group context from the replied-to object" do
      group =
        insert(:user,
          actor_type: "Group",
          local: true,
          ap_id: "https://local.example/users/group"
        )

      parent =
        insert(:note,
          data: %{
            "id" => "https://local.example/objects/group-root",
            "type" => "Page",
            "actor" => "https://remote.example/users/alice",
            "audience" => group.ap_id,
            "to" => [Pleroma.Constants.as_public(), group.ap_id],
            "cc" => []
          }
        )

      data = %{
        "id" => "https://remote.example/objects/reply",
        "type" => "Note",
        "attributedTo" => "https://remote.example/users/pat",
        "inReplyTo" => parent.data["id"],
        "to" => [Pleroma.Constants.as_public()],
        "cc" => ["https://remote.example/users/pat/followers"]
      }

      fixed = CommonFixes.fix_object_defaults(data)

      assert fixed["audience"] == [group.ap_id]
      assert fixed["pleroma_internal"]["addressed_groups"] == [group.ap_id]
    end

    test "treats a group mention tag as group addressing" do
      group =
        insert(:user,
          actor_type: "Group",
          local: true,
          ap_id: "https://local.example/users/group"
        )

      data = %{
        "id" => "https://remote.example/objects/group-mention",
        "type" => "Note",
        "attributedTo" => "https://remote.example/users/pat",
        "to" => [Pleroma.Constants.as_public()],
        "cc" => ["https://remote.example/users/pat/followers"],
        "tag" => [
          %{
            "type" => "Mention",
            "href" => group.ap_id,
            "name" => "@group@local.example"
          }
        ]
      }

      fixed = CommonFixes.fix_object_defaults(data)

      assert fixed["audience"] == [group.ap_id]
      assert fixed["pleroma_internal"]["addressed_groups"] == [group.ap_id]
    end

    test "treats a bare group WebFinger mention as group addressing" do
      group =
        insert(:user,
          actor_type: "Group",
          local: true,
          nickname: "group_text_addressing",
          ap_id: "https://local.example/users/group_text_addressing"
        )

      data = %{
        "id" => "https://remote.example/objects/group-content-mention",
        "type" => "Note",
        "attributedTo" => "https://remote.example/users/pat",
        "to" => [Pleroma.Constants.as_public()],
        "cc" => ["https://remote.example/users/pat/followers"],
        "content" => "@group_text_addressing@#{Pleroma.Web.Endpoint.host()} hello group"
      }

      fixed = CommonFixes.fix_object_defaults(data)

      assert fixed["audience"] == [group.ap_id]
      assert fixed["pleroma_internal"]["addressed_groups"] == [group.ap_id]
    end
  end
end
