# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ActivityPubIdempotencyTest do
  use Pleroma.DataCase, async: true

  require Pleroma.Constants

  alias Pleroma.Web.ActivityPub.ActivityPub

  import Pleroma.Factory

  test "persist/2 returns the existing activity on duplicate AP IDs" do
    actor = insert(:user)

    data = %{
      "id" => "https://remote.example/activities/duplicate",
      "type" => "Announce",
      "actor" => actor.ap_id,
      "object" => "https://remote.example/objects/duplicate",
      "to" => [Pleroma.Constants.as_public()]
    }

    assert {:ok, first_activity, _meta} = ActivityPub.persist(data, local: false)
    assert {:ok, second_activity, _meta} = ActivityPub.persist(data, local: false)

    assert second_activity.id == first_activity.id
  end

  test "persist/2 returns the existing Create activity on duplicate AP IDs" do
    actor = insert(:user)

    data = %{
      "id" => "https://remote.example/activities/create-duplicate",
      "type" => "Create",
      "actor" => actor.ap_id,
      "object" => "https://remote.example/objects/create-duplicate",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => []
    }

    assert {:ok, first_activity, _meta} = ActivityPub.persist(data, local: false)
    assert {:ok, second_activity, _meta} = ActivityPub.persist(data, local: false)

    assert second_activity.id == first_activity.id
  end

  test "persist/2 normalizes malformed and duplicate non-Create recipients" do
    actor = insert(:user)

    direct = "https://remote.example/users/direct"
    cc = "https://remote.example/users/cc"
    bcc = "https://remote.example/users/bcc"
    audience = "https://remote.example/c/main"
    nested = "https://remote.example/users/nested"

    data = %{
      "id" => "https://remote.example/activities/recipient-shapes",
      "type" => "Like",
      "actor" => actor.ap_id,
      "object" => %{
        "id" => "https://remote.example/objects/recipient-shapes",
        "to" => [%{"href" => nested}, %{"bad" => "shape"}],
        "cc" => [nested]
      },
      "to" => [direct, %{"id" => direct}, nil, %{"bad" => "shape"}],
      "cc" => %{"href" => cc},
      "bcc" => [bcc, %{"id" => bcc}],
      "audience" => %{"id" => audience}
    }

    assert {:ok, activity, _meta} = ActivityPub.persist(data, local: false)

    assert Enum.sort(activity.recipients) == Enum.sort([direct, cc, bcc, audience, nested])
  end
end
