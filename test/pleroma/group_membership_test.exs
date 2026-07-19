# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.GroupMembershipTest do
  use Pleroma.DataCase, async: true

  import Ecto.Query
  import Pleroma.Factory

  alias Pleroma.GroupMembership
  alias Pleroma.Repo

  test "owner membership upserts remain idempotent" do
    group = insert(:user, actor_type: "Group", local: true)
    account = insert(:user)

    assert {:ok, first_membership} = GroupMembership.ensure_owner(group, account)
    assert {:ok, second_membership} = GroupMembership.ensure_owner(group, account)

    assert first_membership.id == second_membership.id

    assert 1 =
             Repo.aggregate(
               from(m in GroupMembership,
                 where: m.group_id == ^group.id and m.account_id == ^account.id
               ),
               :count,
               :id
             )

    assert %GroupMembership{role: "owner", state: "active"} =
             GroupMembership.get(group, account)
  end

  test "federated Follow synchronization preserves managers and bans" do
    group = insert(:user, actor_type: "Group", local: true)
    owner = insert(:user)
    moderator = insert(:user)
    banned_account = insert(:user)

    assert {:ok, _membership} = GroupMembership.ensure_owner(group, owner)

    assert {:ok, _membership} =
             GroupMembership.sync_federated_follow(group, moderator, "active")

    assert {:ok, [_membership]} =
             GroupMembership.promote(owner, group, [moderator], "moderator")

    assert {:ok, %GroupMembership{role: "moderator", state: "active"}} =
             GroupMembership.sync_federated_follow(group, moderator, "pending")

    assert {:ok, %GroupMembership{role: "moderator", state: "active"}} =
             GroupMembership.sync_federated_unfollow(group, moderator)

    assert {:ok, [%GroupMembership{state: "banned"}]} =
             GroupMembership.ban(owner, group, [banned_account])

    assert {:error, :banned} =
             GroupMembership.validate_federated_follow(group, banned_account)

    assert {:error, :banned} =
             GroupMembership.sync_federated_follow(group, banned_account, "active")

    assert {:ok, %GroupMembership{state: "banned"}} =
             GroupMembership.sync_federated_unfollow(group, banned_account)
  end
end

# end of group_membership_test.exs
