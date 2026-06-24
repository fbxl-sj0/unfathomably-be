# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CommonFixesTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes

  test "leaves activity addressing alone when the actor is not cached" do
    activity = %{
      "actor" => "https://remote.example/users/missing",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => []
    }

    assert CommonFixes.fix_activity_addressing(activity) == activity
  end

  test "uses stable object fields when an object has no explicit context" do
    object = %Object{data: %{"id" => "https://remote.example/objects/1"}}

    assert %{"context" => "https://remote.example/objects/1"} =
             CommonFixes.fix_activity_context(%{}, object)
  end

  test "leaves activity context alone when no object context can be inferred" do
    assert %{} = CommonFixes.fix_activity_context(%{}, nil)
  end

  test "leaves recipients alone when the acted-on object has no actor" do
    activity = %{
      "actor" => "https://remote.example/users/alice",
      "to" => [],
      "cc" => []
    }

    tombstone = %Object{
      data: %{
        "id" => "https://remote.example/objects/deleted",
        "type" => "Tombstone"
      }
    }

    assert ^activity = CommonFixes.fix_object_action_recipients(activity, tombstone)
  end
end
