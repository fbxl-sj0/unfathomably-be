# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.FollowingRelationshipTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.FollowingRelationship
  alias Pleroma.Instances
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.InternalFetchActor
  alias Pleroma.Web.ActivityPub.Relay

  import Pleroma.Factory

  describe "following/1" do
    test "returns following addresses without internal.fetch" do
      user = insert(:user)
      fetch_actor = InternalFetchActor.get_actor()
      FollowingRelationship.follow(fetch_actor, user, :follow_accept)
      assert FollowingRelationship.following(fetch_actor) == [user.follower_address]
    end

    test "returns following addresses without relay" do
      user = insert(:user)
      relay_actor = Relay.get_actor()
      FollowingRelationship.follow(relay_actor, user, :follow_accept)
      assert FollowingRelationship.following(relay_actor) == [user.follower_address]
    end

    test "returns following addresses without remote user" do
      user = insert(:user)
      actor = insert(:user, local: false)
      FollowingRelationship.follow(actor, user, :follow_accept)
      assert FollowingRelationship.following(actor) == [user.follower_address]
    end

    test "returns following addresses with local user" do
      user = insert(:user)
      actor = insert(:user, local: true)
      FollowingRelationship.follow(actor, user, :follow_accept)

      assert FollowingRelationship.following(actor) == [
               actor.follower_address,
               user.follower_address
             ]
    end

    test "refreshes cached following AP IDs after relationship changes" do
      user = insert(:user)
      followed = insert(:user)

      assert User.get_cached_user_friends_ap_ids(user) == []

      FollowingRelationship.follow(user, followed, :follow_accept)
      assert User.get_cached_user_friends_ap_ids(user) == [followed.ap_id]

      FollowingRelationship.unfollow(user, followed)
      assert User.get_cached_user_friends_ap_ids(user) == []
    end
  end

  describe "dormant instance filtering" do
    setup do
      clear_config([:instance, :dormant_instance_timeout_days], 1)
    end

    test "hides followers and following entries from dormant remote instances" do
      user = insert(:user)

      active_remote =
        insert(:user,
          local: false,
          nickname: "active@active.example",
          ap_id: "https://active.example/users/active",
          follower_address: "https://active.example/users/active/followers"
        )

      dormant_remote =
        insert(:user,
          local: false,
          nickname: "dormant@dormant.example",
          ap_id: "https://dormant.example/users/dormant",
          follower_address: "https://dormant.example/users/dormant/followers"
        )

      FollowingRelationship.follow(active_remote, user, :follow_accept)
      FollowingRelationship.follow(dormant_remote, user, :follow_accept)
      FollowingRelationship.follow(user, active_remote, :follow_accept)
      FollowingRelationship.follow(user, dormant_remote, :follow_accept)

      Instances.set_unreachable("dormant.example", Instances.dormant_datetime_threshold())

      assert FollowingRelationship.follower_count(user) == 1
      assert FollowingRelationship.following_count(user) == 1
      assert FollowingRelationship.followers_ap_ids(user) == [active_remote.ap_id]

      assert Enum.sort(FollowingRelationship.following(user)) ==
               Enum.sort([user.follower_address, active_remote.follower_address])
    end
  end
end
