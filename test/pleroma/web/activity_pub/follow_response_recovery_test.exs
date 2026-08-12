# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.FollowResponseRecoveryTest do
  use Pleroma.DataCase, async: false

  import Ecto.Query
  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.FollowingRelationship
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.SideEffects

  test "reprocessing an incoming Follow reuses one stable Accept activity" do
    follower = insert(:user, local: false)
    followed = insert(:user, local: true, is_locked: false)

    {:ok, follow_data, _meta} = Builder.follow(follower, followed)

    follow_data =
      Map.put(
        follow_data,
        "id",
        "https://remote.example/activities/follow-retry"
      )

    {:ok, follow, _meta} = ActivityPub.persist(follow_data, local: false)
    {:ok, accept_data, _meta} = Builder.accept(followed, follow)

    assert {:ok, %Activity{}, _meta} = SideEffects.handle(follow)
    assert {:ok, %Activity{}, _meta} = SideEffects.handle(follow)

    assert %FollowingRelationship{state: :follow_accept} =
             FollowingRelationship.get(follower, followed)

    response_count =
      from(activity in Activity,
        where: fragment("?->>'id' = ?", activity.data, ^accept_data["id"])
      )
      |> Repo.aggregate(:count)

    assert response_count == 1

    assert %Activity{data: %{"object" => object_id, "type" => "Accept"}} =
             Activity.get_by_ap_id(accept_data["id"])

    assert object_id == follow.data["id"]
  end
end

# end of test/pleroma/web/activity_pub/follow_response_recovery_test.exs
