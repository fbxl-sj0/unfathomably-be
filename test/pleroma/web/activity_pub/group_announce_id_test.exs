# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.GroupAnnounceIdTest do
  use Pleroma.DataCase, async: true

  require Pleroma.Constants

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Web.ActivityPub.Builder

  test "a local Group derives one Announce ID for a canonical activity" do
    group = insert(:user, local: true, actor_type: "Group")

    object = %Activity{
      actor: "https://remote.example/users/author",
      data: %{
        "actor" => "https://remote.example/users/author",
        "context" => "https://remote.example/contexts/1",
        "id" => "https://remote.example/activities/1",
        "to" => [Pleroma.Constants.as_public()],
        "type" => "Create"
      }
    }

    assert {:ok, first, _meta} = Builder.announce(group, object, public: true)
    assert {:ok, second, _meta} = Builder.announce(group, object, public: true)

    assert first["id"] == second["id"]
    assert first["object"] == object.data["id"]
    assert first["actor"] == group.ap_id
  end
end

# end of test/pleroma/web/activity_pub/group_announce_id_test.exs
