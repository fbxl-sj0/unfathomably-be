# Unfathomably BE
# ----------------
#
# File: marketplace_test.exs
#
# Purpose:
#   Cover the opt-in boundary for specialised marketplace federation.
#
# Responsibilities:
#   - require explicit author consent before a local offer becomes a
#     Flohmarkt-compatible delivery payload
#   - preserve the normal public-offer metadata required by the adapter
#
# This file intentionally does NOT contact a remote marketplace server.

defmodule Pleroma.Web.ActivityPub.MarketplaceTest do
  use Pleroma.DataCase

  import Pleroma.Factory

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Marketplace

  @native_family "https://unfathomably.social/ns#family"

  test "requires explicit marketplace delivery consent" do
    seller = insert(:user)
    object = %Object{data: listing_data(seller, false)}

    assert {:error, :not_marketplace_listing} = Marketplace.flohmarkt_object(object, seller)

    object = %Object{data: listing_data(seller, true)}

    assert {:ok, listing} = Marketplace.flohmarkt_object(object, seller)
    assert listing["flohmarkt:data"]["currency"] == "CAD"
    assert listing["flohmarkt:data"]["price"] == "25.00"
    assert listing["tag"] == [%{"name" => "#radio", "type" => "Hashtag"}]

    assert %{
             "publishes" => %{
               "resourceQuantity" => %{"hasNumericalValue" => "1", "hasUnit" => "one"}
             },
             "type" => "Proposal"
           } = List.last(listing["attachment"])
  end

  test "translates listing revisions and closes sold listings for Flohmarkt peers" do
    seller = insert(:user)
    listing = listing_data(seller, true)

    update = %{
      "actor" => seller.ap_id,
      "id" => seller.ap_id <> "/activities/update-marketplace-test-item",
      "object" => Map.put(listing, "price", "30.00"),
      "type" => "Update"
    }

    assert {:ok, translated} = Marketplace.prepare_activity_for_marketplace(update)
    assert translated["type"] == "Update"
    assert translated["object"]["flohmarkt:data"]["price"] == "30.00"

    sold = put_in(update, ["object", "state"], "sold")

    assert {:ok, translated} = Marketplace.prepare_activity_for_marketplace(sold)
    assert translated["type"] == "Delete"
    assert translated["object"]["type"] == "Tombstone"
    assert translated["object"]["id"] =~ "/users/#{seller.nickname}/items/"
  end

  defp listing_data(seller, marketplace_delivery) do
    %{
      @native_family => "markets",
      "actor" => seller.ap_id,
      "content" => "A reliable shortwave radio with a working speaker.",
      "id" => seller.ap_id <> "/objects/marketplace-test-item",
      "latitude" => "43.653200",
      "listingType" => "offer",
      "longitude" => "-79.383200",
      "marketplaceDelivery" => marketplace_delivery,
      "name" => "Shortwave radio",
      "price" => "25.00",
      "priceCurrency" => "CAD",
      "published" => "2026-07-21T12:00:00Z",
      "quantity" => "1",
      "tag" => [%{"name" => "#radio", "type" => "Hashtag"}]
    }
  end
end

# end of test/pleroma/web/activity_pub/marketplace_test.exs
