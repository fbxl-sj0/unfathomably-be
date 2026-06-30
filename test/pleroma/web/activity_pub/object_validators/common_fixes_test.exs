# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CommonFixesTest do
  use Pleroma.DataCase, async: true

  require Pleroma.Constants

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes

  import Pleroma.Factory

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
  end

  describe "fix_activity_context/2" do
    test "leaves activity data unchanged when the object has no context" do
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

      assert ^data = CommonFixes.fix_activity_context(data, object)
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
  end
end
