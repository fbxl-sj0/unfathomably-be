# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.FederatedTargetFollowStateTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.FollowingRelationship
  alias Pleroma.Web.FederatedTarget

  import Pleroma.Factory

  test "followed Worlds surfaces include accepted relationships only" do
    user = insert(:user, local: true, is_active: true)

    accepted_group = group("accepted")
    pending_group = group("pending")
    rejected_group = group("rejected")

    accepted_source = source("accepted")
    pending_source = source("pending")
    rejected_source = source("rejected")

    assert {:ok, _, _} = FollowingRelationship.follow(user, accepted_group, :follow_accept)
    assert {:ok, _, _} = FollowingRelationship.follow(user, pending_group, :follow_pending)
    assert {:ok, _, _} = FollowingRelationship.follow(user, rejected_group, :follow_reject)

    assert {:ok, _, _} = FollowingRelationship.follow(user, accepted_source, :follow_accept)
    assert {:ok, _, _} = FollowingRelationship.follow(user, pending_source, :follow_pending)
    assert {:ok, _, _} = FollowingRelationship.follow(user, rejected_source, :follow_reject)

    assert FederatedTarget.followed_group_ap_ids(user) == [accepted_group.ap_id]
    assert FederatedTarget.followed_source_ap_ids(user) == [accepted_source.ap_id]
    assert Enum.map(FederatedTarget.list_groups(user, %{}), & &1.id) == [accepted_group.id]
    assert Enum.map(FederatedTarget.list_sources(user, %{}), & &1.id) == [accepted_source.id]

    assert FederatedTarget.followed_rss_source?(accepted_source)
    refute FederatedTarget.followed_rss_source?(pending_source)
    refute FederatedTarget.followed_rss_source?(rejected_source)
  end

  defp group(label) do
    insert(:user,
      actor_type: "Group",
      local: false,
      nickname: "#{label}@groups.example",
      ap_id: "https://groups.example/c/#{label}"
    )
  end

  defp source(label) do
    insert(:user,
      actor_type: "Service",
      local: false,
      nickname: "rss-#{label}@feeds.example",
      ap_id: "https://feeds.example/#{label}.rss"
    )
  end
end

# end of test/pleroma/web/federated_target_follow_state_test.exs
