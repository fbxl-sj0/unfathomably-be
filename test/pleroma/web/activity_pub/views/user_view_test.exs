# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.UserViewTest do
  use Pleroma.DataCase, async: true
  import Pleroma.Factory

  alias Pleroma.FollowingRelationship
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.UserView
  alias Pleroma.Web.CommonAPI

  require Pleroma.Constants

  test "Renders a user, including the public key" do
    user = insert(:user, raw_bio: "plain profile source")

    result = UserView.render("user.json", %{user: user})

    assert result["id"] == user.ap_id
    assert result["preferredUsername"] == user.nickname
    assert result["_misskey_summary"] == "plain profile source"

    public_key = result["publicKey"]["publicKeyPem"]

    assert String.starts_with?(public_key, "-----BEGIN PUBLIC KEY-----\n")
    assert String.ends_with?(public_key, "-----END PUBLIC KEY-----\n")
    refute String.ends_with?(public_key, "-----END PUBLIC KEY-----\n\n")
  end

  test "renders FEP-7aa9 featured collection hints" do
    user = insert(:user, is_discoverable: true)

    result = UserView.render("user.json", %{user: user})

    assert result["featuredCollections"] == "#{user.ap_id}/collections"

    assert result["interactionPolicy"] == %{
             "canFeature" => %{
               "automaticApproval" => [Pleroma.Constants.as_public()]
             }
           }

    assert Enum.any?(result["@context"], fn
             %{"featuredCollections" => _, "canFeature" => _} -> true
             _ -> false
           end)
  end

  test "renders conservative FEP-7aa9 feature policies for locked and undiscoverable users" do
    locked_user = insert(:user, is_discoverable: true, is_locked: true)
    undiscoverable_user = insert(:user, is_discoverable: false)
    locked_followers = locked_user.follower_address
    undiscoverable_ap_id = undiscoverable_user.ap_id

    assert %{
             "interactionPolicy" => %{
               "canFeature" => %{"automaticApproval" => [^locked_followers]}
             }
           } = UserView.render("user.json", %{user: locked_user})

    assert %{
             "interactionPolicy" => %{
               "canFeature" => %{"automaticApproval" => [^undiscoverable_ap_id]}
             }
           } = UserView.render("user.json", %{user: undiscoverable_user})
  end

  test "renders a FEP-7aa9 collection index for local pinned posts" do
    user = insert(:user)

    assert %{
             "id" => collections_id,
             "type" => "Collection",
             "totalItems" => 1,
             "first" => first
           } = UserView.render("featured_collections.json", %{user: user})

    assert collections_id == "#{user.ap_id}/collections"
    assert first == "#{user.ap_id}/collections?page=1"

    assert %{
             "id" => page_id,
             "type" => "CollectionPage",
             "partOf" => ^collections_id,
             "totalItems" => 1,
             "items" => [featured_address]
           } = UserView.render("featured_collections.json", %{user: user, page: 1})

    assert page_id == first
    assert featured_address == user.featured_address
  end

  test "does not render an empty Misskey profile summary" do
    user = insert(:user, raw_bio: "")

    result = UserView.render("user.json", %{user: user})

    refute Map.has_key?(result, "_misskey_summary")
  end

  test "Renders profile fields" do
    fields = [
      %{"name" => "foo", "value" => "bar"}
    ]

    {:ok, user} =
      insert(:user)
      |> User.update_changeset(%{fields: fields})
      |> User.update_and_set_cache()

    assert %{
             "attachment" => [%{"name" => "foo", "type" => "PropertyValue", "value" => "bar"}]
           } = UserView.render("user.json", %{user: user})
  end

  test "Renders with emoji tags" do
    user = insert(:user, emoji: %{"bib" => "/test"})

    assert %{
             "tag" => [
               %{
                 "icon" => %{"type" => "Image", "url" => "/test"},
                 "id" => "/test",
                 "name" => ":bib:",
                 "type" => "Emoji",
                 "updated" => "1970-01-01T00:00:00Z"
               }
             ]
           } = UserView.render("user.json", %{user: user})
  end

  test "Does not add an avatar image if the user hasn't set one" do
    user = insert(:user)

    result = UserView.render("user.json", %{user: user})
    refute result["icon"]
    refute result["image"]

    user =
      insert(:user,
        avatar: %{"url" => [%{"href" => "https://someurl"}]},
        banner: %{"url" => [%{"href" => "https://somebanner"}]}
      )

    result = UserView.render("user.json", %{user: user})
    assert result["icon"]["url"] == "https://someurl"
    assert result["image"]["url"] == "https://somebanner"
    refute result["icon"]["name"]
    refute result["image"]["name"]
  end

  test "Avatar has a description if the user set one" do
    user =
      insert(:user,
        avatar: %{
          "url" => [%{"href" => "https://someurl"}],
          "name" => "a drawing of pleroma-tan using pleroma groups"
        },
        banner: %{
          "url" => [%{"href" => "https://somebanner"}],
          "summary" => "a red and black skyline"
        }
      )

    result = UserView.render("user.json", %{user: user})

    assert result["icon"]["name"] == "a drawing of pleroma-tan using pleroma groups"
    assert result["icon"]["summary"] == "a drawing of pleroma-tan using pleroma groups"
    assert result["image"]["name"] == "a red and black skyline"
    assert result["image"]["summary"] == "a red and black skyline"
  end

  test "renders an invisible user with the invisible property set to true" do
    user = insert(:user, invisible: true)

    assert %{"invisible" => true} = UserView.render("service.json", %{user: user})
  end

  test "renders AKAs" do
    akas = ["https://i.tusooa.xyz/users/test-pleroma"]
    user = insert(:user, also_known_as: akas)
    assert %{"alsoKnownAs" => ^akas} = UserView.render("user.json", %{user: user})
  end

  describe "endpoints" do
    test "local users have a usable endpoints structure" do
      user = insert(:user)

      result = UserView.render("user.json", %{user: user})

      assert result["id"] == user.ap_id

      %{
        "sharedInbox" => _,
        "oauthAuthorizationEndpoint" => _,
        "oauthRegistrationEndpoint" => _,
        "oauthTokenEndpoint" => _
      } = result["endpoints"]
    end

    test "remote users have an empty endpoints structure" do
      user = insert(:user, local: false)

      result = UserView.render("user.json", %{user: user})

      assert result["id"] == user.ap_id
      assert result["endpoints"] == %{}
    end

    test "instance users do not expose oAuth endpoints" do
      user = insert(:user, nickname: nil, local: true)

      result = UserView.render("user.json", %{user: user})

      refute result["endpoints"]["oauthAuthorizationEndpoint"]
      refute result["endpoints"]["oauthRegistrationEndpoint"]
      refute result["endpoints"]["oauthTokenEndpoint"]
    end
  end

  describe "followers" do
    test "sets totalItems to zero when followers are hidden" do
      user = insert(:user)
      other_user = insert(:user)
      {:ok, _other_user, user, _activity} = CommonAPI.follow(other_user, user)
      assert %{"totalItems" => 1} = UserView.render("followers.json", %{user: user})
      user = Map.merge(user, %{hide_followers_count: true, hide_followers: true})
      refute UserView.render("followers.json", %{user: user}) |> Map.has_key?("totalItems")
    end

    test "sets correct totalItems when followers are hidden but the follower counter is not" do
      user = insert(:user)
      other_user = insert(:user)
      {:ok, _other_user, user, _activity} = CommonAPI.follow(other_user, user)
      assert %{"totalItems" => 1} = UserView.render("followers.json", %{user: user})
      user = Map.merge(user, %{hide_followers_count: false, hide_followers: true})
      assert %{"totalItems" => 1} = UserView.render("followers.json", %{user: user})
    end

    test "renders paginated follower collections from cached counts" do
      user = insert(:user)

      for _ <- 1..11 do
        follower = insert(:user)
        {:ok, _follower, _user} = FollowingRelationship.follow(follower, user, :follow_accept)
      end

      user = User.get_by_id(user.id)
      first = UserView.render("followers.json", %{user: user})["first"]

      assert first["totalItems"] == 11
      assert length(first["orderedItems"]) == 10
      assert first["next"] == "#{user.ap_id}/followers?page=2"

      second = UserView.render("followers.json", %{user: user, page: 2})

      assert second["totalItems"] == 11
      assert length(second["orderedItems"]) == 1
      refute Map.has_key?(second, "next")
    end
  end

  describe "following" do
    test "sets totalItems to zero when follows are hidden" do
      user = insert(:user)
      other_user = insert(:user)
      {:ok, user, _other_user, _activity} = CommonAPI.follow(user, other_user)
      assert %{"totalItems" => 1} = UserView.render("following.json", %{user: user})
      user = Map.merge(user, %{hide_follows_count: true, hide_follows: true})
      assert %{"totalItems" => 0} = UserView.render("following.json", %{user: user})
    end

    test "sets correct totalItems when follows are hidden but the follow counter is not" do
      user = insert(:user)
      other_user = insert(:user)
      {:ok, user, _other_user, _activity} = CommonAPI.follow(user, other_user)
      assert %{"totalItems" => 1} = UserView.render("following.json", %{user: user})
      user = Map.merge(user, %{hide_follows_count: false, hide_follows: true})
      assert %{"totalItems" => 1} = UserView.render("following.json", %{user: user})
    end

    test "renders paginated following collections from cached counts" do
      user = insert(:user)

      for _ <- 1..11 do
        followed = insert(:user)
        {:ok, _user, _followed} = FollowingRelationship.follow(user, followed, :follow_accept)
      end

      user = User.get_by_id(user.id)
      first = UserView.render("following.json", %{user: user})["first"]

      assert first["totalItems"] == 11
      assert length(first["orderedItems"]) == 10
      assert first["next"] == "#{user.ap_id}/following?page=2"

      second = UserView.render("following.json", %{user: user, page: 2})

      assert second["totalItems"] == 11
      assert length(second["orderedItems"]) == 1
      refute Map.has_key?(second, "next")
    end
  end

  describe "acceptsChatMessages" do
    test "it returns this value if it is set" do
      true_user = insert(:user, accepts_chat_messages: true)
      false_user = insert(:user, accepts_chat_messages: false)
      nil_user = insert(:user, accepts_chat_messages: nil)

      assert %{"capabilities" => %{"acceptsChatMessages" => true}} =
               UserView.render("user.json", user: true_user)

      assert %{"capabilities" => %{"acceptsChatMessages" => false}} =
               UserView.render("user.json", user: false_user)

      refute Map.has_key?(
               UserView.render("user.json", user: nil_user)["capabilities"],
               "acceptsChatMessages"
             )
    end
  end
end
