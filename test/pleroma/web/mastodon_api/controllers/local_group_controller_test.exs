# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.LocalGroupControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.GroupMembership
  alias Pleroma.User

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "POST /api/v1/groups" do
    setup do: oauth_access(["write", "write:accounts", "read:accounts", "read:follows"])

    test "creates a local ActivityPub Group actor that the creator has joined", %{
      conn: conn,
      user: user
    } do
      assert %{
               "actor_type" => "Group",
               "display_name" => "3D Printing",
               "locked" => false,
               "relationship" => %{"member" => true, "role" => "owner"},
               "target_profile" => "activitypub_group"
             } =
               response =
               conn
               |> post("/api/v1/groups", %{
                 display_name: "3D Printing",
                 note: "Printers, filament, and tiny calibration cubes.",
                 discoverable: true
               })
               |> json_response(200)

      assert %User{actor_type: "Group", local: true} =
               group =
               User.get_cached_by_id(response["id"])

      assert String.ends_with?(group.ap_id, "/users/3d_printing")
      assert User.following?(user, group)
      assert %GroupMembership{role: "owner", state: "active"} = GroupMembership.get(group, user)
    end

    test "creates a closed group that requires moderator approval", %{conn: conn, user: user} do
      assert %{
               "actor_type" => "Group",
               "locked" => true,
               "membership_required" => true,
               "relationship" => %{"member" => true, "role" => "owner"}
             } =
               response =
               conn
               |> post("/api/v1/groups", %{
                 display_name: "Quiet Workshop",
                 group_visibility: "members_only"
               })
               |> json_response(200)

      assert %User{is_locked: true} = group = User.get_cached_by_id(response["id"])
      assert %GroupMembership{role: "owner", state: "active"} = GroupMembership.get(group, user)
    end
  end
end
