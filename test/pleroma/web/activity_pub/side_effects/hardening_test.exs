# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.SideEffects.HardeningTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.SideEffects

  describe "malformed or embedded activity targets" do
    test "Delete Tombstones are accepted as no-op side effects" do
      activity = %{
        data: %{
          "id" => "https://remote.example/activities/delete-tombstone",
          "type" => "Delete",
          "actor" => "https://remote.example/users/alice",
          "object" => %{
            "id" => "https://remote.example/objects/deleted",
            "type" => "Tombstone"
          }
        }
      }

      assert {:ok, ^activity, %{}} = SideEffects.handle(activity, %{})
    end

    test "Like with an embedded or missing target does not raise" do
      activity = %{
        data: %{
          "id" => "https://remote.example/activities/like",
          "type" => "Like",
          "actor" => "https://remote.example/users/alice",
          "object" => %{"id" => "https://remote.example/objects/missing", "type" => "Note"}
        }
      }

      assert {:ok, ^activity, %{}} = SideEffects.handle(activity, %{})
    end

    test "EmojiReact with an embedded or missing target does not raise" do
      activity = %{
        data: %{
          "id" => "https://remote.example/activities/react",
          "type" => "EmojiReact",
          "actor" => "https://remote.example/users/alice",
          "content" => ":like:",
          "object" => %{"id" => "https://remote.example/objects/missing", "type" => "Note"}
        }
      }

      assert {:ok, ^activity, %{}} = SideEffects.handle(activity, %{})
    end

    test "Announce wrapping an embedded relay activity does not raise" do
      activity = %{
        data: %{
          "id" => "https://remote.example/activities/announce",
          "type" => "Announce",
          "actor" => "https://remote.example/c/main",
          "object" => %{
            "id" => "https://remote.example/activities/like",
            "type" => "Like",
            "actor" => "https://remote.example/users/alice",
            "object" => "https://remote.example/posts/1"
          }
        }
      }

      assert {:ok, ^activity, %{}} = SideEffects.handle(activity, %{})
    end

    test "Undo with a malformed target does not raise" do
      activity = %{
        data: %{
          "id" => "https://remote.example/activities/undo",
          "type" => "Undo",
          "actor" => "https://remote.example/users/alice",
          "object" => %{"type" => "Like"}
        }
      }

      assert {:ok, ^activity, %{}} = SideEffects.handle(activity, %{})
    end

    test "Join with a missing target does not raise" do
      activity = %{
        data: %{
          "id" => "https://remote.example/activities/join",
          "type" => "Join",
          "actor" => "https://remote.example/users/alice",
          "object" => "https://remote.example/events/missing",
          "to" => ["https://remote.example/events/missing"],
          "cc" => []
        }
      }

      assert {:ok, ^activity, %{}} = SideEffects.handle(activity, %{})
    end
  end
end
