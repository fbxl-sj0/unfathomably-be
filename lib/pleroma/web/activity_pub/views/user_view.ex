# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.UserView do
  use Pleroma.Web, :view

  alias Pleroma.Keys
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CollectionViewHelper
  alias Pleroma.Web.ActivityPub.ObjectView
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.Router.Helpers

  import Ecto.Query
  require Pleroma.Constants

  def render("endpoints.json", %{user: %User{nickname: nil, local: true} = _user}) do
    %{"sharedInbox" => Helpers.activity_pub_url(Endpoint, :inbox)}
  end

  def render("endpoints.json", %{user: %User{local: true} = _user}) do
    %{
      "oauthAuthorizationEndpoint" => Helpers.o_auth_url(Endpoint, :authorize),
      "oauthRegistrationEndpoint" => Helpers.app_url(Endpoint, :create),
      "oauthTokenEndpoint" => Helpers.o_auth_url(Endpoint, :token_exchange),
      "sharedInbox" => Helpers.activity_pub_url(Endpoint, :inbox),
      "uploadMedia" => Helpers.activity_pub_url(Endpoint, :upload_media)
    }
  end

  def render("endpoints.json", _), do: %{}

  def render("service.json", %{user: user}) do
    public_key = public_key_pem(user)

    endpoints = render("endpoints.json", %{user: user})

    %{
      "id" => user.ap_id,
      "type" => "Application",
      "following" => "#{user.ap_id}/following",
      "followers" => "#{user.ap_id}/followers",
      "inbox" => "#{user.ap_id}/inbox",
      "outbox" => "#{user.ap_id}/outbox",
      "name" => "Pleroma",
      "summary" =>
        "An internal service actor for this Pleroma instance.  No user-serviceable parts inside.",
      "url" => user.ap_id,
      "manuallyApprovesFollowers" => false,
      "publicKey" => %{
        "id" => "#{user.ap_id}#main-key",
        "owner" => user.ap_id,
        "publicKeyPem" => public_key
      },
      "endpoints" => endpoints,
      "invisible" => User.invisible?(user)
    }
    |> Map.merge(Utils.make_json_ld_header())
  end

  # the instance itself is not a Person, but instead an Application
  def render("user.json", %{user: %User{nickname: nil} = user}),
    do: render("service.json", %{user: user})

  def render("user.json", %{user: %User{nickname: "internal." <> _} = user}) do
    nickname =
      user.nickname
      |> String.split("@", parts: 2)
      |> List.first()

    render("service.json", %{user: user}) |> Map.put("preferredUsername", nickname)
  end

  def render("user.json", %{user: user}) do
    public_key = public_key_pem(user)
    user = User.sanitize_html(user)

    endpoints = render("endpoints.json", %{user: user})

    emoji_tags = Transmogrifier.take_emoji_tags(user)

    fields = Enum.map(user.fields, &Map.put(&1, "type", "PropertyValue"))

    capabilities =
      if is_boolean(user.accepts_chat_messages) do
        %{
          "acceptsChatMessages" => user.accepts_chat_messages
        }
      else
        %{}
      end

    birthday =
      if user.show_birthday && user.birthday,
        do: Date.to_iso8601(user.birthday),
        else: nil

    %{
      "id" => user.ap_id,
      "type" => user.actor_type,
      "following" => "#{user.ap_id}/following",
      "followers" => "#{user.ap_id}/followers",
      "inbox" => "#{user.ap_id}/inbox",
      "outbox" => "#{user.ap_id}/outbox",
      "featured" => "#{user.ap_id}/collections/featured",
      "featuredCollections" => "#{user.ap_id}/collections",
      "preferredUsername" => user.nickname,
      "name" => user.name,
      "summary" => user.bio,
      "url" => user.ap_id,
      "manuallyApprovesFollowers" => user.is_locked,
      "publicKey" => %{
        "id" => "#{user.ap_id}#main-key",
        "owner" => user.ap_id,
        "publicKeyPem" => public_key
      },
      "endpoints" => endpoints,
      "attachment" => fields,
      "tag" => emoji_tags,
      # Note: key name is indeed "discoverable" (not an error)
      "discoverable" => user.is_discoverable,
      "capabilities" => capabilities,
      "alsoKnownAs" => user.also_known_as,
      "interactionPolicy" => feature_interaction_policy(user),
      "vcard:bday" => birthday,
      "vcard:Address" => user.location
    }
    |> maybe_put_misskey_summary(user.raw_bio)
    |> Map.merge(
      maybe_make_image(&User.avatar_url/2, User.image_description(user.avatar, nil), "icon", user)
    )
    |> Map.merge(
      maybe_make_image(
        &User.banner_url/2,
        User.image_description(user.banner, nil),
        "image",
        user
      )
    )
    |> Map.merge(Utils.make_json_ld_header())
    |> add_fep_7aa9_context()
  end

  def render("following.json", %{user: user, page: page} = opts) do
    showing_items = (opts[:for] && opts[:for] == user) || !user.hide_follows
    showing_count = showing_items || !user.hide_follows_count

    {following_page, total} =
      cond do
        showing_items ->
          page_items =
            user
            |> User.get_friends_query()
            |> select([u], [:ap_id])
            |> User.Query.paginate(page, 10)
            |> Repo.all()

          {page_items, if(showing_count, do: user.following_count, else: 0)}

        showing_count ->
          {[], user.following_count}

        true ->
          {[], 0}
      end

    CollectionViewHelper.collection_page_offset(
      following_page,
      "#{user.ap_id}/following",
      page,
      showing_items,
      total
    )
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("following.json", %{user: user} = opts) do
    showing_items = (opts[:for] && opts[:for] == user) || !user.hide_follows
    showing_count = showing_items || !user.hide_follows_count

    total = if showing_count, do: user.following_count, else: 0

    first_page =
      if showing_items do
        user
        |> User.get_friends_query()
        |> select([u], [:ap_id])
        |> User.Query.paginate(1, 10)
        |> Repo.all()
      else
        []
      end

    %{
      "id" => "#{user.ap_id}/following",
      "type" => "OrderedCollection",
      "totalItems" => total,
      "first" =>
        if showing_items do
          CollectionViewHelper.collection_page_offset(
            first_page,
            "#{user.ap_id}/following",
            1,
            !user.hide_follows,
            total
          )
        else
          "#{user.ap_id}/following?page=1"
        end
    }
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("followers.json", %{user: user, page: page} = opts) do
    showing_items = (opts[:for] && opts[:for] == user) || !user.hide_followers
    showing_count = showing_items || !user.hide_followers_count

    {followers_page, total} =
      cond do
        showing_items ->
          page_items =
            user
            |> User.get_followers_query()
            |> select([u], [:ap_id])
            |> User.Query.paginate(page, 10)
            |> Repo.all()

          {page_items, if(showing_count, do: user.follower_count, else: 0)}

        showing_count ->
          {[], user.follower_count}

        true ->
          {[], 0}
      end

    CollectionViewHelper.collection_page_offset(
      followers_page,
      "#{user.ap_id}/followers",
      page,
      showing_items,
      total
    )
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("followers.json", %{user: user} = opts) do
    showing_items = (opts[:for] && opts[:for] == user) || !user.hide_followers
    showing_count = showing_items || !user.hide_followers_count

    total = if showing_count, do: user.follower_count, else: 0

    first_page =
      if showing_items do
        user
        |> User.get_followers_query()
        |> select([u], [:ap_id])
        |> User.Query.paginate(1, 10)
        |> Repo.all()
      else
        []
      end

    %{
      "id" => "#{user.ap_id}/followers",
      "type" => "OrderedCollection",
      "first" =>
        if showing_items do
          CollectionViewHelper.collection_page_offset(
            first_page,
            "#{user.ap_id}/followers",
            1,
            showing_items,
            total
          )
        else
          "#{user.ap_id}/followers?page=1"
        end
    }
    |> maybe_put_total_items(showing_count, total)
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("activity_collection.json", %{iri: iri}) do
    %{
      "id" => iri,
      "type" => "OrderedCollection",
      "first" => "#{iri}?page=true"
    }
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("activity_collection_page.json", %{
        activities: activities,
        iri: iri,
        pagination: pagination
      }) do
    collection =
      Enum.map(activities, fn activity ->
        {:ok, data} = Transmogrifier.prepare_outgoing(activity.data)
        data
      end)

    %{
      "type" => "OrderedCollectionPage",
      "partOf" => iri,
      "orderedItems" => collection
    }
    |> Map.merge(Utils.make_json_ld_header())
    |> Map.merge(pagination)
  end

  def render("featured.json", %{
        user: %{featured_address: featured_address, pinned_objects: pinned_objects}
      }) do
    objects =
      pinned_objects
      |> Enum.sort_by(fn {_, pinned_at} -> pinned_at end, &>=/2)
      |> Enum.map(fn {id, _} ->
        ObjectView.render("object.json", %{object: Object.get_cached_by_ap_id(id)})
      end)

    %{
      "id" => featured_address,
      "type" => "OrderedCollection",
      "orderedItems" => objects,
      "totalItems" => length(objects)
    }
    |> Map.merge(Utils.make_json_ld_header())
    |> add_fep_7aa9_context()
  end

  def render("featured_collections.json", %{user: user, page: page}) do
    %{
      "id" => "#{user.ap_id}/collections?page=#{page}",
      "type" => "CollectionPage",
      "partOf" => "#{user.ap_id}/collections",
      "totalItems" => 1,
      "items" => [User.ap_featured_collection(user)]
    }
    |> Map.merge(Utils.make_json_ld_header())
    |> add_fep_7aa9_context()
  end

  def render("featured_collections.json", %{user: user}) do
    %{
      "id" => "#{user.ap_id}/collections",
      "type" => "Collection",
      "totalItems" => 1,
      "first" => "#{user.ap_id}/collections?page=1"
    }
    |> Map.merge(Utils.make_json_ld_header())
    |> add_fep_7aa9_context()
  end

  defp maybe_put_total_items(map, false, _total), do: map

  defp maybe_put_total_items(map, true, total) do
    Map.put(map, "totalItems", total)
  end

  defp maybe_put_misskey_summary(data, raw_bio) when is_binary(raw_bio) and raw_bio != "" do
    Map.put(data, "_misskey_summary", raw_bio)
  end

  defp maybe_put_misskey_summary(data, _raw_bio), do: data

  defp public_key_pem(%User{keys: keys}) do
    {:ok, _, public_key} = Keys.keys_from_pem(keys)

    public_key = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)

    public_key
    |> List.wrap()
    |> :public_key.pem_encode()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp maybe_make_image(func, description, key, user) do
    if image = func.(user, no_default: true) do
      %{
        key =>
          %{
            "type" => "Image",
            "url" => image
          }
          |> maybe_put_description(description)
      }
    else
      %{}
    end
  end

  defp maybe_put_description(map, description) when is_binary(description) do
    map
    |> Map.put("name", description)
    |> Map.put("summary", description)
  end

  defp maybe_put_description(map, _description), do: map

  defp feature_interaction_policy(%User{} = user) do
    %{
      "canFeature" => %{
        "automaticApproval" => [feature_approval_uri(user)]
      }
    }
  end

  defp feature_approval_uri(%User{is_locked: true} = user), do: User.ap_followers(user)
  defp feature_approval_uri(%User{is_discoverable: false} = user), do: user.ap_id
  defp feature_approval_uri(%User{}), do: Pleroma.Constants.as_public()

  defp add_fep_7aa9_context(%{"@context" => context} = map) when is_list(context) do
    Map.put(map, "@context", context ++ [fep_7aa9_context()])
  end

  defp add_fep_7aa9_context(map), do: map

  defp fep_7aa9_context do
    %{
      "FeaturedCollection" => "https://w3id.org/fep/7aa9#FeaturedCollection",
      "FeaturedItem" => "https://w3id.org/fep/7aa9#FeaturedItem",
      "FeatureAuthorization" => "https://w3id.org/fep/7aa9#FeatureAuthorization",
      "FeatureRequest" => "https://w3id.org/fep/7aa9#FeatureRequest",
      "automaticApproval" => %{
        "@id" => "https://gotosocial.org/ns#automaticApproval",
        "@type" => "@id"
      },
      "canFeature" => %{"@id" => "https://w3id.org/fep/7aa9#canFeature", "@type" => "@id"},
      "featureAuthorization" => %{
        "@id" => "https://w3id.org/fep/7aa9#featureAuthorization",
        "@type" => "@id"
      },
      "featuredCollections" => %{
        "@id" => "https://w3id.org/fep/7aa9#featuredCollections",
        "@type" => "@id"
      },
      "featuredObject" => %{"@id" => "https://w3id.org/fep/7aa9#featuredObject", "@type" => "@id"},
      "interactionPolicy" => %{
        "@id" => "https://gotosocial.org/ns#interactionPolicy",
        "@type" => "@id"
      },
      "manualApproval" => %{"@id" => "https://gotosocial.org/ns#manualApproval", "@type" => "@id"},
      "topic" => %{"@id" => "https://w3id.org/fep/7aa9#topic", "@type" => "@id"}
    }
  end
end
