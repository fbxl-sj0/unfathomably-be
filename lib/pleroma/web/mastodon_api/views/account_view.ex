# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.AccountView do
  use Pleroma.Web, :view

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @favicon_cache_ttl :timer.hours(24)
  @stale_favicon_cache_ttl :timer.minutes(5)
  @maximum_remote_profile_note_chars 5_000
  @maximum_remote_profile_note_bytes @maximum_remote_profile_note_chars * 4

  alias Pleroma.FederationStatus
  alias Pleroma.Activity
  alias Pleroma.FollowingRelationship
  alias Pleroma.Instances.Instance
  alias Pleroma.Nostr.Identity
  alias Pleroma.User
  alias Pleroma.UserNote
  alias Pleroma.UserRelationship
  alias Pleroma.Utils.URIEncoding
  alias Pleroma.Web.ActivityPub.ActorExtensions
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.CommonAPI.Utils
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.Web.MediaProxy
  alias Pleroma.Workers.InstanceFaviconWorker

  defp bounded_profile_note(%{bio: bio}, false) when is_binary(bio) do
    limit =
      case Pleroma.Config.get([:instance, :user_bio_length], 5_000) do
        value when is_integer(value) and value >= 0 ->
          min(value, @maximum_remote_profile_note_chars)

        _value ->
          @maximum_remote_profile_note_chars
      end

    # Older rows and non-ActivityPub import paths can predate the remote-user
    # changeset limit. A codepoint boundary is deliberate here: one grapheme
    # may contain an unbounded number of combining codepoints.
    Pleroma.TextBoundary.truncate_utf8(bio, limit, @maximum_remote_profile_note_bytes)
  end

  defp bounded_profile_note(%{bio: bio}, _local) when is_binary(bio), do: bio
  defp bounded_profile_note(_user, _local), do: ""

  def render("index.json", %{users: users} = opts) do
    reading_user = opts[:for]

    relationships_opt =
      cond do
        Map.has_key?(opts, :relationships) ->
          opts[:relationships]

        is_nil(reading_user) || !opts[:embed_relationships] ->
          UserRelationship.view_relationships_option(nil, [])

        true ->
          UserRelationship.view_relationships_option(reading_user, users)
      end

    opts =
      opts
      |> Map.merge(%{relationships: relationships_opt, as: :user})
      |> Map.delete(:users)

    users
    |> render_many(AccountView, "show.json", opts)
    |> Enum.filter(&Enum.any?/1)
  end

  @doc """
  Renders specified user account.
    :skip_visibility_check option skips visibility check and renders any user (local or remote)
      regardless of [:pleroma, :restrict_unauthenticated] setting.
    :for option specifies the requester and can be a User record or nil.
      Only use `user: user, for: user` when `user` is the actual requester of own profile.
  """
  def render("show.json", %{user: _user, skip_visibility_check: true} = opts) do
    do_render("show.json", opts)
  end

  def render("show.json", %{user: user, for: for_user_or_nil} = opts) do
    if User.visible_for(user, for_user_or_nil) == :visible do
      do_render("show.json", opts)
    else
      %{}
    end
  end

  def render("show.json", _) do
    raise "In order to prevent account accessibility issues, " <>
            ":skip_visibility_check or :for option is required."
  end

  def render("mention.json", %{user: user}) do
    %{
      id: to_string(user.id),
      acct: user.nickname,
      username: mention_username(user),
      url: user.uri || user.ap_id,
      actor_type: user.actor_type
    }
  end

  def render("relationship.json", %{user: nil, target: _target}) do
    %{}
  end

  def render(
        "relationship.json",
        %{user: %User{} = reading_user, target: %User{} = target} = opts
      ) do
    user_relationships = get_in(opts, [:relationships, :user_relationships])
    following_relationships = get_in(opts, [:relationships, :following_relationships])

    follow_state =
      if following_relationships do
        user_to_target_following_relation =
          FollowingRelationship.find(following_relationships, reading_user, target)

        User.get_follow_state(reading_user, target, user_to_target_following_relation)
      else
        User.get_follow_state(reading_user, target)
      end

    followed_by = FollowingRelationship.following?(target, reading_user)
    following = FollowingRelationship.following?(reading_user, target)

    requested =
      cond do
        following -> false
        true -> match?(:follow_pending, follow_state)
      end

    subscribing =
      UserRelationship.exists?(
        user_relationships,
        :inverse_subscription,
        target,
        reading_user,
        &User.subscribed_to?(&2, &1)
      )

    blocking =
      UserRelationship.exists?(
        user_relationships,
        :block,
        reading_user,
        target,
        &User.blocks_user?(&1, &2)
      )

    muting =
      UserRelationship.exists?(
        user_relationships,
        :mute,
        reading_user,
        target,
        &User.mutes?(&1, &2)
      )

    federation = FederationStatus.for_user(target)

    # NOTE: adjust UserRelationship.view_relationships_option/2 on new relation-related flags
    relationship = %{
      id: to_string(target.id),
      following: following,
      followed_by: followed_by,
      blocking: blocking,
      blocked_by:
        UserRelationship.exists?(
          user_relationships,
          :block,
          target,
          reading_user,
          &User.blocks_user?(&1, &2)
        ),
      block_expires_at: nil,
      muting: muting,
      muting_notifications:
        UserRelationship.exists?(
          user_relationships,
          :notification_mute,
          reading_user,
          target,
          &User.muted_notifications?(&1, &2)
        ),
      mute_expires_at: nil,
      subscribing: subscribing,
      notifying: subscribing,
      requested: requested,
      domain_blocking: User.blocks_domain?(reading_user, target),
      federation: federation,
      federation_blocked: FederationStatus.defederated?(federation),
      showing_reblogs:
        not UserRelationship.exists?(
          user_relationships,
          :reblog_mute,
          reading_user,
          target,
          &User.muting_reblogs?(&1, &2)
        ),
      note:
        UserNote.show(
          reading_user,
          target
        ),
      endorsed:
        UserRelationship.exists?(
          user_relationships,
          :endorsement,
          reading_user,
          target,
          &User.endorses?(&1, &2)
        )
    }

    relationship
    |> maybe_put_mute_expires_at(target, reading_user, %{mutes: muting})
    |> maybe_put_block_expires_at(target, reading_user, %{blocks: blocking})
  end

  def render("relationships.json", %{user: user, targets: targets} = opts) do
    relationships_opt =
      cond do
        Map.has_key?(opts, :relationships) ->
          opts[:relationships]

        is_nil(user) ->
          UserRelationship.view_relationships_option(nil, [])

        true ->
          UserRelationship.view_relationships_option(user, targets)
      end

    render_opts = %{as: :target, user: user, relationships: relationships_opt}
    render_many(targets, AccountView, "relationship.json", render_opts)
  end

  def render("familiar_followers.json", %{users: users} = opts) do
    opts =
      opts
      |> Map.merge(%{as: :user})
      |> Map.delete(:users)

    users
    |> render_many(AccountView, "familiar_followers.json", opts)
  end

  def render("familiar_followers.json", %{user: %{id: id, accounts: accounts}} = opts) do
    accounts =
      accounts
      |> render_many(AccountView, "show.json", opts)
      |> Enum.filter(&Enum.any?/1)

    %{id: id, accounts: accounts}
  end

  defp do_render("show.json", %{user: user} = opts) do
    self = opts[:for] == user

    nostr = Identity.presentation(user)
    atproto = Pleroma.ATProto.Identities.presentation(user)
    diaspora = Pleroma.Diaspora.presentation(user)
    local = public_local?(user, nostr, atproto, diaspora)
    user = if local, do: user, else: %{user | bio: bounded_profile_note(user, false)}
    user = User.sanitize_html(user, User.html_filter_policy(opts[:for]))
    display_name = user.name || user.nickname

    avatar = MediaProxy.url(User.avatar_url(user))
    avatar_static = MediaProxy.preview_url(User.avatar_url(user), static: true)
    avatar_description = User.image_description(user.avatar)
    header = MediaProxy.url(User.banner_url(user))
    header_static = MediaProxy.preview_url(User.banner_url(user), static: true)
    header_description = User.image_description(user.banner)

    following_count = rendered_following_count(user, self)
    followers_count = rendered_follower_count(user, self)

    bot = user.actor_type == "Service"

    emojis =
      Enum.map(user.emoji, fn {shortcode, raw_url} ->
        url =
          raw_url
          |> encode_emoji_url()
          |> MediaProxy.url()

        %{
          shortcode: shortcode,
          url: url,
          static_url: url,
          visible_in_picker: false
        }
      end)

    relationship = rendered_relationship(user, opts)
    favicon = rendered_favicon(user)
    federation = FederationStatus.for_user(user)
    native = ActorExtensions.presentation(user.actor_extensions, user.ap_id)

    %{
      id: to_string(user.id),
      username: username_from_nickname(user.nickname),
      acct: user.nickname,
      display_name: display_name,
      locked: user.is_locked,
      created_at: Utils.to_masto_date(user.inserted_at),
      followers_count: followers_count,
      following_count: following_count,
      statuses_count: user.note_count,
      note: bounded_profile_note(user, local),
      url: user.uri || user.ap_id,
      avatar: avatar,
      avatar_static: avatar_static,
      avatar_description: avatar_description,
      header: header,
      header_static: header_static,
      header_description: header_description,
      emojis: emojis,
      fields: user.fields,
      bot: bot,
      local: local,
      source: %{
        note: user.raw_bio || "",
        sensitive: false,
        fields: user.raw_fields,
        pleroma: %{
          discoverable: user.is_discoverable,
          indexable: user.is_indexable,
          actor_type: user.actor_type,
          actor_types: user.actor_types
        }
      },
      last_status_at: Utils.to_masto_date(user.last_status_at, nil),

      # Pleroma extensions
      # Note: it's insecure to output :email but fully-qualified nickname may serve as safe stub
      fqn: User.full_nickname(user),
      pleroma: %{
        ap_id: user.ap_id,
        actor_types: user.actor_types,
        also_known_as: user.also_known_as,
        is_confirmed: user.is_confirmed,
        is_suggested: user.is_suggested,
        tags: user.tags,
        hide_followers_count: user.hide_followers_count,
        hide_follows_count: user.hide_follows_count,
        hide_followers: user.hide_followers,
        hide_follows: user.hide_follows,
        hide_favorites: user.hide_favorites,
        relationship: relationship,
        skip_thread_containment: user.skip_thread_containment,
        background_image: MediaProxy.url(image_url(user.background)),
        accepts_chat_messages: user.accepts_chat_messages,
        favicon: favicon,
        federation: federation,
        is_local: local,
        location: user.location,
        avatar_description: avatar_description,
        header_description: header_description,
        identity_proofs: user.identity_proofs
      }
    }
    |> maybe_put_native(native)
    |> maybe_put_nostr(nostr)
    |> maybe_put_protocol(:atproto, atproto)
    |> maybe_put_protocol(:diaspora, diaspora)
    |> maybe_put_role(user, opts[:for])
    |> maybe_put_privileges(user, opts[:for])
    |> maybe_put_settings(user, opts[:for], opts)
    |> maybe_put_notification_settings(user, opts[:for])
    |> maybe_put_settings_store(user, opts[:for], opts)
    |> maybe_put_activation_status(user, opts[:for])
    |> maybe_put_follow_requests_count(user, opts[:for])
    |> maybe_put_allow_following_move(user, opts[:for])
    |> maybe_put_moved_to(user, opts[:for])
    |> maybe_put_unread_conversation_count(user, opts[:for])
    |> maybe_put_unread_notification_count(user, opts[:for])
    |> maybe_put_accepts_email_list(user, opts[:for])
    |> maybe_put_email_address(user, opts[:for])
    |> maybe_put_mute_expires_at(user, opts[:for], opts, relationship)
    |> maybe_put_block_expires_at(user, opts[:for], opts, relationship)
    |> maybe_show_birthday(user, opts[:for])
  end

  defp maybe_put_moved_to(data, %User{id: user_id} = user, %User{id: user_id}) do
    moved_to =
      case ActivityPub.latest_move(user) do
        %Activity{data: %{"target" => target}} when is_binary(target) -> target
        _ -> nil
      end

    put_in(data, [:pleroma, :moved_to], moved_to)
  end

  defp maybe_put_moved_to(data, _user, _viewer), do: data

  defp maybe_put_native(account, nil), do: account

  defp maybe_put_native(%{pleroma: pleroma} = account, native) do
    %{account | pleroma: Map.put(pleroma, :native, native)}
  end

  defp maybe_put_nostr(account, nil), do: account
  defp maybe_put_nostr(account, nostr), do: Map.put(account, :nostr, nostr)
  defp maybe_put_protocol(account, _key, nil), do: account
  defp maybe_put_protocol(account, key, value), do: Map.put(account, key, value)

  # Nostr mirrors are hosted local actors because Unfathomably must sign and
  # serve their ActivityPub projections. The represented people and groups are
  # nevertheless remote identities, so public account metadata must not expose
  # the storage-level User.local flag for them.
  defp mention_username(user) do
    atproto_handle =
      case Pleroma.ATProto.Identities.get_by_user(user) do
        %Pleroma.ATProto.Identity{handle: handle} when is_binary(handle) and handle != "" ->
          handle

        _identity ->
          nil
      end

    nostr_name =
      case Pleroma.Nostr.Identity.get_by_user(user) do
        %Pleroma.Nostr.Entity{} ->
          case Pleroma.Nostr.Identity.presentation(user) do
            %{nip05: nip05} when is_binary(nip05) and nip05 != "" -> nip05
            %{npub: npub} when is_binary(npub) and npub != "" -> npub
            _presentation -> nil
          end

        _entity ->
          nil
      end

    atproto_handle || nostr_name || username_from_nickname(user.nickname)
  end

  defp public_local?(%User{local: true}, %{kind: kind}, _atproto, _diaspora)
       when kind in ["mirror_profile", "mirror_group"],
       do: false

  defp public_local?(%User{local: true}, _nostr, %{mirror: true}, _diaspora), do: false
  defp public_local?(%User{local: true}, _nostr, _atproto, %{mirror: true}), do: false

  defp public_local?(%User{local: local}, _nostr, _atproto, _diaspora), do: local == true

  defp rendered_following_count(user, self) do
    if !user.hide_follows_count or !user.hide_follows or self do
      visible_following_count(user)
    else
      0
    end
  end

  defp rendered_follower_count(user, self) do
    if !user.hide_followers_count or !user.hide_followers or self do
      visible_follower_count(user)
    else
      0
    end
  end

  defp rendered_relationship(user, %{embed_relationships: true} = opts) do
    render("relationship.json", %{
      user: opts[:for],
      target: user,
      relationships: opts[:relationships]
    })
  end

  defp rendered_relationship(_, _), do: %{}

  defp rendered_favicon(user) do
    if Pleroma.Config.get([:instances_favicons, :enabled]) do
      user
      |> Map.get(:ap_id, "")
      |> URI.parse()
      |> URI.merge("/")
      |> cached_favicon()
      |> Instance.normalize_favicon_url()
      |> MediaProxy.url()
    else
      nil
    end
  end

  defp cached_favicon(%URI{host: host} = uri) when is_binary(host) do
    cache_key = Instance.favicon_cache_key(host)

    case @cachex.fetch!(:host_meta_cache, cache_key, fn _ ->
           {favicon, ttl} = favicon_for_render(uri)
           {:commit, {:favicon, favicon}, expire: ttl}
         end) do
      {:favicon, favicon} -> favicon
      favicon when is_binary(favicon) -> favicon
      _ -> nil
    end
  rescue
    _ -> uri |> favicon_for_render() |> elem(0)
  end

  defp cached_favicon(_uri), do: nil

  defp favicon_for_render(uri) do
    case Instance.favicon_status(uri) do
      {:fresh, favicon} ->
        {favicon, @favicon_cache_ttl}

      {:stale, favicon} ->
        _ = InstanceFaviconWorker.enqueue(uri)
        {favicon, @stale_favicon_cache_ttl}

      _ ->
        {nil, @stale_favicon_cache_ttl}
    end
  end

  defp username_from_nickname(string) when is_binary(string) do
    hd(String.split(string, "@"))
  end

  defp username_from_nickname(_), do: nil

  defp maybe_put_follow_requests_count(
         data,
         %User{id: user_id} = user,
         %User{id: user_id}
       ) do
    count = length(User.get_follow_requests(user))

    data
    |> Kernel.put_in([:follow_requests_count], count)
  end

  defp maybe_put_follow_requests_count(data, _, _), do: data

  defp maybe_put_settings(
         data,
         %User{id: user_id} = user,
         %User{id: user_id},
         _opts
       ) do
    data
    |> Kernel.put_in([:source, :privacy], user.default_scope)
    |> Kernel.put_in([:source, :pleroma, :show_role], user.show_role)
    |> Kernel.put_in([:source, :pleroma, :no_rich_text], user.no_rich_text)
    |> Kernel.put_in([:source, :pleroma, :show_birthday], user.show_birthday)
  end

  defp maybe_put_settings(data, _, _, _), do: data

  defp maybe_put_settings_store(data, %User{} = user, %User{}, %{
         with_pleroma_settings: true
       }) do
    data
    |> Kernel.put_in([:pleroma, :settings_store], user.pleroma_settings_store)
  end

  defp maybe_put_settings_store(data, _, _, _), do: data

  defp maybe_put_role(data, %User{show_role: true} = user, _) do
    put_role(data, user)
  end

  defp maybe_put_role(data, %User{id: user_id} = user, %User{id: user_id}) do
    put_role(data, user)
  end

  defp maybe_put_role(data, _, _), do: data

  defp put_role(data, user) do
    data
    |> Kernel.put_in([:pleroma, :is_admin], user.is_admin)
    |> Kernel.put_in([:pleroma, :is_moderator], user.is_moderator)
  end

  defp maybe_put_privileges(data, %User{id: user_id} = user, %User{id: user_id}) do
    put_privileges(data, user)
  end

  defp maybe_put_privileges(data, _, _), do: data

  defp put_privileges(data, user) do
    Kernel.put_in(data, [:pleroma, :privileges], User.privileges(user))
  end

  defp maybe_put_notification_settings(data, %User{id: user_id} = user, %User{id: user_id}) do
    Kernel.put_in(
      data,
      [:pleroma, :notification_settings],
      Map.from_struct(user.notification_settings)
    )
  end

  defp maybe_put_notification_settings(data, _, _), do: data

  defp maybe_put_allow_following_move(data, %User{id: user_id} = user, %User{id: user_id}) do
    Kernel.put_in(data, [:pleroma, :allow_following_move], user.allow_following_move)
  end

  defp maybe_put_allow_following_move(data, _, _), do: data

  defp maybe_put_activation_status(data, user, user_for) do
    if User.privileged?(user_for, :users_manage_activation_state),
      do: Kernel.put_in(data, [:pleroma, :deactivated], !user.is_active),
      else: data
  end

  defp maybe_put_unread_conversation_count(data, %User{id: user_id} = user, %User{id: user_id}) do
    data
    |> Kernel.put_in(
      [:pleroma, :unread_conversation_count],
      Pleroma.Conversation.Participation.unread_count(user)
    )
  end

  defp maybe_put_unread_conversation_count(data, _, _), do: data

  defp maybe_put_unread_notification_count(data, %User{id: user_id}, %User{id: user_id} = user) do
    Kernel.put_in(
      data,
      [:pleroma, :unread_notifications_count],
      Pleroma.Notification.unread_notifications_count(user)
    )
  end

  defp maybe_put_unread_notification_count(data, _, _), do: data

  defp maybe_put_accepts_email_list(data, %User{id: user_id}, %User{id: user_id} = user) do
    Kernel.put_in(
      data,
      [:pleroma, :accepts_email_list],
      user.accepts_email_list
    )
  end

  defp maybe_put_accepts_email_list(data, _, _), do: data

  defp maybe_put_email_address(data, %User{id: user_id}, %User{id: user_id} = user) do
    Kernel.put_in(
      data,
      [:pleroma, :email],
      user.email
    )
  end

  defp maybe_put_email_address(data, _, _), do: data

  defp maybe_put_mute_expires_at(data, target, user, opts, relationship \\ nil)

  defp maybe_put_mute_expires_at(data, _target, _user, %{mutes: true}, %{
         mute_expires_at: mute_expires_at
       }) do
    Map.put(data, :mute_expires_at, mute_expires_at)
  end

  defp maybe_put_mute_expires_at(data, %User{} = target, %User{} = user, %{mutes: true}, _rel) do
    Map.put(
      data,
      :mute_expires_at,
      UserRelationship.get_mute_expire_date(user, target)
    )
  end

  defp maybe_put_mute_expires_at(data, _, _, _, _), do: data

  defp maybe_put_block_expires_at(data, target, user, opts, relationship \\ nil)

  defp maybe_put_block_expires_at(data, _target, _user, %{blocks: true}, %{
         block_expires_at: block_expires_at
       }) do
    Map.put(data, :block_expires_at, block_expires_at)
  end

  defp maybe_put_block_expires_at(data, %User{} = target, %User{} = user, %{blocks: true}, _rel) do
    Map.put(
      data,
      :block_expires_at,
      UserRelationship.get_block_expire_date(user, target)
    )
  end

  defp maybe_put_block_expires_at(data, _, _, _, _), do: data

  defp maybe_show_birthday(data, %User{id: user_id} = user, %User{id: user_id}) do
    data
    |> Kernel.put_in([:pleroma, :birthday], user.birthday)
  end

  defp maybe_show_birthday(data, %User{show_birthday: true} = user, _) do
    data
    |> Kernel.put_in([:pleroma, :birthday], user.birthday)
  end

  defp maybe_show_birthday(data, _, _) do
    data
  end

  defp visible_following_count(%User{local: true} = user) do
    if Pleroma.Instances.any_dormant?() do
      cached_visible_count(user, :following, fn ->
        FollowingRelationship.following_count(user)
      end)
    else
      user.following_count || 0
    end
  end

  defp visible_following_count(%User{} = user), do: user.following_count || 0

  defp visible_follower_count(%User{local: true} = user) do
    if Pleroma.Instances.any_dormant?() do
      cached_visible_count(user, :follower, fn ->
        FollowingRelationship.follower_count(user)
      end)
    else
      user.follower_count || 0
    end
  end

  defp visible_follower_count(%User{} = user), do: user.follower_count || 0

  defp cached_visible_count(%User{id: id}, type, fun)
       when not is_nil(id) and type in [:follower, :following] do
    @cachex.fetch!(:user_cache, "visible_#{type}_count:#{id}", fn _ ->
      fun.()
    end)
  rescue
    _ -> fun.()
  end

  defp cached_visible_count(_, _, fun), do: fun.()

  defp image_url(%{"url" => [%{"href" => href} | _]}), do: href
  defp image_url(_), do: nil

  defp encode_emoji_url(nil), do: nil
  defp encode_emoji_url("http" <> _ = url), do: URIEncoding.encode_url(url)

  defp encode_emoji_url("/" <> _ = path) do
    URIEncoding.encode_url(path, bypass_parse: true, bypass_decode: true)
  end

  defp encode_emoji_url(path) when is_binary(path) do
    URIEncoding.encode_url(path, bypass_parse: true, bypass_decode: true)
  end
end
