# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.UserView do
  use Pleroma.Web, :view

  require Logger
  require Pleroma.Constants

  alias Pleroma.GroupMembership
  alias Pleroma.Keys
  alias Pleroma.Keys.Multikey
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActorExtensions
  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.ActivityPub.ObjectView
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.Router.Helpers

  import Ecto.Query

  @fep_844e_context "https://w3id.org/fep/844e"
  @rfc_9421_capability %{
    "href" => "https://datatracker.ietf.org/doc/html/rfc9421",
    "name" => "RFC-9421: HTTP Message Signatures"
  }

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
      "implements" => application_capabilities(),
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
    |> add_capability_context()
    |> maybe_put_finalized_fep_fields(user)
  end

  # the instance itself is not a Person, but instead an Application
  def render("user.json", %{user: %User{nickname: nil} = user}),
    do: render("service.json", %{user: user})

  def render("user.json", %{user: %User{nickname: "internal." <> _} = user}) do
    nickname =
      user.nickname
      |> String.split("@", parts: 2)
      |> List.first()

    render("service.json", %{user: user})
    |> Map.merge(%{
      "preferredUsername" => nickname,
      "webfinger" => "acct:#{User.full_nickname(user)}"
    })
  end

  def render("restricted_user.json", %{user: %User{nickname: nil} = user}),
    do: render("service.json", %{user: user})

  def render("restricted_user.json", %{user: %User{nickname: "internal." <> _} = user}),
    do: render("user.json", %{user: user})

  # Hybrid authorized fetch exposes only the public key and delivery routes
  # needed for a peer to retry with a signature. Human-facing profile data,
  # media, fields, dates, and extension payloads remain available only after
  # the requester proves its identity.
  def render("restricted_user.json", %{user: %User{local: true} = user}) do
    endpoints =
      "endpoints.json"
      |> render(%{user: user})
      |> Map.take(["sharedInbox"])

    %{
      "id" => user.ap_id,
      "type" => actor_json_ld_type(user),
      "following" => User.ap_following(user),
      "followers" => User.ap_followers(user),
      "inbox" => "#{user.ap_id}/inbox",
      "outbox" => user.outbox_address || "#{user.ap_id}/outbox",
      "featured" => User.ap_featured_collection(user),
      "preferredUsername" => Marketplace.webfinger_nickname(user),
      "url" => user.ap_id,
      "manuallyApprovesFollowers" => user.is_locked,
      "publicKey" => %{
        "id" => "#{user.ap_id}#main-key",
        "owner" => user.ap_id,
        "publicKeyPem" => public_key_pem(user)
      },
      "endpoints" => endpoints,
      "webfinger" =>
        "acct:#{Marketplace.webfinger_nickname(user)}@#{Pleroma.Web.WebFinger.domain()}"
    }
    |> maybe_put_restricted_group_fields(user)
    |> Map.merge(Utils.make_json_ld_header())
    |> maybe_put_finalized_fep_fields(user)
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
      "type" => actor_json_ld_type(user),
      "following" => User.ap_following(user),
      "followers" => User.ap_followers(user),
      "inbox" => "#{user.ap_id}/inbox",
      "outbox" => user.outbox_address || "#{user.ap_id}/outbox",
      "featured" => User.ap_featured_collection(user),
      "preferredUsername" => Marketplace.webfinger_nickname(user),
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
      "attachment" => fields ++ (user.identity_proofs || []),
      "tag" => emoji_tags,
      # Note: key name is indeed "discoverable" (not an error)
      "discoverable" => user.is_discoverable,
      "indexable" => user.is_indexable,
      "interactionPolicy" => %{
        "canFeature" => %{
          "automaticApproval" => [
            if(user.is_discoverable, do: Pleroma.Constants.as_public(), else: user.ap_id)
          ]
        }
      },
      "capabilities" => capabilities,
      "generator" => application_generator(),
      "alsoKnownAs" => user.also_known_as,
      "vcard:bday" => birthday,
      "vcard:Address" => user.location,
      "webfinger" =>
        "acct:#{Marketplace.webfinger_nickname(user)}@#{Pleroma.Web.WebFinger.domain()}",
      "published" => Pleroma.Web.CommonAPI.Utils.to_masto_date(user.inserted_at)
    }
    |> maybe_put_attribution_domains(user)
    |> Map.merge(group_actor_fields(user))
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
    |> ActorExtensions.merge_into_actor(user.actor_extensions)
    |> maybe_keep_local_generator(user)
    |> maybe_put_finalized_fep_fields(user)
  end

  def render("following.json", %{user: user, page: page} = opts) do
    showing_items = (opts[:for] && opts[:for] == user) || !user.hide_follows
    showing_count = showing_items || !user.hide_follows_count

    query = User.get_friends_query(user)
    query = from(user in query, select: [:ap_id])
    following = Repo.all(query)

    total =
      if showing_count do
        length(following)
      else
        0
      end

    collection(following, "#{user.ap_id}/following", page, showing_items, total)
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("following.json", %{user: user} = opts) do
    showing_items = (opts[:for] && opts[:for] == user) || !user.hide_follows
    showing_count = showing_items || !user.hide_follows_count

    query = User.get_friends_query(user)
    query = from(user in query, select: [:ap_id])
    following = Repo.all(query)

    total =
      if showing_count do
        length(following)
      else
        0
      end

    first =
      if showing_items do
        collection(following, "#{user.ap_id}/following", 1, !user.hide_follows)
      else
        "#{user.ap_id}/following?page=1"
      end

    %{
      "id" => "#{user.ap_id}/following",
      "type" => "OrderedCollection",
      "totalItems" => total,
      "count" => total,
      "results" => collection_results(first),
      "first" => first,
      "last" => "#{user.ap_id}/following?page=#{max(div(total + 9, 10), 1)}"
    }
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("followers.json", %{user: user, page: page} = opts) do
    showing_items = (opts[:for] && opts[:for] == user) || !user.hide_followers
    showing_count = showing_items || !user.hide_followers_count

    query = User.get_followers_query(user)
    query = from(user in query, select: [:ap_id])
    followers = Repo.all(query)

    total =
      if showing_count do
        length(followers)
      else
        0
      end

    collection(followers, "#{user.ap_id}/followers", page, showing_items, total)
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("followers.json", %{user: user} = opts) do
    showing_items = (opts[:for] && opts[:for] == user) || !user.hide_followers
    showing_count = showing_items || !user.hide_followers_count

    query = User.get_followers_query(user)
    query = from(user in query, select: [:ap_id])
    followers = Repo.all(query)

    total =
      if showing_count do
        length(followers)
      else
        0
      end

    first =
      if showing_items do
        collection(followers, "#{user.ap_id}/followers", 1, showing_items, total)
      else
        "#{user.ap_id}/followers?page=1"
      end

    %{
      "id" => "#{user.ap_id}/followers",
      "type" => "OrderedCollection",
      "count" => total,
      "results" => collection_results(first),
      "first" => first,
      "last" => "#{user.ap_id}/followers?page=#{max(div(total + 9, 10), 1)}"
    }
    |> maybe_put_total_items(showing_count, total)
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("activity_collection.json", %{iri: iri} = opts) do
    %{
      "id" => iri,
      "type" => "OrderedCollection",
      "first" => "#{iri}?page=true"
    }
    |> maybe_put_total_items(is_integer(opts[:total_items]), opts[:total_items])
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render(
        "activity_collection_page.json",
        %{
          activities: activities,
          iri: iri,
          pagination: pagination
        } = opts
      ) do
    collection = Enum.flat_map(activities, &prepare_collection_item/1)

    %{
      "type" => "OrderedCollectionPage",
      "partOf" => iri,
      "orderedItems" => collection
    }
    |> maybe_put_total_items(is_integer(opts[:total_items]), opts[:total_items])
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
  end

  def render("moderators.json", %{user: %User{} = user}) do
    moderators =
      if GroupMembership.local_group?(user) do
        GroupMembership.local_group_moderator_ap_ids(user)
      else
        []
      end

    %{
      "id" => user.attributed_to_address || "#{user.ap_id}/collections/moderators",
      "type" => "OrderedCollection",
      "orderedItems" => moderators,
      "totalItems" => length(moderators)
    }
    |> Map.merge(Utils.make_json_ld_header())
  end

  # Historical rows can outlive their actor, object, or a now-supported wire
  # shape. One such row must not make the complete outbox unavailable to a
  # remote peer, but it should remain visible to operators as repair signal.
  defp prepare_collection_item(activity) do
    case Transmogrifier.prepare_outgoing(activity.data) do
      {:ok, data} when is_map(data) ->
        [data]

      result ->
        log_skipped_collection_item(activity, result)
        []
    end
  rescue
    exception ->
      log_skipped_collection_item(activity, {:exception, Exception.message(exception)})
      []
  catch
    kind, reason ->
      log_skipped_collection_item(activity, {kind, reason})
      []
  end

  defp log_skipped_collection_item(activity, reason) do
    Logger.warning("Skipping an unrenderable ActivityPub collection item",
      activity_id: Map.get(activity, :id),
      activity_type: get_in(activity.data || %{}, ["type"]),
      reason: inspect(reason, limit: 10, printable_limit: 300)
    )
  end

  defp maybe_put_total_items(map, false, _total), do: map

  defp maybe_put_total_items(map, true, total) do
    Map.put(map, "totalItems", total)
  end

  def collection(collection, iri, page, show_items \\ true, total \\ nil) do
    offset = (page - 1) * 10
    items = Enum.slice(collection, offset, 10)
    items = Enum.map(items, fn user -> user.ap_id end)
    total = total || length(collection)

    map = %{
      "id" => "#{iri}?page=#{page}",
      "type" => "OrderedCollectionPage",
      "partOf" => iri,
      "count" => total,
      "totalItems" => total,
      "results" => if(show_items, do: items, else: []),
      "orderedItems" => if(show_items, do: items, else: [])
    }

    map =
      if page > 1 do
        Map.put(map, "prev", "#{iri}?page=#{page - 1}")
      else
        map
      end

    if offset + 10 < total,
      do: Map.put(map, "next", "#{iri}?page=#{page + 1}"),
      else: map
  end

  defp collection_results(%{"orderedItems" => items}) when is_list(items), do: items
  defp collection_results(_), do: []

  defp maybe_put_restricted_group_fields(data, %User{actor_type: "Group"} = user) do
    Map.put(
      data,
      "attributedTo",
      user.attributed_to_address || "#{user.ap_id}/collections/moderators"
    )
  end

  defp maybe_put_restricted_group_fields(data, _user), do: data

  # FEP-2345 requires the actor to authorize every site that may identify the
  # actor through a fediverse:creator HTML tag. Remote actor documents retain
  # their publisher-supplied value through ActorExtensions instead.
  defp maybe_put_attribution_domains(data, %User{local: true}) do
    Map.put(data, "attributionDomains", [Pleroma.Web.WebFinger.domain()])
  end

  defp maybe_put_attribution_domains(data, _user), do: data

  # FEP-844e permits an anonymous partial Application under generator. Only
  # local actors advertise capabilities here; rendering a cached remote actor
  # must never make Unfathomably claim authorship of that actor document.
  defp application_generator do
    %{
      "type" => "Application",
      "name" => "Unfathomably",
      "implements" => application_capabilities()
    }
  end

  defp application_capabilities, do: [@rfc_9421_capability]

  defp maybe_keep_local_generator(data, %User{local: true}) do
    data
    |> Map.put("generator", application_generator())
    |> add_capability_context()
  end

  defp maybe_keep_local_generator(data, _user) do
    Map.delete(data, "generator")
  end

  defp add_capability_context(%{"@context" => context} = data) do
    context =
      context
      |> List.wrap()
      |> Kernel.++([@fep_844e_context])
      |> Enum.uniq()

    Map.put(data, "@context", context)
  end

  defp group_actor_fields(%User{actor_type: "Group"} = user) do
    %{
      "attributedTo" => user.attributed_to_address || "#{user.ap_id}/collections/moderators",
      "indexable" => user.is_indexable,
      "postingRestrictedToMods" => user.posting_restricted_to_mods
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp group_actor_fields(_), do: %{}

  defp actor_json_ld_type(%User{actor_types: [actor_type]}), do: actor_type

  defp actor_json_ld_type(%User{actor_types: actor_types})
       when is_list(actor_types) and length(actor_types) > 1,
       do: actor_types

  defp actor_json_ld_type(%User{actor_type: actor_type}), do: actor_type

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
    Map.put(map, "name", description)
  end

  defp maybe_put_description(map, _description), do: map

  defp maybe_put_finalized_fep_fields(data, %User{local: true, ap_id: ap_id, keys: keys} = user)
       when is_binary(ap_id) and is_binary(keys) do
    data
    |> maybe_put_assertion_method(ap_id, keys)
    |> maybe_put_appendable_wall(user)
  end

  defp maybe_put_finalized_fep_fields(data, _user), do: data

  defp maybe_put_assertion_method(data, ap_id, keys) do
    case Multikey.rsa_public_key_multibase(keys) do
      {:ok, public_key_multibase} ->
        data
        |> Map.put("assertionMethod", [
          %{
            "id" => ap_id <> "#main-key",
            "type" => "Multikey",
            "controller" => ap_id,
            "publicKeyMultibase" => public_key_multibase
          }
        ])
        |> append_json_ld_context("https://www.w3.org/ns/cid/v1")

      _error ->
        data
    end
  end

  defp maybe_put_appendable_wall(data, %User{nickname: nickname} = user)
       when is_binary(nickname) do
    if Pleroma.Web.ActivityPub.AppendableCollection.enabled?() do
      data
      |> Map.put("wall", Pleroma.Web.ActivityPub.AppendableCollection.collection(user))
      |> append_json_ld_context(%{
        "wall" => %{
          "@id" => "https://w3id.org/fep/400e#wall",
          "@type" => "@id"
        }
      })
    else
      data
    end
  end

  defp maybe_put_appendable_wall(data, _user), do: data

  defp append_json_ld_context(data, context) do
    Map.update(data, "@context", [context], fn
      contexts when is_list(contexts) -> Enum.uniq(contexts ++ [context])
      existing -> [existing, context]
    end)
  end
end

# end of user_view.ex
