# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.UserViewTest do
  use Pleroma.DataCase, async: true
  import Pleroma.Factory

  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.ActivityPub.UserView
  alias Pleroma.Web.CommonAPI

  test "Renders a user, including the public key" do
    user = insert(:user, raw_bio: "plain profile source")

    result = UserView.render("user.json", %{user: user})

    assert result["id"] == user.ap_id
    assert result["preferredUsername"] == user.nickname
    assert result["_misskey_summary"] == "plain profile source"
    assert result["attributionDomains"] == [Pleroma.Web.WebFinger.domain()]
    assert "https://w3id.org/fep/844e" in result["@context"]

    assert result["generator"] == %{
             "type" => "Application",
             "name" => "Unfathomably",
             "implements" => [
               %{
                 "href" => "https://datatracker.ietf.org/doc/html/rfc9421",
                 "name" => "RFC-9421: HTTP Message Signatures"
               }
             ]
           }

    public_key = result["publicKey"]["publicKeyPem"]

    assert String.starts_with?(public_key, "-----BEGIN PUBLIC KEY-----\n")
    assert String.ends_with?(public_key, "-----END PUBLIC KEY-----\n")
    refute String.ends_with?(public_key, "-----END PUBLIC KEY-----\n\n")
  end

  test "does not render an empty Misskey profile summary" do
    user = insert(:user, raw_bio: "")

    result = UserView.render("user.json", %{user: user})

    refute Map.has_key?(result, "_misskey_summary")
  end

  test "restricted actors expose key and routing metadata without profile data" do
    user =
      insert(:user,
        name: "Private display name",
        bio: "Private profile text",
        raw_bio: "Private profile source",
        fields: [%{"name" => "private", "value" => "field"}],
        avatar: %{"url" => [%{"href" => "https://example.com/avatar.png"}]}
      )

    result = UserView.render("restricted_user.json", %{user: user})

    assert result["id"] == user.ap_id
    assert result["preferredUsername"] == user.nickname
    assert result["inbox"] == "#{user.ap_id}/inbox"
    assert result["outbox"] == "#{user.ap_id}/outbox"
    assert result["endpoints"] |> Map.keys() == ["sharedInbox"]
    assert String.starts_with?(result["publicKey"]["publicKeyPem"], "-----BEGIN PUBLIC KEY-----")

    for key <- [
          "name",
          "summary",
          "attachment",
          "tag",
          "icon",
          "image",
          "published",
          "generator",
          "_misskey_summary"
        ] do
      refute Map.has_key?(result, key)
    end
  end

  test "renders the marketplace service actor with its public instance handle" do
    {:ok, user} = Marketplace.service_actor()

    result = UserView.render("user.json", %{user: user})

    assert result["preferredUsername"] == Marketplace.service_actor_webfinger_nickname()

    assert result["webfinger"] ==
             "acct:#{Marketplace.service_actor_webfinger_nickname()}@#{Pleroma.Web.WebFinger.domain()}"
  end

  test "service actors advertise tested RFC 9421 support through FEP-844e" do
    user = insert(:user)

    result = UserView.render("service.json", %{user: user})

    assert "https://w3id.org/fep/844e" in result["@context"]

    assert result["implements"] == [
             %{
               "href" => "https://datatracker.ietf.org/doc/html/rfc9421",
               "name" => "RFC-9421: HTTP Message Signatures"
             }
           ]
  end

  test "the LitePub context defines WebFinger without a remote context dependency" do
    %{"@context" => context} =
      "priv/static/schemas/litepub-0.1.jsonld"
      |> File.read!()
      |> Jason.decode!()

    refute "https://purl.archive.org/socialweb/webfinger" in context

    assert Enum.any?(context, fn
             %{"webfinger" => "https://purl.archive.org/socialweb/webfinger#webfinger"} -> true
             _ -> false
           end)

    assert MIME.from_path("litepub-0.1.jsonld") == "application/ld+json"
  end

  test "round trips a multi-valued ForgeFed actor type" do
    actor_types = ["Repository", "TicketTracker", "PatchTracker"]
    user = insert(:user, local: false, actor_type: "Repository", actor_types: actor_types)

    assert %{"type" => ^actor_types} = UserView.render("user.json", %{user: user})
  end

  test "round trips Manyfold actor extensions without replacing normalized fields" do
    actor_extensions = %{
      "@context" => %{"f3di" => "http://purl.org/f3di/ns#"},
      "content" => "Native model notes",
      "f3di:concreteType" => "3DModel",
      "attachment" => [
        %{"type" => "Link", "href" => "https://example.org/model", "name" => "Model"}
      ]
    }

    user =
      insert(:user,
        local: false,
        actor_type: "Service",
        actor_types: ["Service"],
        actor_extensions: actor_extensions,
        name: "Normalized model name"
      )

    result = UserView.render("user.json", %{user: user})

    assert result["type"] == "Service"
    assert result["name"] == "Normalized model name"
    assert result["f3di:concreteType"] == "3DModel"
    assert result["content"] == "Native model notes"
    assert Enum.any?(result["attachment"], &(&1["type"] == "Link"))
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
        }
      )

    result = UserView.render("user.json", %{user: user})

    assert result["icon"]["name"] == "a drawing of pleroma-tan using pleroma groups"
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
      refute Map.has_key?(result, "attributionDomains")
      refute Map.has_key?(result, "generator")
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
  end

  describe "collection pagination" do
    test "advertises root bounds for empty follower and following collections" do
      user = insert(:user)

      assert %{
               "first" => %{"type" => "OrderedCollectionPage"},
               "last" => followers_last
             } = UserView.render("followers.json", %{user: user})

      assert followers_last == "#{user.ap_id}/followers?page=1"

      assert %{
               "first" => %{"type" => "OrderedCollectionPage"},
               "last" => following_last
             } = UserView.render("following.json", %{user: user})

      assert following_last == "#{user.ap_id}/following?page=1"
    end

    test "does not advertise an empty page after the final partial page" do
      iri = "https://example.test/users/alice/followers"
      followers = Enum.map(1..11, &%{ap_id: "https://remote.test/users/#{&1}"})

      assert %{"next" => next} = UserView.collection(followers, iri, 1)
      assert next == iri <> "?page=2"

      final_page = UserView.collection(followers, iri, 2)

      assert final_page["prev"] == iri <> "?page=1"
      refute Map.has_key?(final_page, "next")
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

# end of user_view_test.exs
