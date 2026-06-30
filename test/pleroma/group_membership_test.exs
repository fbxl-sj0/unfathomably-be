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
end

# end of group_membership_test.exs
