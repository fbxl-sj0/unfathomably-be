# Unfathomably Backend
#
# File: aggregate_feed_membership_test.exs
#
# Purpose:
#   Cover authorization, idempotency, and isolation of aggregate Feed state.
#
# These tests intentionally exercise the projection directly; generic
# Add/Remove pipeline behavior is covered by the ActivityPub validator tests.

defmodule Pleroma.Web.ActivityPub.AggregateFeedMembershipTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  alias Pleroma.Web.ActivityPub.AggregateFeedMembership

  describe "aggregate Feed collection changes" do
    test "adds and removes Group actors idempotently" do
      feed =
        insert(:user,
          local: false,
          actor_type: "Feed",
          ap_id: "https://example.test/feeds/technology",
          following_address: "https://example.test/feeds/technology/following"
        )

      community =
        insert(:user,
          local: false,
          actor_type: "Group",
          ap_id: "https://community.test/c/engineering"
        )

      target = %{"type" => "Collection", "id" => feed.following_address}

      assert AggregateFeedMembership.authorized?(target, feed, community.ap_id)

      assert {:ok, _membership} =
               AggregateFeedMembership.apply_change("Add", target, feed, community.ap_id)

      assert {:ok, _membership} =
               AggregateFeedMembership.apply_change("Add", target, feed, community.ap_id)

      assert AggregateFeedMembership.member?(feed, community)
      assert [listed_community] = AggregateFeedMembership.list_communities(feed)
      assert listed_community.id == community.id

      assert %{entries: [{discovered_community, discovered_feed}], total: 1} =
               AggregateFeedMembership.search_communities("engineering", 12, 0)

      assert discovered_community.id == community.id
      assert discovered_feed.id == feed.id

      assert {:ok, nil} =
               AggregateFeedMembership.apply_change("Remove", target, feed, community.ap_id)

      assert {:ok, nil} =
               AggregateFeedMembership.apply_change("Remove", target, feed, community.ap_id)

      refute AggregateFeedMembership.member?(feed, community)
    end

    test "rejects foreign collections and non-community objects" do
      feed =
        insert(:user,
          local: false,
          actor_type: "Feed",
          ap_id: "https://example.test/feeds/technology",
          following_address: "https://example.test/feeds/technology/following"
        )

      person =
        insert(:user,
          local: false,
          actor_type: "Person",
          ap_id: "https://people.test/users/alice"
        )

      refute AggregateFeedMembership.authorized?(
               "https://attacker.test/following",
               feed,
               person.ap_id
             )

      refute AggregateFeedMembership.authorized?(feed.following_address, feed, person.ap_id)

      assert {:error, :unauthorized_aggregate_feed_change} =
               AggregateFeedMembership.apply_change(
                 "Add",
                 feed.following_address,
                 feed,
                 person.ap_id
               )
    end
  end
end

# end of test/pleroma/web/activity_pub/aggregate_feed_membership_test.exs
