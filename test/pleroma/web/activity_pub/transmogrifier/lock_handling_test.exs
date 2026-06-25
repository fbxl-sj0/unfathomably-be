# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.LockHandlingTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Transmogrifier

  test "it handles Mbin-style Lock and Undo Lock activities" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://mbin.example/u/alice",
        follower_address: "https://mbin.example/u/alice/followers"
      )

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://mbin.example/m/main",
        follower_address: "https://mbin.example/m/main/followers"
      )

    object_id = "https://mbin.example/m/main/t/1"

    create = %{
      "id" => "https://mbin.example/activities/create/1",
      "actor" => actor.ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.ap_id],
      "type" => "Create",
      "object" => %{
        "type" => "Page",
        "id" => object_id,
        "actor" => actor.ap_id,
        "attributedTo" => actor.ap_id,
        "to" => [Pleroma.Constants.as_public()],
        "cc" => [group.ap_id],
        "name" => "A locked Mbin thread",
        "content" => "<p>Thread body</p>",
        "commentsEnabled" => true,
        "mediaType" => "text/html",
        "published" => "2026-06-24T00:00:00Z"
      }
    }

    assert {:ok, _activity} = Transmogrifier.handle_incoming(create)
    assert Object.get_by_ap_id(object_id).data["commentsEnabled"] == true

    lock = %{
      "id" => "https://mbin.example/activities/lock/1",
      "actor" => actor.ap_id,
      "object" => object_id,
      "type" => "Lock",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.ap_id]
    }

    assert {:ok, _activity} = Transmogrifier.handle_incoming(lock)
    assert Object.get_by_ap_id(object_id).data["commentsEnabled"] == false

    undo = %{
      "id" => "https://mbin.example/activities/undo-lock/1",
      "actor" => actor.ap_id,
      "object" => lock,
      "type" => "Undo",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.ap_id]
    }

    assert {:ok, _activity} = Transmogrifier.handle_incoming(undo)
    assert Object.get_by_ap_id(object_id).data["commentsEnabled"] == true
  end
end
