# Pleroma: A lightweight social networking server
# Copyright Ã‚Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.FederatedTarget do
  @moduledoc """
  Shared lookup, listing, and classification for federated groups and feeds.

  Rebased stores remote ActivityPub actors in the normal users table.  This
  module keeps the higher-level "group" and "feed" APIs from growing a
  parallel actor store by treating ActivityPub Group actors as groups and
  non-profile publishers such as RSS feeds, blogs, channels, and music
  libraries as feeds.
  """

  import Ecto.Query
  import SweetXml, only: [sigil_x: 2]

  require Pleroma.Constants

  alias Pleroma.Activity
  alias Pleroma.FollowingRelationship
  alias Pleroma.GroupMembership
  alias Pleroma.HTTP
  alias Pleroma.HTTP.AdapterHelper
  alias Pleroma.Instances
  alias Pleroma.Instances.Instance
  alias Pleroma.Notification
  alias Pleroma.Object.Fetcher
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.RemoteReplies
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.Federation.Platform
  alias Pleroma.Web.MastodonAPI.StatusView

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @group_actor_type "Group"
  @group_service_actor_types ["Application", "Service"]
  @group_service_actor_regex "fedigroups|gancio|gup\\.pe|buzzrelay|tootgroup"
  @group_service_platform_fragments ["fedigroups", "gancio", "gup.pe", "buzzrelay", "tootgroup"]
  @feed_actor_types ["Application", "Service"]
  @feed_source_actor_regex "wp-json|wordpress|writefreely|postmarks|/api/collections/|/video-channels/|peertube|castopod|/federation/user/|/federation/music/libraries/|/music/libraries/|funkwhale|bookwyrm"
  @feed_source_platform_regex "^(bookwyrm|castopod|funkwhale|gancio|mobilizon|owncast|peertube|pixelfed|postmarks|wordpress|wordpress event bridge|writefreely)$"
  @feed_microblog_platforms [
    "gotosocial",
    "iceshrimp",
    "misskey",
    "mitra",
    "sharkey",
    "snac",
    "wafrn"
  ]
  @iceshrimp_instance_hosts ["torsi.ca", "tuit.fr", "yuustan.space", "iceshrimp.de"]
  @non_content_activity_types [
    "ApproveReply",
    "Accept",
    "Block",
    "Delete",
    "Dislike",
    "Download",
    "Flag",
    "Follow",
    "Like",
    "Reject",
    "RejectReply",
    "Undo",
    "View"
  ]
  @source_item_status_types [
    "Note",
    "Article",
    "Page",
    "Question",
    "Audio",
    "Video",
    "Image",
    "Event",
    "Comment",
    "Quotation",
    "Rating",
    "Review"
  ]
  @default_limit 40
  @max_limit 80
  @catalog_window_limit 240
  @max_target_identifier_bytes 2048
  @source_item_title_limit 240
  @source_item_summary_limit 1_000
  @rss_source_nickname_prefix "rss-"
  @rss_feed_redirect_limit 3
  @rss_feed_redirect_statuses [301, 302, 303, 307, 308]
  @rss_feed_gone_statuses [410, 451]
  @remote_group_preview_cache :remote_group_preview_cache
  @source_items_cache_ttl :timer.minutes(5)

  def group?(%User{
        actor_type: @group_actor_type,
        is_active: true,
        invisible: false,
        ap_id: ap_id
      })
      when is_binary(ap_id) do
    url?(ap_id)
  end

  def group?(
        %User{
          actor_type: actor_type,
          local: false,
          is_active: true,
          invisible: false,
          ap_id: ap_id
        } = user
      )
      when actor_type in @group_service_actor_types and is_binary(ap_id) do
    url?(ap_id) and group_service_actor?(user)
  end

  def group?(_), do: false

  def source?(
        %User{
          local: false,
          is_active: true,
          invisible: false,
          ap_id: ap_id
        } = user
      )
      when is_binary(ap_id) do
    url?(ap_id) and not group?(user) and feed_source_actor?(user)
  end

  def source?(_), do: false

  def rss_source?(%User{
        actor_type: "Service",
        local: false,
        nickname: nickname,
        ap_id: ap_id
      })
      when is_binary(ap_id) do
    (is_binary(nickname) and String.starts_with?(nickname, @rss_source_nickname_prefix)) or
      rss_feed_url?(ap_id)
  end

  def rss_source?(_), do: false

  defp feed_source_actor?(%User{} = user) do
    source_profile(user) != "activitypub_profile"
  end

  def list_groups(user, params), do: list_targets(:group, user, params)
  def list_sources(user, params), do: list_targets(:source, user, params)

  @doc "Return AP IDs for reachable groups followed by the given user."
  def followed_group_ap_ids(%User{} = user) do
    user
    |> FollowingRelationship.following_query()
    |> filter_followed_kind(:group)
    |> select([_r, u], u.ap_id)
    |> Repo.all()
  end

  def followed_group_ap_ids(_user), do: []

  @doc "Return AP IDs for reachable sources followed by the given user."
  def followed_source_ap_ids(%User{} = user) do
    user
    |> FollowingRelationship.following_query()
    |> filter_followed_kind(:source)
    |> select([_r, u], u.ap_id)
    |> Repo.all()
  end

  def followed_source_ap_ids(_user), do: []

  @doc "Return reachable RSS sources followed by at least one local user."
  def followed_rss_sources(limit \\ 200) do
    reachability_datetime_threshold = Instances.reachability_datetime_threshold()
    limit = followed_rss_sources_limit(limit)
    rss_nickname = @rss_source_nickname_prefix <> "%"

    FollowingRelationship
    |> join(:inner, [r], follower in User, on: r.follower_id == follower.id)
    |> join(:inner, [r, _follower], source in User, on: r.following_id == source.id)
    |> where([r, _follower, _source], r.state == ^:follow_accept)
    |> where([_r, follower, _source], follower.local == true and follower.is_active == true)
    |> where(
      [_r, _follower, source],
      source.actor_type == "Service" and source.local == false and source.is_active == true and
        source.invisible == false and fragment("? ~ ?", source.ap_id, "^https?://")
    )
    |> where(
      [_r, _follower, source],
      like(source.nickname, ^rss_nickname) or
        fragment(
          "lower(coalesce(?, '')) ~ ?",
          source.ap_id,
          "(/(rss|atom|feeds?)([-_.0-9/]|$)|\\.(xml|rss|atom)(\\?|#|$))"
        )
    )
    |> where(
      [_r, _follower, source],
      fragment(
        """
        not exists (
          select 1 from instances i
          where lower(i.host) = ap_id_host(?)
            and i.unreachable_since <= ?
        )
        """,
        source.ap_id,
        ^reachability_datetime_threshold
      )
    )
    |> distinct([_r, _follower, source], source.id)
    |> order_by([_r, _follower, source], desc: source.updated_at)
    |> select([_r, _follower, source], source)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.filter(&rss_source?/1)
  end

  def search_groups(params), do: search_targets(:group, params)
  def search_sources(params), do: search_targets(:source, params)

  def search_catalog(params) do
    limit = limit_param(params)
    offset = offset_param(params)
    window_limit = min(offset + limit, @catalog_window_limit)

    lookup_params =
      params
      |> Map.put("limit", window_limit)
      |> Map.put("offset", 0)

    group_targets =
      :group
      |> search_targets(lookup_params)
      |> Enum.map(&{:group, &1})

    source_targets =
      :source
      |> search_targets(lookup_params)
      |> Enum.map(&{:source, &1})

    [group_targets, source_targets]
    |> List.flatten()
    |> Enum.uniq_by(fn {_kind, user} -> user.id end)
    |> Enum.sort_by(fn {_kind, user} -> target_search_sort_key(user) end)
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  def resolve_group(identifier) do
    with {:ok, identifier} <- normalize_identifier(identifier),
         false <- unsafe_remote_identifier?(identifier) do
      case resolve_kind(identifier, :group) do
        {:ok, %User{} = group} -> {:ok, group}
        _ -> resolve_group_actor(identifier)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_source(identifier) do
    with {:ok, identifier} <- normalize_identifier(identifier),
         false <- unsafe_remote_identifier?(identifier) do
      case resolve_existing_source(identifier) do
        {:ok, %User{} = source} ->
          {:ok, source}

        _ ->
          case resolve_collection_source(identifier) do
            {:ok, %User{} = source} ->
              {:ok, source}

            _ ->
              case resolve_actor_source(identifier) do
                {:ok, %User{} = source} -> {:ok, source}
                _ -> resolve_source_webfinger_or_rss(identifier)
              end
          end
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_kind(identifier, kind) do
    with {:ok, identifier} <- normalize_identifier(identifier),
         false <- unsafe_remote_identifier?(identifier),
         {:ok, %User{} = user} <- resolve_target(identifier),
         true <- matches_kind?(user, kind) do
      {:ok, user}
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_target(identifier) when is_binary(identifier) do
    with {:ok, identifier} <- normalize_identifier(identifier) do
      cond do
        url?(identifier) and safe_fetch_url?(identifier) ->
          User.get_or_fetch_by_ap_id(identifier)

        url?(identifier) ->
          {:error, :not_found}

        safe_webfinger_identifier?(identifier) ->
          resolve_by_nickname(identifier)

        String.contains?(identifier, "@") ->
          {:error, :not_found}

        true ->
          resolve_by_id_or_nickname(identifier)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_target(_), do: {:error, :not_found}

  defp resolve_existing_source(identifier) do
    case resolve_kind(identifier, :source) do
      {:ok, %User{} = source} -> maybe_refresh_existing_rss_source(identifier, source)
      error -> error
    end
  end

  defp maybe_refresh_existing_rss_source(identifier, %User{} = source) do
    if url?(identifier) and rss_feed_url?(identifier) and rss_source?(source) do
      case resolve_rss_source(identifier) do
        {:ok, %User{} = refreshed_source} ->
          {:ok, refreshed_source}

        _ ->
          case Repo.get(User, source.id) do
            %User{is_active: true, invisible: false} = source -> {:ok, source}
            _ -> {:error, :not_found}
          end
      end
    else
      {:ok, source}
    end
  end

  def group_profile(%User{} = user) do
    host = String.downcase(host(user) || "")
    path = String.downcase(path(user) || "")
    nodeinfo_platform = instance_platform_name(user)

    cond do
      String.ends_with?(host, "gup.pe") ->
        "relay_group"

      String.contains?(path, ["/c/", "/communities/", "/m/"]) ->
        "threadiverse_forum"

      String.contains?(path, "/video-channels/") or nodeinfo_platform == "peertube" or
          (is_nil(nodeinfo_platform) and String.contains?(host, "peertube")) ->
        "collection_channel"

      String.contains?(path, "/category/") ->
        "forum_category"

      true ->
        "activitypub_group"
    end
  end

  def group_kind(%User{} = user) do
    case group_profile(user) do
      "relay_group" -> "relay_group"
      "forum_category" -> "forum_category"
      "collection_channel" -> "collection"
      _ -> "group"
    end
  end

  def source_profile(%User{} = user) do
    host = String.downcase(host(user) || "")
    path = String.downcase(path(user) || "")
    nodeinfo_platform = instance_platform_name(user)

    cond do
      rss_source?(user) ->
        "rss_feed"

      nodeinfo_platform in ["wordpress", "writefreely", "postmarks", "xwiki"] or
        String.contains?(path, "wp-json") or String.contains?(path, "/api/collections/") or
        String.contains?(path, "/xwiki/activitypub/") or
          (is_nil(nodeinfo_platform) and
             (String.contains?(host, "wordpress") or String.contains?(host, "writefreely") or
                String.contains?(host, "postmarks"))) ->
        "blog_publisher"

      nodeinfo_platform in ["peertube", "owncast", "castopod"] or
        String.contains?(path, "/video-channels/") or
        String.contains?(path, "/federation/user/") or
          (is_nil(nodeinfo_platform) and
             (String.contains?(host, "peertube") or String.contains?(host, "castopod"))) ->
        "collection_channel"

      nodeinfo_platform in ["funkwhale", "bookwyrm"] or
        String.contains?(path, ["/federation/music/libraries/", "/music/libraries/"]) or
          (is_nil(nodeinfo_platform) and
             (String.contains?(host, "funkwhale") or String.contains?(host, "bookwyrm"))) ->
        "library"

      nodeinfo_platform == "pixelfed" or
          (is_nil(nodeinfo_platform) and String.contains?(host, "pixelfed")) ->
        "photo_stream"

      nodeinfo_platform in @feed_microblog_platforms ->
        "microblog_feed"

      user.actor_type in ["Application", "Service"] ->
        "application_source"

      true ->
        "activitypub_profile"
    end
  end

  def source_kind(%User{} = user) do
    user
    |> source_platform()
    |> then(&source_kind_for_platform(user, &1))
  end

  def source_kind_label(%User{} = user), do: source_kind_label_for_kind(source_kind(user))
  def group_kind_label(%User{} = user), do: group_kind_label_for_kind(group_kind(user))

  def source_capabilities(%User{} = user) do
    platform = source_platform(user)
    kind = source_kind_for_platform(user, platform)

    source_capability_labels(kind, platform.platform)
  end

  def group_capabilities(%User{} = user) do
    platform = group_platform(user)
    kind = group_kind(user)

    group_capability_labels(kind, platform.platform)
  end

  def group_member_count(%User{local: false, follower_count: count})
      when is_integer(count) and count > 0,
      do: count

  def group_member_count(%User{local: false} = group) do
    group
    |> fetch_remote_group_member_count()
    |> case do
      count when is_integer(count) -> count
      _ -> group.follower_count || 0
    end
  end

  def group_member_count(%User{} = group), do: group.follower_count || 0

  def group_moderator_count(%User{local: true, actor_type: "Group"} = group) do
    group
    |> GroupMembership.local_group_moderator_ap_ids()
    |> length()
  end

  def group_moderator_count(%User{local: false, moderator_count: count})
      when is_integer(count) and count > 0,
      do: count

  def group_moderator_count(%User{local: false} = group) do
    group
    |> fetch_remote_group_moderator_count()
    |> case do
      count when is_integer(count) -> count
      _ -> group.moderator_count || 0
    end
  end

  def group_moderator_count(_), do: 0

  def source_platform(%User{} = user) do
    user
    |> source_platform_classification()
    |> platform_metadata()
  end

  def group_platform(%User{} = user) do
    user
    |> group_platform_classification()
    |> platform_metadata()
  end

  defp source_platform_classification(%User{} = user) do
    profile = source_profile(user)

    user
    |> platform_hints(profile, user.actor_type || "Object")
    |> Platform.classify()
  end

  defp group_platform_classification(%User{} = user) do
    profile = group_profile(user)

    user
    |> platform_hints(profile, "Group")
    |> Platform.classify()
  end

  defp platform_hints(%User{} = user, profile, fallback_type) do
    %{
      "nodeinfo" => instance_platform_hint(user),
      "platform" => platform_name_hint(user, profile),
      "type" => fallback_type
    }
  end

  defp instance_platform_name(%User{} = user) do
    user
    |> instance_platform_hint()
    |> case do
      %{} = hint ->
        case Platform.classify(%{"nodeinfo" => hint}) do
          %{confidence: :software, platform: platform} -> platform
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp instance_platform_hint(%User{} = user) do
    user
    |> cached_instance_metadata()
    |> instance_platform_hint()
  end

  defp instance_platform_hint(metadata) do
    software_name = metadata_field(metadata, :software_name)

    if present_binary?(software_name) do
      %{
        "software" =>
          %{
            "name" => software_name,
            "version" => metadata_field(metadata, :software_version)
          }
          |> maybe_put("repository", metadata_field(metadata, :software_repository))
      }
    end
  end

  defp cached_instance_metadata(%User{} = user) do
    with host when is_binary(host) <- host(user) do
      cached_instance_metadata(host)
    end
  end

  defp cached_instance_metadata(host) when is_binary(host) do
    host =
      host
      |> String.trim()
      |> String.downcase()

    cache_key = {__MODULE__, :instance_metadata_by_host}
    cache = Process.get(cache_key, %{})

    case Map.fetch(cache, host) do
      {:ok, metadata} ->
        metadata

      :error ->
        metadata =
          Instance
          |> where([instance], fragment("lower(?)", instance.host) == ^host)
          |> Repo.one()
          |> cached_instance_record_metadata()

        Process.put(cache_key, Map.put(cache, host, metadata))
        metadata
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp cached_instance_metadata(_), do: nil

  defp cached_instance_record_metadata(%Instance{} = instance) do
    if metadata_has_software?(instance.metadata) do
      instance.metadata
    else
      nil
    end
  end

  defp cached_instance_record_metadata(_), do: nil

  defp metadata_has_software?(metadata) do
    metadata
    |> metadata_field(:software_name)
    |> present_binary?()
  end

  defp metadata_field(%{} = metadata, key) when is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_field(_, _), do: nil

  defp platform_name_hint(%User{} = user, profile) do
    host = String.downcase(host(user) || "")
    path = String.downcase(path(user) || "")
    uri_path = String.downcase(path(user.uri) || "")
    inbox_path = String.downcase(path(user.inbox) || "")
    shared_inbox_path = String.downcase(path(user.shared_inbox) || "")
    paths = Enum.join([path, uri_path, inbox_path, shared_inbox_path], " ")

    cond do
      profile == "rss_feed" ->
        "rss"

      String.contains?(host, "funkwhale") or String.contains?(path, "/music/libraries/") ->
        "funkwhale"

      String.contains?(host, "castopod") ->
        "castopod"

      String.contains?(host, "event-bridge") or String.contains?(path, "event-bridge") ->
        "wordpress_event_bridge"

      String.contains?(host, "wordpress") or String.contains?(paths, "wp-json/activitypub") ->
        "wordpress"

      String.contains?(host, "writefreely") or String.contains?(paths, "/api/collections/") ->
        "writefreely"

      String.contains?(paths, "/xwiki/activitypub/") ->
        "xwiki"

      String.contains?(host, "postmarks") ->
        "postmarks"

      String.contains?(host, "gotosocial") or String.starts_with?(host, "gts.") ->
        "gotosocial"

      String.contains?(host, "iceshrimp") or host in @iceshrimp_instance_hosts ->
        "iceshrimp"

      String.contains?(host, "pixelfed") ->
        "pixelfed"

      String.contains?(host, "mitra") ->
        "mitra"

      String.contains?(path, "/federation/user/") ->
        "owncast"

      String.contains?(host, ["misskey", "calckey"]) ->
        "misskey"

      String.contains?(host, "sharkey") ->
        "sharkey"

      String.contains?(host, "bookwyrm") ->
        "bookwyrm"

      String.contains?(host, "wafrn") ->
        "wafrn"

      String.contains?(host, "snac") or String.contains?(path, "/snac/") ->
        "snac"

      String.contains?(host, "mastodon") ->
        "mastodon"

      String.contains?(host, ["pleroma", "akkoma"]) ->
        "pleroma"

      String.contains?(host, ["lotide", "narwhal.city"]) ->
        "lotide"

      String.contains?(host, "piefed") ->
        "piefed"

      String.contains?(host, "lemmy") or String.contains?(path, ["/c/", "/communities/"]) ->
        "lemmy"

      String.contains?(host, "mbin") or String.contains?(path, "/m/") ->
        "mbin"

      String.contains?(host, "mobilizon") ->
        "mobilizon"

      String.contains?(host, "nodebb") ->
        "nodebb"

      String.contains?(host, "discourse") or String.contains?(path, "/category/") or
          (String.contains?(path, "/ap/actor/") and String.contains?(uri_path, "/c/")) ->
        "discourse"

      String.contains?(host, ["friendica", "friendi.ca"]) ->
        "friendica"

      String.contains?(host, "hubzilla") ->
        "hubzilla"

      String.contains?(host, "bonfire") ->
        "bonfire"

      String.contains?(host, "fedigroups") ->
        "fedigroups"

      String.contains?(host, "fedibird") ->
        "fedibird_group"

      String.ends_with?(host, "gup.pe") or String.contains?(host, "guppe") ->
        "guppe"

      String.contains?(host, "buzzrelay") ->
        "buzzrelay"

      String.contains?(host, "flipboard") ->
        "flipboard"

      String.contains?(host, "elgg") ->
        "elgg"

      String.contains?(host, "smithereen") ->
        "smithereen"

      String.contains?(host, "streams") ->
        "streams_forte"

      String.contains?(host, "gancio") or String.contains?(path, "/federation/u/") ->
        "gancio"

      String.contains?(host, "peertube") or String.contains?(path, "/video-channels/") ->
        "peertube"

      profile == "library" ->
        "funkwhale"

      profile == "blog_publisher" ->
        "wordpress"

      profile == "collection_channel" ->
        "peertube"

      profile == "threadiverse_forum" ->
        "lemmy"

      true ->
        nil
    end
  end

  defp source_kind_for_platform(%User{} = user, %{platform: platform}) do
    case source_profile(user) do
      _ when platform == "owncast" -> "live_stream"
      "rss_feed" -> "rss_feed"
      "photo_stream" -> "photo_feed"
      "microblog_feed" -> "microblog_feed"
      "library" when platform == "funkwhale" -> "funkwhale_library"
      "library" -> "collection"
      "collection_channel" -> "ordered_collection"
      "blog_publisher" -> "actor_feed"
      "application_source" -> "service"
      _ -> "actor_feed"
    end
  end

  defp source_kind_label_for_kind("funkwhale_library"), do: "Library"
  defp source_kind_label_for_kind("photo_feed"), do: "Photo feed"
  defp source_kind_label_for_kind("microblog_feed"), do: "Microblog feed"
  defp source_kind_label_for_kind("live_stream"), do: "Live stream"
  defp source_kind_label_for_kind("ordered_collection"), do: "Ordered collection"
  defp source_kind_label_for_kind("collection"), do: "Collection"
  defp source_kind_label_for_kind("actor_feed"), do: "Actor feed"
  defp source_kind_label_for_kind("rss_feed"), do: "RSS feed"
  defp source_kind_label_for_kind("service"), do: "Service"
  defp source_kind_label_for_kind("group"), do: "Group"
  defp source_kind_label_for_kind(kind), do: humanize_key(kind)

  defp group_kind_label_for_kind("relay_group"), do: "Relay"
  defp group_kind_label_for_kind("forum_category"), do: "Forum category"
  defp group_kind_label_for_kind("collection"), do: "Collection"
  defp group_kind_label_for_kind("group"), do: "Group"
  defp group_kind_label_for_kind(kind), do: humanize_key(kind)

  defp source_capability_labels("funkwhale_library", _platform),
    do: ["follow library", "preview tracks", "owner inbox"]

  defp source_capability_labels("rss_feed", _platform),
    do: ["follow feed", "read items", "share links"]

  defp source_capability_labels(_kind, platform)
       when platform in [
              "fedigroups",
              "fedibird_group",
              "buzzrelay",
              "guppe",
              "ap_groups",
              "tootgroup"
            ],
       do: ["follow relay", "receive boosts", "public posts"]

  defp source_capability_labels(_kind, platform)
       when platform in ["wordpress", "writefreely", "postmarks", "xwiki"],
       do: ["follow author", "read posts", "send replies"]

  defp source_capability_labels(_kind, "flipboard"), do: ["follow magazine", "read articles"]

  defp source_capability_labels(_kind, "owncast"),
    do: ["follow stream", "preview live status", "play stream"]

  defp source_capability_labels(_kind, "castopod"),
    do: ["follow podcast", "preview episodes", "send replies"]

  defp source_capability_labels(_kind, platform)
       when platform in ["gancio", "mobilizon", "wordpress_event_bridge"],
       do: ["follow events", "preview events", "send replies"]

  defp source_capability_labels(_kind, "bookwyrm"),
    do: ["follow reader", "preview reviews", "read posts"]

  defp source_capability_labels(_kind, "pixelfed"),
    do: ["follow account", "preview images", "read posts"]

  defp source_capability_labels(_kind, platform)
       when platform in [
              "gotosocial",
              "misskey",
              "sharkey",
              "iceshrimp",
              "snac",
              "mitra",
              "wafrn",
              "mastodon",
              "pleroma"
            ],
       do: ["follow account", "preview posts", "read posts"]

  defp source_capability_labels("group", _platform), do: ["follow group", "read posts"]
  defp source_capability_labels(_kind, _platform), do: ["follow", "preview"]

  defp group_capability_labels("relay_group", _platform),
    do: ["follow relay", "receive boosts", "public posts"]

  defp group_capability_labels("forum_category", _platform),
    do: ["follow forum", "read threads", "send replies"]

  defp group_capability_labels(_kind, platform)
       when platform in ["mobilizon", "gancio", "wordpress_event_bridge"],
       do: ["follow events", "preview events", "send replies"]

  defp group_capability_labels(_kind, "peertube"),
    do: ["follow channel", "preview videos", "send replies"]

  defp group_capability_labels(_kind, platform)
       when platform in [
              "lemmy",
              "lotide",
              "piefed",
              "kbin",
              "mbin",
              "nodebb",
              "discourse",
              "friendica",
              "hubzilla",
              "bonfire",
              "smithereen",
              "streams_forte",
              "elgg"
            ],
       do: ["follow community", "read posts", "send replies"]

  defp group_capability_labels(_kind, _platform), do: ["follow group", "read posts"]

  defp humanize_key(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp platform_metadata(%{
         platform: platform,
         label: label,
         family: family,
         confidence: confidence
       }) do
    %{
      platform: platform,
      platform_label: label,
      platform_family: to_string(family),
      platform_confidence: to_string(confidence)
    }
  end

  def host(%User{} = user) do
    user
    |> actor_url()
    |> parse_uri()
    |> Map.get(:host)
  end

  defp path(%User{} = user) do
    user
    |> actor_url()
    |> parse_uri()
    |> Map.get(:path)
  end

  defp path(url) when is_binary(url) do
    url
    |> parse_uri()
    |> Map.get(:path)
  end

  defp path(_), do: nil

  defp list_targets(kind, %User{} = user, params) do
    case search_param(params) do
      "" ->
        followed_targets(kind, user, params)

      _ ->
        search_targets(kind, params)
    end
  end

  defp list_targets(kind, _user, params), do: search_targets(kind, params)

  defp followed_targets(kind, user, params) do
    user
    |> FollowingRelationship.following_query()
    |> filter_followed_kind(kind)
    |> order_by([r, _u], desc: r.updated_at)
    |> select([_r, u], u)
    |> offset(^offset_param(params))
    |> limit(^limit_param(params))
    |> Repo.all()
  end

  defp filter_followed_kind(query, :group) do
    reachability_datetime_threshold = Instances.reachability_datetime_threshold()

    where(
      query,
      [_r, u],
      (u.actor_type == @group_actor_type or
         (u.actor_type in ^@group_service_actor_types and
            fragment("? ~* ?", u.ap_id, ^@group_service_actor_regex))) and
        u.is_active == true and u.invisible == false and fragment("? ~ ?", u.ap_id, "^https?://")
    )
    |> filter_reachable_followed_actor(reachability_datetime_threshold)
  end

  defp filter_followed_kind(query, :source) do
    reachability_datetime_threshold = Instances.reachability_datetime_threshold()
    rss_nickname = @rss_source_nickname_prefix <> "%"

    where(
      query,
      [_r, u],
      u.local == false and
        u.is_active == true and u.invisible == false and fragment("? ~ ?", u.ap_id, "^https?://")
    )
    |> where(
      [_r, u],
      not (u.actor_type == @group_actor_type or
             (u.actor_type in ^@group_service_actor_types and
                fragment("? ~* ?", u.ap_id, ^@group_service_actor_regex)))
    )
    |> where(
      [_r, u],
      u.actor_type in ^@feed_actor_types or ilike(u.nickname, ^rss_nickname) or
        fragment(
          """
          concat_ws(' ', ?, ?, ?, ?) ~* ?
          """,
          u.ap_id,
          u.uri,
          u.inbox,
          u.shared_inbox,
          ^@feed_source_actor_regex
        ) or
        fragment(
          """
          exists (
            select 1 from instances i
            where lower(i.host) = ap_id_host(?)
              and lower(coalesce(i.metadata->>'software_name', '')) ~ ?
          )
          """,
          u.ap_id,
          ^@feed_source_platform_regex
        )
    )
    |> filter_reachable_followed_actor(reachability_datetime_threshold)
  end

  defp filter_reachable_followed_actor(query, reachability_datetime_threshold) do
    where(
      query,
      [_r, u],
      fragment(
        """
        not exists (
          select 1 from instances i
          where lower(i.host) = ap_id_host(?)
            and i.unreachable_since <= ?
        )
        """,
        u.ap_id,
        ^reachability_datetime_threshold
      )
    )
  end

  defp search_targets(kind, params) do
    query = search_param(params)

    fetched =
      if fetchable_identifier?(query) do
        case resolve_fetchable_identifier(query, kind) do
          {:ok, %User{} = user} -> [user]
          _ -> []
        end
      else
        []
      end

    known =
      if query == "" do
        []
      else
        term = "%#{query}%"

        kind_query(kind)
        |> where(
          [u],
          ilike(u.nickname, ^term) or ilike(u.name, ^term) or ilike(u.ap_id, ^term) or
            ilike(u.uri, ^term)
        )
        |> order_by([u], desc: u.updated_at)
        |> offset(^offset_param(params))
        |> limit(^limit_param(params))
        |> Repo.all()
      end

    [fetched, known]
    |> List.flatten()
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&matches_kind?(&1, kind))
    |> Enum.sort_by(&target_search_sort_key/1)
    |> Enum.take(limit_param(params))
  end

  def contact_interaction_score(%User{ap_id: ap_id} = user) when is_binary(ap_id) do
    local_follow_score(user) * 100 +
      local_notification_score(user) * 20 +
      local_direct_activity_score(user) * 15 +
      min(cached_remote_post_score(user), 50)
  end

  def contact_interaction_score(_), do: 0

  defp target_search_sort_key(%User{} = user) do
    {
      -contact_interaction_score(user),
      -sortable_datetime(user.updated_at),
      user.nickname || user.name || user.ap_id || ""
    }
  end

  defp sortable_datetime(%NaiveDateTime{} = datetime) do
    NaiveDateTime.diff(datetime, ~N[1970-01-01 00:00:00], :second)
  end

  defp sortable_datetime(_), do: 0

  defp local_follow_score(%User{id: id}) do
    FollowingRelationship
    |> join(:inner, [r], follower in User, on: r.follower_id == follower.id)
    |> where([r, follower], r.following_id == ^id and r.state == ^:follow_accept)
    |> where([_r, follower], follower.local == true and follower.is_active == true)
    |> Repo.aggregate(:count, :id)
  end

  defp local_notification_score(%User{ap_id: ap_id}) do
    Notification
    |> join(:inner, [notification], activity in Activity,
      on: notification.activity_id == activity.id
    )
    |> join(:inner, [notification, _activity], user in User, on: notification.user_id == user.id)
    |> where([_notification, activity, user], activity.actor == ^ap_id and user.local == true)
    |> Repo.aggregate(:count, :id)
  end

  defp local_direct_activity_score(%User{ap_id: ap_id}) do
    Activity
    |> join(:inner, [activity], user in User, on: user.ap_id == activity.actor)
    |> where([activity, user], activity.local == true and user.local == true)
    |> where(
      [activity, _user],
      fragment("?->>'object' = ?", activity.data, ^ap_id) or
        fragment("?->'to' \\? ?", activity.data, ^ap_id) or
        fragment("?->'cc' \\? ?", activity.data, ^ap_id)
    )
    |> Repo.aggregate(:count, :id)
  end

  defp cached_remote_post_score(%User{ap_id: ap_id}) do
    Activity
    |> where([activity], activity.local == false and activity.actor == ^ap_id)
    |> where([activity], fragment("?->>'type' = 'Create'", activity.data))
    |> Repo.aggregate(:count, :id)
  end

  defp kind_query(:group) do
    reachability_datetime_threshold = Instances.reachability_datetime_threshold()

    from(u in User,
      where:
        u.actor_type == @group_actor_type or
          (u.actor_type in ^@group_service_actor_types and
             fragment("? ~* ?", u.ap_id, ^@group_service_actor_regex)),
      where: u.is_active == true,
      where: u.invisible == false,
      where: fragment("? ~ ?", u.ap_id, "^https?://"),
      where:
        fragment(
          """
          not exists (
            select 1 from instances i
            where lower(i.host) = ap_id_host(?)
              and i.unreachable_since <= ?
          )
          """,
          u.ap_id,
          ^reachability_datetime_threshold
        )
    )
  end

  defp kind_query(:source) do
    reachability_datetime_threshold = Instances.reachability_datetime_threshold()
    rss_nickname = @rss_source_nickname_prefix <> "%"

    from(u in User,
      where: u.local == false,
      where: u.is_active == true,
      where: u.invisible == false,
      where: fragment("? ~ ?", u.ap_id, "^https?://"),
      where:
        not (u.actor_type == @group_actor_type or
               (u.actor_type in ^@group_service_actor_types and
                  fragment("? ~* ?", u.ap_id, ^@group_service_actor_regex))),
      where:
        u.actor_type in ^@feed_actor_types or ilike(u.nickname, ^rss_nickname) or
          fragment(
            """
            concat_ws(' ', ?, ?, ?, ?) ~* ?
            """,
            u.ap_id,
            u.uri,
            u.inbox,
            u.shared_inbox,
            ^@feed_source_actor_regex
          ),
      where:
        fragment(
          """
          not exists (
            select 1 from instances i
            where lower(i.host) = ap_id_host(?)
              and i.unreachable_since <= ?
          )
          """,
          u.ap_id,
          ^reachability_datetime_threshold
        )
    )
  end

  defp matches_kind?(user, :group), do: group?(user)
  defp matches_kind?(user, :source), do: source?(user)

  defp resolve_fetchable_identifier(identifier, :source), do: resolve_source(identifier)
  defp resolve_fetchable_identifier(identifier, :group), do: resolve_group(identifier)
  defp resolve_fetchable_identifier(identifier, kind), do: resolve_kind(identifier, kind)

  defp resolve_by_nickname(identifier) do
    case User.get_cached_by_nickname(identifier) do
      %User{} = user -> {:ok, user}
      _ -> ActivityPub.make_user_from_nickname(identifier)
    end
  end

  defp resolve_by_id_or_nickname(identifier) do
    case safe_get_cached_by_id(identifier) ||
           get_by_display_id(identifier) ||
           User.get_cached_by_nickname(identifier) do
      %User{} = user -> {:ok, user}
      _ -> {:error, :not_found}
    end
  end

  defp safe_get_cached_by_id(identifier) do
    User.get_cached_by_id(identifier)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp get_by_display_id(identifier) when is_binary(identifier) do
    User
    |> where([u], fragment("?::text = ?", u.id, ^identifier))
    |> Repo.one()
    |> case do
      %User{} = user ->
        User.set_cache(user)
        user

      _ ->
        nil
    end
  end

  defp fetchable_identifier?(identifier) do
    with {:ok, identifier} <- normalize_identifier(identifier) do
      (url?(identifier) and safe_fetch_url?(identifier)) or
        safe_webfinger_identifier?(identifier)
    else
      _ -> false
    end
  end

  defp normalize_identifier(identifier) when is_binary(identifier) do
    identifier =
      identifier
      |> String.replace(~r/\p{C}+/u, " ")
      |> String.trim()

    cond do
      identifier == "" ->
        {:error, :not_found}

      byte_size(identifier) > @max_target_identifier_bytes ->
        {:error, :not_found}

      not String.valid?(identifier) ->
        {:error, :not_found}

      String.contains?(identifier, <<0>>) ->
        {:error, :not_found}

      true ->
        {:ok, identifier}
    end
  end

  defp normalize_identifier(_), do: {:error, :not_found}

  defp unsafe_remote_identifier?(identifier),
    do: url?(identifier) and not safe_fetch_url?(identifier)

  defp safe_fetch_url?(identifier) do
    with %URI{scheme: scheme, host: host, path: path} when is_binary(host) <-
           URI.parse(identifier),
         true <- scheme in ["http", "https"],
         false <- String.contains?(path || "", ["..", "<", ">", "\\"]) do
      true
    else
      _ -> false
    end
  end

  defp safe_webfinger_identifier?(identifier) do
    String.contains?(identifier, "@") and
      not String.contains?(identifier, ["/", "\\", "<", ">", " "])
  end

  defp resolve_collection_source(identifier) when is_binary(identifier) do
    with true <- url?(identifier),
         {:ok, data} <- fetch_collection_json(identifier),
         true <- collection_source_object?(data),
         :ok <- refresh_instance_metadata(data["id"] || identifier),
         {:ok, owner_data} <- fetch_collection_source_owner(data),
         {:ok, attrs} <- collection_source_attrs(data, owner_data),
         {:ok, %User{} = source} <- upsert_collection_source(attrs) do
      {:ok, source}
    else
      _ -> {:error, :not_found}
    end
  end

  defp resolve_actor_source(identifier) when is_binary(identifier) do
    with true <- url?(identifier),
         {:ok, data} <- fetch_collection_json(identifier),
         true <- actor_source_object?(data),
         :ok <- refresh_instance_metadata(data["id"] || identifier),
         {:ok, attrs} <- actor_source_attrs(data),
         {:ok, %User{} = source} <- upsert_collection_source(attrs),
         true <- source?(source) do
      {:ok, source}
    else
      _ -> {:error, :not_found}
    end
  end

  defp resolve_rss_source(identifier) when is_binary(identifier) do
    with true <- url?(identifier),
         true <- safe_fetch_url?(identifier),
         {:ok, feed} <- fetch_rss_feed(identifier),
         canonical_url <- Map.get(feed, :canonical_url, identifier),
         {:ok, attrs} <- rss_source_attrs(canonical_url, feed),
         {:ok, %User{} = source} <- upsert_collection_source(attrs) do
      {:ok, source}
    else
      _ -> {:error, :not_found}
    end
  end

  defp resolve_group_actor(identifier) when is_binary(identifier) do
    cond do
      url?(identifier) -> resolve_group_actor_url(identifier)
      String.contains?(identifier, "@") -> resolve_group_webfinger(identifier)
      true -> {:error, :not_found}
    end
  end

  defp resolve_group_actor_url(url) when is_binary(url) do
    with true <- url?(url),
         {:ok, data} <- fetch_collection_json(url),
         true <- group_actor_object?(data),
         :ok <- refresh_instance_metadata(data["id"] || url),
         {:ok, attrs} <- actor_source_attrs(data),
         {:ok, %User{} = group} <- upsert_collection_source(attrs),
         true <- group?(group) do
      {:ok, group}
    else
      _ -> {:error, :not_found}
    end
  end

  defp resolve_group_webfinger(identifier) do
    with {:ok, _local, host, account} <- webfinger_identifier_parts(identifier),
         {:ok, %{"links" => links}} <-
           fetch_webfinger_json(
             "https://#{host}/.well-known/webfinger?resource=" <>
               URI.encode_www_form("acct:" <> account)
           ),
         self when is_binary(self) <- webfinger_self_link(links) do
      resolve_group_actor_url(self)
    else
      _ -> {:error, :not_found}
    end
  end

  defp resolve_source_webfinger_or_rss(identifier) do
    case resolve_source_webfinger(identifier) do
      {:ok, %User{} = source} -> {:ok, source}
      _ -> resolve_rss_source(identifier)
    end
  end

  defp resolve_source_webfinger(identifier) do
    with {:ok, _local, host, account} <- webfinger_identifier_parts(identifier),
         {:ok, %{"links" => links}} <-
           fetch_webfinger_json(
             "https://#{host}/.well-known/webfinger?resource=" <>
               URI.encode_www_form("acct:" <> account)
           ),
         self when is_binary(self) <- webfinger_self_link(links) do
      resolve_actor_source(self)
    else
      _ -> {:error, :not_found}
    end
  end

  defp webfinger_identifier_parts(identifier) when is_binary(identifier) do
    identifier =
      identifier
      |> String.trim()
      |> String.replace_prefix("acct:", "")
      |> String.trim_leading("@")
      |> String.trim_leading("!")
      |> String.trim_leading("&")

    case String.split(identifier, "@", parts: 2) do
      [local, host] when local != "" and host != "" ->
        if String.contains?(host, "@") do
          {:error, :not_found}
        else
          {:ok, local, host, local <> "@" <> host}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp webfinger_identifier_parts(_), do: {:error, :not_found}

  defp fetch_webfinger_json(url) do
    headers = [{"accept", "application/jrd+json, application/json"}]

    with {:ok, %{status: status, body: body}} when status in 200..299 <- HTTP.get(url, headers),
         {:ok, %{} = data} <- decode_source_items_body(body) do
      {:ok, data}
    else
      _ -> {:error, :not_found}
    end
  end

  defp webfinger_self_link(links) when is_list(links) do
    Enum.find_value(links, fn
      %{"rel" => "self", "href" => href} when is_binary(href) ->
        href

      _ ->
        nil
    end)
  end

  defp webfinger_self_link(_), do: nil

  defp group_actor_object?(%{"type" => @group_actor_type}), do: true

  defp group_actor_object?(%{"type" => type, "id" => id})
       when type in @group_service_actor_types and is_binary(id) do
    group_service_actor_url?(id)
  end

  defp group_actor_object?(_), do: false

  defp group_service_actor?(%User{} = user) do
    user
    |> actor_url()
    |> group_service_actor_url?()
  end

  defp group_service_actor_url?(url) when is_binary(url) do
    url = String.downcase(url)
    Enum.any?(@group_service_platform_fragments, &String.contains?(url, &1))
  end

  defp group_service_actor_url?(_), do: false

  defp actor_source_object?(%{"type" => type})
       when type in ["Application", "Organization", "Person", "Service"],
       do: true

  defp actor_source_object?(_), do: false

  defp refresh_instance_metadata(url) when is_binary(url) do
    with %URI{scheme: scheme, host: host} = uri
         when scheme in ["http", "https"] and is_binary(host) <-
           parse_uri(url) do
      uri
      |> Map.merge(%{path: "/", query: nil, fragment: nil})
      |> Instance.get_or_update_metadata()
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp refresh_instance_metadata(_), do: :ok

  defp collection_source_object?(%{"type" => type})
       when type in ["Library", "Collection", "OrderedCollection"],
       do: true

  defp collection_source_object?(_), do: false

  defp fetch_collection_source_owner(%{"attributedTo" => owner}) when is_binary(owner) do
    with true <- url?(owner),
         {:ok, %{"inbox" => inbox} = data} when is_binary(inbox) <-
           fetch_collection_json(owner) do
      {:ok, data}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_collection_source_owner(_), do: {:error, :not_found}

  defp fetch_collection_json(url) do
    case safe_signed_fetch(url) do
      {:ok, data} ->
        {:ok, data}

      _ ->
        fetch_public_json(url)
    end
  end

  defp fetch_public_json(url) do
    headers = [
      {"accept",
       "application/activity+json, application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\", application/json"}
    ]

    with {:ok, %{status: status, body: body}} when status in 200..299 <- HTTP.get(url, headers) do
      case decode_source_items_body(body) do
        {:ok, %{} = data} ->
          if data["id"] == url do
            {:ok, data}
          else
            fetch_public_alternate_json(url, body, headers)
          end

        _ ->
          fetch_public_alternate_json(url, body, headers)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_public_alternate_json(url, body, headers) when is_binary(body) do
    with alternate when is_binary(alternate) <- activity_alternate_url(url, body),
         true <- alternate != url,
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           HTTP.get(alternate, headers),
         {:ok, %{} = data} <- decode_source_items_body(body),
         true <- is_binary(data["id"]) do
      {:ok, data}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_public_alternate_json(_, _, _), do: {:error, :not_found}

  defp activity_alternate_url(base_url, body) do
    ~r/<link\b[^>]*>/i
    |> Regex.scan(body)
    |> Enum.find_value(fn [tag] ->
      rel = html_attr(tag, "rel") || ""
      type = html_attr(tag, "type") || ""
      href = html_attr(tag, "href")

      cond do
        !is_binary(href) ->
          nil

        not String.contains?(String.downcase(rel), "alternate") ->
          nil

        not String.contains?(String.downcase(type), ["activity+json", "ld+json"]) ->
          nil

        true ->
          base_url
          |> URI.merge(href)
          |> to_string()
      end
    end)
  end

  defp html_attr(tag, attr) do
    attr
    |> then(&Regex.run(~r/\b#{Regex.escape(&1)}\s*=\s*(['"])(.*?)\1/i, tag))
    |> case do
      [_all, _quote, value] -> html_unescape(value)
      _ -> nil
    end
  end

  defp collection_source_attrs(%{"id" => id} = data, owner_data) when is_binary(id) do
    with %URI{host: host} when is_binary(host) <- parse_uri(id),
         inbox when is_binary(inbox) <- owner_data["inbox"] do
      {:ok,
       %{
         ap_id: id,
         uri: collection_source_url(data) || id,
         nickname: collection_source_nickname(data, host),
         name: collection_source_name(data),
         bio: collection_source_summary(data),
         actor_type: "Service",
         inbox: inbox,
         shared_inbox: get_in(owner_data, ["endpoints", "sharedInbox"]),
         follower_address: collection_source_followers(data, id),
         is_discoverable: true
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp collection_source_attrs(_, _), do: {:error, :not_found}

  defp actor_source_attrs(%{"id" => id, "inbox" => inbox} = data)
       when is_binary(id) and is_binary(inbox) do
    with %URI{host: host} when is_binary(host) <- parse_uri(id),
         nickname when is_binary(nickname) <- actor_source_nickname(data, host, id) do
      {:ok,
       %{
         ap_id: id,
         uri: collection_source_url(data) || id,
         nickname: nickname,
         name: actor_source_name(data),
         bio: collection_source_summary(data),
         actor_type: actor_source_type(data),
         inbox: inbox,
         shared_inbox: get_in(data, ["endpoints", "sharedInbox"]),
         follower_address: collection_source_followers(data, id),
         following_address: actor_source_following(data),
         outbox_address: actor_source_outbox(data),
         public_key: actor_source_public_key(data),
         is_discoverable: actor_source_discoverable(data)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp actor_source_attrs(_), do: {:error, :not_found}

  defp rss_source_attrs(url, feed) when is_binary(url) do
    with %URI{host: host} when is_binary(host) <- parse_uri(url) do
      {:ok,
       %{
         ap_id: url,
         uri: url,
         nickname: rss_source_nickname(url, host),
         name: feed[:title] || host,
         bio: feed[:description] || "",
         raw_bio: feed[:description] || "",
         actor_type: "Service",
         follower_address: url <> "#followers",
         following_address: url <> "#following",
         is_discoverable: true
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp upsert_collection_source(%{ap_id: ap_id} = attrs) do
    case User.get_cached_by_ap_id(ap_id) do
      %User{} = source ->
        source
        |> User.remote_user_changeset(attrs)
        |> User.update_and_set_cache()

      _ ->
        %User{local: false}
        |> User.remote_user_changeset(attrs)
        |> insert_collection_source(attrs)
    end
  end

  defp insert_collection_source(changeset, %{ap_id: ap_id} = attrs) do
    case Repo.insert(changeset) do
      {:ok, %User{} = source} ->
        User.set_cache(source)

      {:error, %Ecto.Changeset{} = changeset} = error ->
        if user_unique_identity_error?(changeset) do
          update_existing_collection_source(ap_id, attrs)
        else
          error
        end
    end
  rescue
    e in Ecto.ConstraintError ->
      if user_unique_identity_error?(e) do
        update_existing_collection_source(ap_id, attrs)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp update_existing_collection_source(ap_id, attrs) do
    case User.get_by_ap_id(ap_id) do
      %User{} = source ->
        source
        |> User.remote_user_changeset(attrs)
        |> User.update_and_set_cache()

      _ ->
        {:error, :already_exists}
    end
  end

  defp collection_source_url(%{"url" => url}) when is_binary(url), do: url
  defp collection_source_url(%{"url" => %{"href" => url}}) when is_binary(url), do: url

  defp collection_source_url(%{"url" => urls}) when is_list(urls) do
    Enum.find_value(urls, fn
      %{"href" => url, "mediaType" => "text/html"} when is_binary(url) -> url
      %{"href" => url} when is_binary(url) -> url
      url when is_binary(url) -> url
      _ -> nil
    end)
  end

  defp collection_source_url(_), do: nil

  defp collection_source_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp collection_source_name(_), do: "Remote collection"

  defp collection_source_summary(%{"summary" => summary}) when is_binary(summary), do: summary

  defp collection_source_summary(%{"totalItems" => total_items}) when is_integer(total_items) do
    "<p>Remote collection with #{total_items} items.</p>"
  end

  defp collection_source_summary(_), do: ""

  defp collection_source_followers(%{"followers" => followers}, _id) when is_binary(followers),
    do: followers

  defp collection_source_followers(_data, id), do: id <> "/followers"

  defp collection_source_nickname(data, host) do
    local =
      data
      |> Map.get("id", "")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "collection-#{local}@#{host}"
  end

  defp actor_source_nickname(%{"preferredUsername" => preferred_username}, host, _id)
       when is_binary(preferred_username) and preferred_username != "" do
    "#{preferred_username}@#{host}"
  end

  defp actor_source_nickname(_data, host, id) do
    collection_source_nickname(%{"id" => id}, host)
  end

  defp actor_source_name(%{"name" => name}) when is_binary(name) and name != "", do: name

  defp actor_source_name(%{"preferredUsername" => preferred_username})
       when is_binary(preferred_username) and preferred_username != "" do
    preferred_username
  end

  defp actor_source_name(_), do: "Remote source"

  defp actor_source_type(%{"type" => type}) when is_binary(type), do: type
  defp actor_source_type(_), do: "Person"

  defp actor_source_following(%{"following" => following}) when is_binary(following),
    do: following

  defp actor_source_following(_), do: nil

  defp actor_source_outbox(%{"outbox" => outbox}) when is_binary(outbox), do: outbox
  defp actor_source_outbox(_), do: nil

  defp actor_source_public_key(%{"publicKey" => %{"publicKeyPem" => public_key}})
       when is_binary(public_key),
       do: public_key

  defp actor_source_public_key(_), do: nil

  defp rss_source_nickname(url, host) do
    local =
      url
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    @rss_source_nickname_prefix <> local <> "@" <> host
  end

  defp actor_source_discoverable(%{"discoverable" => discoverable}) when is_boolean(discoverable),
    do: discoverable

  defp actor_source_discoverable(%{"indexable" => indexable}) when is_boolean(indexable),
    do: indexable

  defp actor_source_discoverable(_), do: true

  defp rss_feed_url?(url) when is_binary(url) do
    uri = parse_uri(url)

    path =
      uri
      |> Map.get(:path, "")
      |> to_string()
      |> String.downcase()

    query =
      uri
      |> Map.get(:query, "")
      |> to_string()
      |> String.downcase()

    path
    |> String.split("/", trim: true)
    |> Enum.any?(&rss_feed_path_segment?/1)
    |> Kernel.||(String.ends_with?(path, [".xml", ".rss", ".atom"]))
    |> Kernel.||(Regex.match?(~r/(^|[&;])(format|type)=(rss|atom|feed)(&|$)/, query))
  end

  defp rss_feed_path_segment?(segment) do
    Regex.match?(~r/^(rss|atom|feeds?)([-_.0-9]|$)/, segment)
  end

  defp url?(identifier) do
    String.starts_with?(identifier, ["http://", "https://"])
  end

  defp search_param(params) do
    params
    |> param(:q)
    |> case do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp limit_param(params) do
    params
    |> param(:limit)
    |> parse_limit()
  end

  defp offset_param(params) do
    params
    |> param(:offset)
    |> parse_offset()
  end

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, to_string(key))
  end

  defp parse_limit(limit) when is_integer(limit), do: clamp_limit(limit)

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, _} -> clamp_limit(limit)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit

  defp clamp_limit(limit) when limit < 1, do: @default_limit
  defp clamp_limit(limit) when limit > @max_limit, do: @max_limit
  defp clamp_limit(limit), do: limit

  defp parse_offset(offset) when is_integer(offset), do: max(offset, 0)

  defp parse_offset(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {offset, _} -> max(offset, 0)
      _ -> 0
    end
  end

  defp parse_offset(_), do: 0

  defp followed_rss_sources_limit(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(1_000)
  end

  defp followed_rss_sources_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, _} -> followed_rss_sources_limit(limit)
      _ -> 200
    end
  end

  defp followed_rss_sources_limit(_), do: 200

  defp actor_url(%User{} = user), do: user.ap_id || user.uri || ""

  defp parse_uri(url) do
    URI.parse(url)
  rescue
    URI.Error -> %URI{}
  end

  @doc "Create a local ActivityPub Group actor for Threadiverse-compatible follows."
  def create_local_group(%User{} = owner, params) do
    display_name = local_group_text_param(params, "display_name") || "New group"
    note = local_group_text_param(params, "note") || ""
    base_nickname = local_group_base_nickname(params, display_name)

    with {:ok, nickname} <- unique_local_group_nickname(base_nickname),
         {:ok, keys} <- Pleroma.Keys.generate_rsa_pem() do
      ap_id = User.ap_id(%User{nickname: nickname})

      group = %User{
        actor_type: "Group",
        ap_id: ap_id,
        bio: note,
        email: nil,
        attributed_to_address: ap_id <> "/collections/moderators",
        featured_address: ap_id <> "/collections/featured",
        follower_address: ap_id <> "/followers",
        following_address: ap_id <> "/following",
        invisible: false,
        is_active: true,
        is_approved: true,
        is_confirmed: true,
        is_discoverable: local_group_truthy_param(params, "discoverable", true),
        is_indexable: local_group_truthy_param(params, "indexable", true),
        is_locked: local_group_locked_param(params),
        keys: keys,
        last_refreshed_at: NaiveDateTime.utc_now(),
        local: true,
        name: display_name,
        nickname: nickname,
        outbox_address: ap_id <> "/outbox",
        posting_restricted_to_mods:
          local_group_truthy_param(params, "posting_restricted_to_mods", false),
        raw_bio: note,
        uri: ap_id
      }

      with {:ok, %User{} = group} <- insert_local_group(group) do
        User.set_cache(group)
        GroupMembership.ensure_owner(group, owner)
        User.follow(owner, group, :follow_accept)
        {:ok, group}
      end
    end
  end

  defp insert_local_group(%User{} = group) do
    case Repo.insert(group) do
      {:ok, %User{} = group} ->
        {:ok, group}

      {:error, %Ecto.Changeset{} = changeset} = error ->
        if user_unique_identity_error?(changeset), do: {:error, :already_exists}, else: error
    end
  rescue
    e in Ecto.ConstraintError ->
      if user_unique_identity_error?(e) do
        {:error, :already_exists}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc "Update a local ActivityPub Group actor after checking group moderation rights."
  def update_local_group(%User{} = group, %User{} = actor, params) do
    with :ok <- GroupMembership.require_manager(actor, group),
         {:ok, group} <- update_group_profile(group, params) do
      {:ok, group}
    end
  end

  @doc "Delete a local ActivityPub Group actor after checking ownership rights."
  def delete_local_group(%User{} = group, %User{} = actor) do
    with :ok <- GroupMembership.require_owner(actor, group) do
      User.delete(group)
    end
  end

  defp update_group_profile(%User{} = group, params) do
    display_name = local_group_text_param(params, "display_name")
    note = local_group_text_param(params, "note")

    changes =
      %{}
      |> maybe_put(:name, display_name)
      |> maybe_put(:bio, note)
      |> maybe_put(:raw_bio, note)
      |> maybe_put(
        :is_discoverable,
        local_group_truthy_param(params, "discoverable", group.is_discoverable)
      )
      |> maybe_put(
        :is_indexable,
        local_group_truthy_param(params, "indexable", group.is_indexable)
      )
      |> maybe_put(
        :posting_restricted_to_mods,
        local_group_truthy_param(
          params,
          "posting_restricted_to_mods",
          group.posting_restricted_to_mods
        )
      )
      |> maybe_put(:is_locked, local_group_locked_param(params, group.is_locked))

    group
    |> Ecto.Changeset.change(changes)
    |> Repo.update()
    |> case do
      {:ok, group} ->
        User.set_cache(group)
        {:ok, group}

      error ->
        error
    end
  end

  @doc "Return native preview items for a remote ActivityPub group."
  def group_items(%User{} = group, params \\ %{}) do
    case group_items_result(group, params, nil) do
      {:ok, envelope} ->
        envelope

      {:error, _reason} ->
        empty_source_items()
    end
  end

  @doc "Return native preview items or a structured group-preview error."
  def group_items_result(group, params \\ %{}, reading_user \\ nil)

  def group_items_result(%User{local: true, actor_type: "Group"}, _params, _reading_user) do
    {:ok, empty_source_items()}
  end

  def group_items_result(%User{} = group, params, reading_user) do
    group_context = group_context(group)

    limit =
      params
      |> Map.get("limit", Map.get(params, :limit, 20))
      |> parse_source_item_limit()

    cached_remote_group_preview_result(group, limit, reading_user, fn ->
      remote_group_items_result(group, params, group_context, limit, reading_user)
    end)
  end

  defp remote_group_items_result(group, params, group_context, limit, reading_user) do
    with {:ok, collection} <- group_items_collection(group, params),
         {:ok, page} <- first_source_item_page(collection) do
      items =
        page
        |> source_collection_items()
        |> Enum.take(preview_candidate_limit(limit))
        |> Enum.map(&group_preview_item/1)
        |> Enum.map(&render_source_item(&1, group_context, reading_user, fetch_replies?: false))
        |> Enum.reject(&is_nil/1)
        |> unique_preview_items()
        |> Enum.take(limit)

      {:ok,
       %{
         items: items,
         next: source_page_next(page),
         total_items: collection_total_items(collection)
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cached_remote_group_preview_result(%User{} = group, limit, reading_user, fun) do
    cache_key = remote_group_preview_cache_key(group, limit, reading_user)

    case @cachex.get(@remote_group_preview_cache, cache_key) do
      {:ok, %{items: items} = envelope} when is_list(items) ->
        {:ok, envelope}

      _ ->
        cache_remote_group_preview_result(cache_key, fun.())
    end
  rescue
    _ ->
      fun.()
  catch
    _, _ ->
      fun.()
  end

  defp cache_remote_group_preview_result(cache_key, {:ok, %{items: items} = envelope} = result)
       when is_list(items) and items != [] do
    @cachex.put(@remote_group_preview_cache, cache_key, envelope)
    result
  end

  defp cache_remote_group_preview_result(_cache_key, result), do: result

  defp remote_group_preview_cache_key(%User{id: id}, limit, reading_user) do
    {id, limit, reading_user_cache_id(reading_user)}
  end

  defp reading_user_cache_id(%User{id: id}), do: id
  defp reading_user_cache_id(_), do: nil

  defp local_group_text_param(params, key) do
    value = Map.get(params, key, Map.get(params, String.to_atom(key)))

    if is_binary(value) do
      value
      |> String.trim()
      |> empty_string_to_nil()
    end
  end

  defp local_group_base_nickname(params, display_name) do
    (local_group_text_param(params, "name") || local_group_text_param(params, "slug") ||
       display_name)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> empty_string_to_nil()
    |> case do
      nil -> "group"
      nickname -> nickname
    end
  end

  defp unique_local_group_nickname(base_nickname) do
    unique_local_group_nickname(base_nickname, 0)
  end

  defp unique_local_group_nickname(_base_nickname, count) when count > 100 do
    {:error, :nickname_taken}
  end

  defp unique_local_group_nickname(base_nickname, count) do
    nickname =
      if count == 0 do
        base_nickname
      else
        "#{base_nickname}_#{count}"
      end

    if User.get_cached_by_nickname(nickname) do
      unique_local_group_nickname(base_nickname, count + 1)
    else
      {:ok, nickname}
    end
  end

  defp user_unique_identity_error?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:ap_id, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "users_ap_id_index" or
          Keyword.get(opts, :constraint) == :unique

      {:nickname, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "users_nickname_index" or
          Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end

  defp user_unique_identity_error?(%Ecto.ConstraintError{constraint: constraint})
       when constraint in ["users_ap_id_index", "users_nickname_index"],
       do: true

  defp user_unique_identity_error?(_), do: false

  defp local_group_truthy_param(params, key, default) do
    case Map.get(params, key, Map.get(params, String.to_atom(key), default)) do
      value when value in [true, "true", "1", 1, "on"] -> true
      value when value in [false, "false", "0", 0, "off"] -> false
      _ -> default
    end
  end

  defp local_group_locked_param(params, default \\ false) do
    case Map.get(params, "group_visibility", Map.get(params, :group_visibility)) do
      value when value in ["members_only", "private", "closed", "locked"] ->
        true

      value when value in ["everyone", "public", "open"] ->
        false

      _ ->
        local_group_truthy_param(params, "locked", default)
    end
  end

  defp maybe_put(changes, _key, nil), do: changes
  defp maybe_put(changes, key, value), do: Map.put(changes, key, value)

  @doc "Return native preview items for a remote source collection."
  def source_items(%User{} = source, params \\ %{}, reading_user \\ nil) do
    case source_items_result(source, params, reading_user) do
      {:ok, envelope} ->
        envelope

      {:error, _reason} ->
        empty_source_items()
    end
  end

  @doc "Return native preview items or a structured source-preview error."
  def source_items_result(%User{} = source, params \\ %{}, reading_user \\ nil) do
    source_context = source_context(source)

    limit =
      params
      |> Map.get("limit", Map.get(params, :limit, 20))
      |> parse_source_item_limit()

    cached_source_items_result(source, limit, reading_user, fn ->
      if rss_source?(source) do
        rss_source_items_result(source, source_context, limit, reading_user)
      else
        activitypub_source_items_result(source, source_context, limit, reading_user)
      end
    end)
  end

  defp cached_source_items_result(%User{} = source, limit, reading_user, fun) do
    cache_key = {:source_items, source.id, limit, reading_user_cache_id(reading_user)}

    case @cachex.get(@remote_group_preview_cache, cache_key) do
      {:ok, %{items: items} = envelope} when is_list(items) ->
        {:ok, envelope}

      _ ->
        cache_source_items_result(cache_key, fun.())
    end
  rescue
    _ ->
      fun.()
  catch
    _, _ ->
      fun.()
  end

  defp cache_source_items_result(cache_key, {:ok, %{items: items} = envelope} = result)
       when is_list(items) and items != [] do
    @cachex.put(@remote_group_preview_cache, cache_key, envelope, ttl: @source_items_cache_ttl)
    result
  end

  defp cache_source_items_result(_cache_key, result), do: result

  defp activitypub_source_items_result(source, source_context, limit, reading_user) do
    with {:ok, collection} <- source_items_collection(source),
         {:ok, page} <- first_source_item_page(collection) do
      items =
        page
        |> source_collection_items()
        |> Enum.take(preview_candidate_limit(limit))
        |> Enum.map(&source_preview_item/1)
        |> Enum.map(&render_source_item(&1, source_context, reading_user, fetch_replies?: false))
        |> Enum.reject(&is_nil/1)
        |> unique_preview_items()
        |> Enum.take(limit)

      if items == [] do
        source_preview_fallback_items(
          source,
          source_context,
          :empty_collection,
          collection_total_items(collection),
          limit,
          reading_user
        )
      else
        {:ok,
         %{
           items: items,
           next: source_page_next(page),
           total_items: collection_total_items(collection)
         }}
      end
    else
      {:error, reason} ->
        source_preview_fallback_items(source, source_context, reason, nil, limit, reading_user)
    end
  end

  defp rss_source_items_result(%User{} = source, source_context, limit, reading_user) do
    with {:ok, feed} <- fetch_rss_feed(source.ap_id || source.uri) do
      items =
        feed.items
        |> Enum.take(preview_candidate_limit(limit))
        |> Enum.map(&render_source_item(&1, source_context, reading_user, fetch_replies?: false))
        |> Enum.reject(&is_nil/1)
        |> unique_preview_items()
        |> Enum.take(limit)

      if items == [] do
        {:error, :empty_collection}
      else
        {:ok,
         %{
           items: items,
           next: nil,
           total_items: length(feed.items)
         }}
      end
    end
  end

  defp empty_source_items do
    %{
      items: [],
      next: nil,
      total_items: nil
    }
  end

  defp parse_source_item_limit(value) when is_integer(value) do
    value
    |> max(1)
    |> min(40)
  end

  defp parse_source_item_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, _} -> parse_source_item_limit(limit)
      _ -> 20
    end
  end

  defp parse_source_item_limit(_), do: 20

  defp preview_candidate_limit(limit), do: min(limit * 8, @max_limit)

  defp unique_preview_items(items) when is_list(items) do
    Enum.uniq_by(items, &preview_item_identity/1)
  end

  defp preview_item_identity(%{} = item) do
    Map.get(item, :id) ||
      Map.get(item, "id") ||
      Map.get(item, :url) ||
      Map.get(item, "url") ||
      :erlang.phash2(item)
  end

  defp source_items_collection(%User{} = source) do
    case source_items_fetch_json(source.ap_id || source.uri) do
      {:ok, %{} = actor_or_collection} ->
        case first_source_item_page(actor_or_collection) do
          {:ok, _page} ->
            {:ok, actor_or_collection}

          {:error, _reason} ->
            case source_outbox_collection(actor_or_collection) do
              {:ok, _collection} = result -> result
              _ -> source_stored_or_inferred_outbox_collection(source)
            end
        end

      {:error, :invalid_body} = error ->
        if source_profile(source) == "activitypub_profile" do
          case source_stored_or_inferred_outbox_collection(source) do
            {:ok, _collection} = result -> result
            _ -> error
          end
        else
          error
        end

      _ ->
        source_stored_or_inferred_outbox_collection(source)
    end
  end

  defp source_items_fetch_json(url) when is_binary(url) do
    case source_items_unsigned_fetch(url) do
      {:ok, %{} = data} ->
        mark_source_items_fetch_reachable(url)
        {:ok, data}

      {:error, :invalid_body} ->
        mark_source_items_fetch_invalid(url)
        {:error, :invalid_body}

      _ ->
        case safe_signed_fetch(url) do
          {:ok, %{} = data} ->
            mark_source_items_fetch_reachable(url)
            {:ok, data}

          _ ->
            {:error, :fetch_failed}
        end
    end
  end

  defp source_items_fetch_json(_), do: {:error, :invalid_source}

  defp mark_source_items_fetch_reachable(url) do
    Instances.record_success(url, source: "source_items")
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp mark_source_items_fetch_invalid(url) do
    Instances.set_consistently_unreachable(url)
    Instances.record_failure(url, :invalid_body, source: "source_items")
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_signed_fetch(url) do
    case Fetcher.fetch_and_contain_remote_object_from_id(url) do
      {:ok, %{} = data} ->
        {:ok, data}

      _ ->
        Fetcher.fetch_and_contain_remote_collection_from_id(url)
    end
  rescue
    _ ->
      {:error, :signed_fetch_failed}
  catch
    _, _ ->
      {:error, :signed_fetch_failed}
  end

  defp source_items_unsigned_fetch(url) do
    headers = [
      {"accept",
       "application/activity+json, application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\", application/json"}
    ]

    case HTTP.get(url, headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case decode_source_items_body(body) do
          {:ok, %{} = data} -> {:ok, data}
          _ -> {:error, :invalid_body}
        end

      {:ok, %{status: _status}} ->
        {:error, :fetch_failed}

      _ ->
        {:error, :fetch_failed}
    end
  rescue
    _ ->
      {:error, :fetch_failed}
  catch
    _, _ ->
      {:error, :fetch_failed}
  end

  defp decode_source_items_body(%{} = body), do: {:ok, body}

  defp decode_source_items_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> {:error, :invalid_body}
    end
  end

  defp decode_source_items_body(_), do: {:error, :invalid_body}

  defp fetch_rss_feed(url) when is_binary(url) do
    fetch_rss_feed(url, url, @rss_feed_redirect_limit)
  end

  defp fetch_rss_feed(_), do: {:error, :invalid_source}

  defp fetch_rss_feed(url, original_url, redirects_left)
       when is_binary(url) and is_binary(original_url) and redirects_left >= 0 do
    headers = [
      {"accept",
       "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.1"}
    ]

    case rss_http_get(url, headers) do
      {:ok, %{status: status, body: body} = response} when status in 200..299 ->
        with {:ok, feed} <- parse_rss_feed(body),
             true <- rss_feed_valid?(feed) do
          canonical_url = rss_response_url(response, url)
          feed = Map.put(feed, :canonical_url, canonical_url)
          mark_source_items_fetch_reachable(canonical_url)
          maybe_mark_rss_feed_redirect(original_url, canonical_url, feed)
          {:ok, feed}
        else
          _ -> {:error, :invalid_body}
        end

      {:ok, %{status: status, headers: response_headers}}
      when status in @rss_feed_redirect_statuses and redirects_left > 0 ->
        with location when is_binary(location) <- header_value(response_headers, "location"),
             redirected_url when is_binary(redirected_url) <- rss_redirect_url(url, location),
             true <- safe_fetch_url?(redirected_url) do
          fetch_rss_feed(redirected_url, original_url, redirects_left - 1)
        else
          _ -> {:error, :invalid_body}
        end

      {:ok, %{status: status}} when status in @rss_feed_gone_statuses ->
        mark_rss_feed_gone(original_url)
        {:error, :gone}

      _ ->
        {:error, :invalid_body}
    end
  rescue
    _ -> {:error, :invalid_body}
  catch
    _, _ -> {:error, :invalid_body}
  end

  defp rss_http_get(url, headers) do
    uri = URI.parse(url)
    adapter = Application.get_env(:tesla, :adapter)

    adapter_opts =
      uri
      |> AdapterHelper.options(pool: :media, follow_redirect: false, force_redirect: false)

    []
    |> Tesla.client(adapter)
    |> Tesla.get(url, headers: headers, opts: [adapter: adapter_opts])
  end

  defp header_value(headers, name) when is_list(headers) do
    name = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: value

      _ ->
        nil
    end)
  end

  defp header_value(_, _), do: nil

  defp rss_redirect_url(base_url, location) do
    if String.starts_with?(location, ["http://", "https://"]) do
      location
    else
      base_url
      |> URI.merge(location)
      |> to_string()
    end
  rescue
    _ -> nil
  end

  defp rss_response_url(%{url: response_url}, request_url) when is_binary(response_url) do
    if url?(response_url), do: response_url, else: request_url
  end

  defp rss_response_url(_response, request_url), do: request_url

  defp maybe_mark_rss_feed_redirect(url, url, _feed), do: :ok

  defp maybe_mark_rss_feed_redirect(original_url, canonical_url, feed)
       when is_binary(original_url) and is_binary(canonical_url) do
    Instances.record_redirect(original_url, canonical_url, source: "rss_feed")
    update_rss_source_url(original_url, canonical_url, feed)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp mark_rss_feed_gone(url) when is_binary(url) do
    Instances.record_gone(url, source: "rss_feed")
    retire_rss_source_url(url)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp update_rss_source_url(original_url, canonical_url, feed) do
    with %User{} = source <- User.get_cached_by_ap_id(original_url),
         nil <- User.get_cached_by_ap_id(canonical_url),
         {:ok, attrs} <- rss_source_attrs(canonical_url, feed) do
      source
      |> User.remote_user_changeset(attrs)
      |> User.update_and_set_cache()
    else
      %User{} ->
        retire_rss_source_url(original_url)

      _ ->
        :ok
    end
  end

  defp retire_rss_source_url(url) do
    User
    |> where([u], u.local == false and (u.ap_id == ^url or u.uri == ^url))
    |> Repo.all()
    |> Enum.each(fn source ->
      source
      |> Ecto.Changeset.change(%{
        is_active: false,
        invisible: true,
        is_discoverable: false,
        avatar: %{},
        banner: %{},
        tags: [],
        emoji: %{}
      })
      |> User.update_and_set_cache()
    end)
  end

  defp parse_rss_feed(body) when is_binary(body) do
    doc = SweetXml.parse(body, dtd: :none)
    rss_items = SweetXml.xpath(doc, ~x"//channel/item"l)
    atom_items = SweetXml.xpath(doc, ~x"//*[local-name()='entry']"l)

    feed = %{
      title: rss_feed_title(doc),
      description: rss_feed_description(doc),
      items: rss_feed_items(rss_items, atom_items)
    }

    {:ok, feed}
  rescue
    _ -> {:error, :invalid_body}
  catch
    _, _ -> {:error, :invalid_body}
  end

  defp parse_rss_feed(_), do: {:error, :invalid_body}

  defp rss_feed_valid?(%{title: title, items: items}) when is_list(items) do
    present_binary?(title) or items != []
  end

  defp rss_feed_valid?(_), do: false

  defp rss_feed_title(doc) do
    rss_xml_text(doc, ~x"//channel/title/text()"s) ||
      rss_xml_text(doc, ~x"//*[local-name()='feed']/*[local-name()='title']/text()"s) ||
      "RSS feed"
  end

  defp rss_feed_description(doc) do
    rss_xml_text(doc, ~x"//channel/description/text()"s) ||
      rss_xml_text(doc, ~x"//*[local-name()='feed']/*[local-name()='subtitle']/text()"s)
  end

  defp rss_feed_items(rss_items, _atom_items) when is_list(rss_items) and rss_items != [] do
    rss_items
    |> Enum.map(&rss_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp rss_feed_items(_rss_items, atom_items) when is_list(atom_items) do
    atom_items
    |> Enum.map(&atom_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp rss_feed_items(_, _), do: []

  defp rss_item(item) do
    title = rss_xml_text(item, ~x"./title/text()"s)
    link = rss_xml_text(item, ~x"./link/text()"s)
    guid = rss_xml_text(item, ~x"./guid/text()"s)
    summary = rss_xml_text(item, ~x"./description/text()"s)
    published = rss_datetime(rss_xml_text(item, ~x"./pubDate/text()"s))
    image = rss_enclosure_image(item)

    rss_item_map(%{
      "id" => guid || link,
      "type" => "Article",
      "name" => title,
      "summary" => summary,
      "url" => link,
      "published" => published,
      "image" => image
    })
  end

  defp atom_item(item) do
    title = rss_xml_text(item, ~x"./*[local-name()='title']/text()"s)
    link = atom_item_link(item)
    image = atom_media_image(item)

    summary =
      rss_xml_text(item, ~x"./*[local-name()='summary']/text()"s) ||
        rss_xml_text(item, ~x"./*[local-name()='content']/text()"s)

    published =
      rss_xml_text(item, ~x"./*[local-name()='published']/text()"s) ||
        rss_xml_text(item, ~x"./*[local-name()='updated']/text()"s)

    rss_item_map(%{
      "id" => rss_xml_text(item, ~x"./*[local-name()='id']/text()"s) || link,
      "type" => if(is_binary(image), do: "Image", else: "Article"),
      "name" => title,
      "summary" => summary,
      "url" => link,
      "published" => rss_datetime(published),
      "image" => image
    })
  end

  defp rss_item_map(item) do
    if Enum.any?(["id", "name", "summary", "url"], &present_binary?(item[&1])) do
      item
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()
    end
  end

  defp atom_item_link(item) do
    rss_xml_text(item, ~x"./*[local-name()='link'][@rel='alternate']/@href"s) ||
      rss_xml_text(item, ~x"./*[local-name()='link'][1]/@href"s)
  end

  defp atom_media_image(item) do
    item
    |> SweetXml.xpath(~x"./*[local-name()='content'][@url]"l)
    |> Enum.find_value(fn media ->
      url = rss_xml_text(media, ~x"./@url"s)
      media_type = rss_xml_text(media, ~x"./@type"s)

      cond do
        !is_binary(url) ->
          nil

        is_binary(media_type) and String.starts_with?(media_type, "image/") ->
          url

        is_nil(media_type) and String.match?(url, ~r/\.(avif|gif|jpe?g|png|webp)(\?|$)/i) ->
          url

        true ->
          nil
      end
    end)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp rss_enclosure_image(item) do
    url = rss_xml_text(item, ~x"./enclosure/@url"s)
    media_type = rss_xml_text(item, ~x"./enclosure/@type"s)

    cond do
      !is_binary(url) ->
        nil

      is_binary(media_type) and String.starts_with?(media_type, "image/") ->
        url

      is_nil(media_type) and String.match?(url, ~r/\.(avif|gif|jpe?g|png|webp)(\?|$)/i) ->
        url

      true ->
        nil
    end
  end

  defp rss_xml_text(node, xpath) do
    node
    |> SweetXml.xpath(xpath)
    |> rss_normalize_text()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp rss_normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> empty_string_to_nil()
    |> html_unescape()
  end

  defp rss_normalize_text(_), do: nil

  defp rss_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_iso8601(datetime)

      _ ->
        rss_http_datetime(value)
    end
  end

  defp rss_datetime(_), do: nil

  defp rss_http_datetime(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, minute, second}} ->
        with {:ok, date} <- Date.new(year, month, day),
             {:ok, time} <- Time.new(hour, minute, second),
             {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
          DateTime.to_iso8601(datetime)
        else
          _ -> value
        end

      _ ->
        value
    end
  rescue
    _ -> value
  catch
    _, _ -> value
  end

  defp first_source_item_page(%{"first" => first}) when is_binary(first) do
    source_items_fetch_json(first)
  end

  defp first_source_item_page(%{"first" => %{} = first}), do: {:ok, first}

  defp first_source_item_page(%{"orderedItems" => items} = collection) when is_list(items) do
    {:ok, collection}
  end

  defp first_source_item_page(%{"items" => items} = collection) when is_list(items) do
    {:ok, collection}
  end

  defp first_source_item_page(_), do: {:error, :empty_collection}

  defp source_collection_items(%{"orderedItems" => items}) when is_list(items), do: items

  defp source_collection_items(%{"items" => items}) when is_list(items), do: items

  defp source_collection_items(_), do: []

  defp source_outbox_collection(%{"outbox" => outbox}) when is_binary(outbox) do
    source_items_fetch_json(outbox)
  end

  defp source_outbox_collection(%{"outbox" => %{} = outbox}), do: {:ok, outbox}
  defp source_outbox_collection(_), do: {:error, :empty_collection}

  defp source_stored_or_inferred_outbox_collection(%User{} = source) do
    with outbox when is_binary(outbox) <- source_outbox_url(source),
         true <- safe_fetch_url?(outbox) do
      source_items_fetch_json(outbox)
    else
      _ -> {:error, :empty_collection}
    end
  end

  defp source_outbox_url(%User{outbox_address: outbox}) when is_binary(outbox) do
    outbox
    |> String.trim()
    |> empty_string_to_nil()
  end

  defp source_outbox_url(%User{ap_id: ap_id}) when is_binary(ap_id) do
    with %URI{scheme: scheme, host: host, path: path} = uri
         when scheme in ["http", "https"] and is_binary(host) and is_binary(path) <-
           parse_uri(ap_id),
         false <- String.ends_with?(path, "/outbox") do
      uri
      |> Map.put(:path, String.trim_trailing(path, "/") <> "/outbox")
      |> Map.put(:query, nil)
      |> Map.put(:fragment, nil)
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  defp source_outbox_url(_), do: nil

  defp source_context(%User{} = source) do
    platform = source_platform(source)
    kind = source_kind_for_platform(source, platform)

    %{
      source: source,
      platform: platform,
      source_kind: kind,
      source_kind_label: source_kind_label_for_kind(kind),
      capabilities: source_capability_labels(kind, platform.platform)
    }
  end

  defp group_context(%User{} = group) do
    platform = group_platform(group)
    kind = group_kind(group)

    %{
      platform: platform,
      source_kind: kind,
      source_kind_label: group_kind_label_for_kind(kind),
      capabilities: group_capability_labels(kind, platform.platform)
    }
  end

  defp fetch_remote_group_member_count(%User{follower_address: followers_url} = group)
       when is_binary(followers_url) do
    with {:ok, %{} = followers} <- source_items_fetch_json(followers_url),
         count when is_integer(count) <- collection_total_items(followers) do
      maybe_cache_group_member_count(group, count)
      count
    else
      _ -> nil
    end
  end

  defp fetch_remote_group_member_count(_), do: nil

  defp fetch_remote_group_moderator_count(%User{attributed_to_address: moderators_url} = group)
       when is_binary(moderators_url) do
    with {:ok, %{} = moderators} <- source_items_fetch_json(moderators_url),
         count when is_integer(count) <- collection_total_items(moderators) do
      maybe_cache_group_moderator_count(group, count)
      count
    else
      _ -> nil
    end
  end

  defp fetch_remote_group_moderator_count(_), do: nil

  defp maybe_cache_group_member_count(%User{follower_count: count}, count), do: :ok

  defp maybe_cache_group_member_count(%User{} = group, count) when is_integer(count) do
    group
    |> Ecto.Changeset.change(%{follower_count: count})
    |> Repo.update()
    |> case do
      {:ok, group} -> User.set_cache(group)
      _ -> :ok
    end
  end

  defp maybe_cache_group_moderator_count(%User{moderator_count: count}, count), do: :ok

  defp maybe_cache_group_moderator_count(%User{} = group, count) when is_integer(count) do
    group
    |> Ecto.Changeset.change(%{moderator_count: count})
    |> Repo.update()
    |> case do
      {:ok, group} -> User.set_cache(group)
      _ -> :ok
    end
  end

  defp group_items_collection(%User{} = group, params) do
    case group_platform_items_collection(group, params) do
      {:ok, %{} = collection} ->
        {:ok, collection}

      _ ->
        case stored_group_outbox_collection(group) do
          {:ok, %{} = collection} ->
            {:ok, collection}

          {:error, _} ->
            with {:ok, %{} = actor} <- source_items_fetch_json(group.ap_id || group.uri) do
              case first_source_item_page(actor) do
                {:ok, _page} ->
                  {:ok, actor}

                {:error, _reason} ->
                  group_outbox_collection(actor)
              end
            end
        end
    end
  end

  defp stored_group_outbox_collection(%User{outbox_address: outbox}) when is_binary(outbox) do
    with {:ok, %{} = collection} <- source_items_fetch_json(outbox) do
      {:ok, collection}
    end
  end

  defp stored_group_outbox_collection(_), do: {:error, :missing_outbox}

  defp group_platform_items_collection(%User{} = group, params) do
    case group_platform(group).platform do
      "lemmy" -> threadiverse_api_collection(group, "api/v3", params)
      "piefed" -> threadiverse_api_collection(group, "api/alpha", params)
      "mbin" -> mbin_api_collection(group)
      "discourse" -> discourse_api_collection(group, params)
      _ -> {:error, :unsupported_platform}
    end
  end

  defp threadiverse_api_collection(%User{} = group, api_path, params) do
    with %URI{scheme: scheme, host: host, path: path} when is_binary(host) <-
           parse_uri(group.ap_id || group.uri),
         community when is_binary(community) <- threadiverse_community_name(path),
         url <-
           "#{scheme || "https"}://#{host}/#{api_path}/post/list?community_name=" <>
             URI.encode_www_form(community) <> "&sort=New&limit=20",
         {:ok, %{"posts" => posts}} when is_list(posts) <- source_items_fetch_json(url),
         items <-
           posts
           |> maybe_filter_threadiverse_featured_posts(params)
           |> Enum.map(&threadiverse_post_item/1)
           |> Enum.reject(&is_nil/1),
         true <- items != [] do
      {:ok, %{"orderedItems" => items, "totalItems" => length(items)}}
    else
      _ -> {:error, :empty_collection}
    end
  end

  defp threadiverse_community_name(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["c", community | _] -> community
      ["communities", community | _] -> community
      _ -> nil
    end
  end

  defp threadiverse_community_name(_), do: nil

  defp maybe_filter_threadiverse_featured_posts(posts, params) do
    if truthy_source_item_param?(params, "include_featured") do
      posts
    else
      Enum.reject(posts, &threadiverse_featured_post?/1)
    end
  end

  defp truthy_source_item_param?(params, key) do
    Map.get(params, key, Map.get(params, String.to_atom(key))) in [true, "true", "1", 1]
  end

  defp threadiverse_featured_post?(%{"post" => %{} = post}) do
    Enum.any?(["featured_community", "featured_local", "stickied", "pinned"], fn key ->
      post[key] in [true, "true", "1", 1]
    end)
  end

  defp threadiverse_featured_post?(_), do: false

  defp threadiverse_post_item(%{"post" => %{} = post} = view) do
    creator = Map.get(view, "creator", %{})

    %{
      "id" => post["ap_id"] || post["url"],
      "type" => threadiverse_post_type(post),
      "name" => post["name"] || post["title"],
      "summary" => post["embed_description"],
      "content" => post["body"] || post["embed_description"],
      "url" => post["ap_id"] || post["url"],
      "published" => post["published"],
      "attributedTo" => creator["actor_id"],
      "image" => threadiverse_post_image(post),
      "commentsCount" => threadiverse_post_comment_count(view)
    }
  end

  defp threadiverse_post_item(_), do: nil

  defp threadiverse_post_type(%{"post_type" => "Image"}), do: "Image"
  defp threadiverse_post_type(%{"post_type" => "Video"}), do: "Video"
  defp threadiverse_post_type(%{"url" => url}) when is_binary(url), do: "Page"
  defp threadiverse_post_type(_), do: "Note"

  defp threadiverse_post_image(%{"thumbnail_url" => thumbnail}) when is_binary(thumbnail),
    do: thumbnail

  defp threadiverse_post_image(%{"small_thumbnail_url" => thumbnail}) when is_binary(thumbnail),
    do: thumbnail

  defp threadiverse_post_image(_), do: nil

  defp threadiverse_post_comment_count(%{"counts" => %{} = counts}) do
    normalized_integer(
      counts["comments"] || counts["comments_count"] || counts["comment_count"] ||
        counts["replies"] || counts["replies_count"]
    )
  end

  defp threadiverse_post_comment_count(%{"post" => %{} = post}) do
    normalized_integer(
      post["comments"] || post["comments_count"] || post["comment_count"] ||
        post["replies"] || post["replies_count"]
    )
  end

  defp threadiverse_post_comment_count(_), do: nil

  defp mbin_api_collection(%User{} = group) do
    with %URI{scheme: scheme, host: host, path: path} when is_binary(host) <-
           parse_uri(group.ap_id || group.uri),
         magazine when is_binary(magazine) <- mbin_magazine_name(path),
         base_url <- "#{scheme || "https"}://#{host}",
         url <- base_url <> "/m/" <> URI.encode_www_form(magazine) <> "/newest",
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           HTTP.get(url, [{"accept", "text/html, application/xhtml+xml"}]),
         items <- mbin_html_items(base_url, magazine, body),
         true <- items != [] do
      {:ok, %{"orderedItems" => items, "totalItems" => length(items)}}
    else
      _ -> {:error, :empty_collection}
    end
  end

  defp discourse_api_collection(%User{} = group, params) do
    limit =
      params
      |> Map.get("limit", Map.get(params, :limit, 20))
      |> parse_source_item_limit()

    with url when is_binary(url) <- discourse_category_json_url(group),
         {:ok, %{"topic_list" => %{"topics" => topics} = topic_list}} when is_list(topics) <-
           source_items_fetch_json(url),
         items <-
           topics
           |> maybe_filter_discourse_featured_topics(params)
           |> Enum.take(preview_candidate_limit(limit))
           |> Enum.map(&discourse_topic_item(group, &1))
           |> Enum.reject(&is_nil/1),
         true <- items != [] do
      collection = %{
        "orderedItems" => items,
        "totalItems" => length(items)
      }

      {:ok, maybe_put_discourse_next(collection, url, topic_list["more_topics_url"])}
    else
      _ -> {:error, :empty_collection}
    end
  end

  defp discourse_category_json_url(%User{} = group) do
    [group.uri, group.ap_id]
    |> Enum.find_value(&discourse_category_json_url/1)
  end

  defp discourse_category_json_url(url, opts \\ [])

  defp discourse_category_json_url(url, opts) when is_binary(url) do
    with %URI{scheme: scheme, host: host, path: path} = uri
         when scheme in ["http", "https"] and is_binary(host) and is_binary(path) <-
           parse_uri(url),
         true <- String.starts_with?(path, "/c/") do
      query =
        if Keyword.get(opts, :keep_query, false) do
          uri.query
        end

      path =
        path
        |> String.trim_trailing("/")
        |> discourse_json_path()

      uri
      |> Map.merge(%{path: path, query: query, fragment: nil})
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  defp discourse_category_json_url(_, _), do: nil

  defp discourse_json_path(path) when is_binary(path) do
    cond do
      String.ends_with?(path, ".json") -> path
      String.ends_with?(path, "/l/latest") -> path <> ".json"
      true -> path <> ".json"
    end
  end

  defp maybe_put_discourse_next(collection, base_url, more_topics_url)
       when is_binary(more_topics_url) do
    next_url =
      base_url
      |> URI.merge(more_topics_url)
      |> URI.to_string()
      |> discourse_category_json_url(keep_query: true)

    if is_binary(next_url) do
      Map.put(collection, "next", next_url)
    else
      collection
    end
  rescue
    _ -> collection
  end

  defp maybe_put_discourse_next(collection, _base_url, _more_topics_url), do: collection

  defp maybe_filter_discourse_featured_topics(topics, params) do
    if truthy_source_item_param?(params, "include_featured") do
      topics
    else
      Enum.reject(topics, &discourse_featured_topic?/1)
    end
  end

  defp discourse_featured_topic?(%{} = topic) do
    Enum.any?(["pinned", "pinned_globally"], fn key ->
      topic[key] in [true, "true", "1", 1]
    end)
  end

  defp discourse_featured_topic?(_), do: false

  defp discourse_topic_item(%User{} = group, %{"id" => id} = topic) do
    with topic_id when is_integer(topic_id) <- normalized_integer(id),
         url when is_binary(url) <- discourse_topic_url(group, topic, topic_id),
         title when is_binary(title) <- discourse_topic_title(topic) do
      post = discourse_topic_first_ap_post(url)
      ap_object_id = discourse_post_ap_object_id(post)

      %{
        "id" => url,
        "type" => "Article",
        "activity_pub_object_id" => ap_object_id,
        "activity_pub_object_type" => discourse_post_ap_object_type(post),
        "name" => title,
        "summary" => discourse_topic_summary(topic),
        "content" => discourse_topic_summary(topic),
        "url" => url,
        "published" => discourse_topic_published(topic),
        "updated" => discourse_topic_updated(topic),
        "attributedTo" => discourse_post_ap_actor(post),
        "image" => discourse_absolute_url(group, topic["image_url"]),
        "commentsCount" => discourse_topic_comment_count(topic)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()
    end
  end

  defp discourse_topic_item(_, _), do: nil

  defp discourse_topic_first_ap_post(topic_url) when is_binary(topic_url) do
    with {:ok, %{"post_stream" => %{"posts" => posts}}} when is_list(posts) <-
           source_items_fetch_json(topic_url <> ".json") do
      Enum.find(posts, &present_binary?(&1["activity_pub_object_id"])) || List.first(posts)
    else
      _ -> nil
    end
  end

  defp discourse_post_ap_object_id(%{"activity_pub_object_id" => id}) when is_binary(id) do
    id
    |> String.trim()
    |> empty_string_to_nil()
  end

  defp discourse_post_ap_object_id(_), do: nil

  defp discourse_post_ap_object_type(%{"activity_pub_object_type" => type})
       when type in @source_item_status_types,
       do: type

  defp discourse_post_ap_object_type(_), do: nil

  defp discourse_post_ap_actor(%{"activity_pub_attributed_to" => actor}) when is_binary(actor),
    do: actor

  defp discourse_post_ap_actor(%{"activity_pub_actor" => actor}) when is_binary(actor), do: actor
  defp discourse_post_ap_actor(_), do: nil

  defp discourse_topic_url(%User{} = group, topic, topic_id) do
    with base_url when is_binary(base_url) <- discourse_base_url(group) do
      slug =
        topic["slug"]
        |> discourse_text()
        |> discourse_safe_slug()

      path =
        if is_binary(slug) do
          "/t/#{slug}/#{topic_id}"
        else
          "/t/#{topic_id}"
        end

      base_url
      |> URI.merge(path)
      |> URI.to_string()
    end
  rescue
    _ -> nil
  end

  defp discourse_base_url(%User{} = group) do
    [group.uri, group.ap_id]
    |> Enum.find_value(fn url ->
      with %URI{scheme: scheme, host: host} = uri
           when scheme in ["http", "https"] and is_binary(host) <- parse_uri(url) do
        uri
        |> Map.merge(%{path: "/", query: nil, fragment: nil})
        |> URI.to_string()
      end
    end)
  end

  defp discourse_absolute_url(_group, nil), do: nil

  defp discourse_absolute_url(%User{} = group, url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      url
    else
      with base_url when is_binary(base_url) <- discourse_base_url(group) do
        base_url
        |> URI.merge(url)
        |> URI.to_string()
      end
    end
  rescue
    _ -> nil
  end

  defp discourse_topic_title(%{} = topic) do
    discourse_text(topic["title"]) || discourse_text(topic["fancy_title"])
  end

  defp discourse_topic_summary(%{} = topic) do
    discourse_text(topic["excerpt"]) || discourse_text(topic["fancy_title"]) ||
      discourse_text(topic["title"])
  end

  defp discourse_text(value) when is_binary(value) do
    value
    |> source_item_strip_html()
    |> HtmlEntities.decode()
    |> HtmlEntities.decode()
    |> String.trim()
    |> empty_string_to_nil()
  end

  defp discourse_text(_), do: nil

  defp discourse_safe_slug(slug) when is_binary(slug) do
    slug
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
    |> empty_string_to_nil()
  end

  defp discourse_safe_slug(_), do: nil

  defp discourse_topic_published(%{} = topic) do
    discourse_text(topic["created_at"]) || discourse_topic_updated(topic)
  end

  defp discourse_topic_updated(%{} = topic) do
    discourse_text(topic["last_posted_at"]) || discourse_text(topic["bumped_at"])
  end

  defp discourse_topic_comment_count(%{} = topic) do
    [
      normalized_integer(topic["reply_count"]),
      discourse_posts_count_to_replies(topic["posts_count"]),
      discourse_posts_count_to_replies(topic["highest_post_number"])
    ]
    |> Enum.find(&is_integer/1)
  end

  defp discourse_posts_count_to_replies(count) do
    with count when is_integer(count) and count > 0 <- normalized_integer(count) do
      count - 1
    end
  end

  defp mbin_magazine_name(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["m", magazine | _] -> magazine
      _ -> nil
    end
  end

  defp mbin_magazine_name(_), do: nil

  defp mbin_html_items(base_url, magazine, body) when is_binary(body) do
    ~r/<article\b[^>]*>(.*?)<\/article>/is
    |> Regex.scan(body)
    |> Enum.map(fn [_all, article] -> mbin_html_post_item(base_url, magazine, article) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(20)
  end

  defp mbin_html_items(_, _, _), do: []

  defp mbin_html_post_item(base_url, magazine, article) do
    article
    |> mbin_html_post_link(magazine)
    |> case do
      {href, title} ->
        url =
          base_url
          |> URI.merge(href)
          |> to_string()

        id = mbin_activity_url(url) || url

        %{
          "id" => id,
          "type" => "Page",
          "name" => title,
          "summary" => mbin_html_post_summary(article),
          "url" => url
        }

      _ ->
        nil
    end
  end

  defp mbin_html_post_link(article, magazine) do
    ~r/<a\b[^>]*href\s*=\s*(['"])(.*?)\1[^>]*>(.*?)<\/a>/is
    |> Regex.scan(article)
    |> Enum.find_value(fn [_all, _quote, href, title_html] ->
      title =
        title_html
        |> source_item_strip_html()
        |> html_unescape()

      cond do
        not String.contains?(href, "/m/#{magazine}/t/") ->
          nil

        String.contains?(href, ["#", "/votes/"]) ->
          nil

        title in ["", nil, "Copy Mbin URL", "Copy original URL", "Open original URL", "Show more"] ->
          nil

        true ->
          {href, source_item_text_limit(title, @source_item_title_limit)}
      end
    end)
  end

  defp mbin_activity_url(url) when is_binary(url) do
    uri = parse_uri(url)

    case String.split(uri.path || "", "/", trim: true) do
      ["m", magazine, "t", thread | _] ->
        %{uri | path: "/m/#{magazine}/t/#{thread}", query: nil, fragment: nil}
        |> URI.to_string()

      _ ->
        nil
    end
  end

  defp mbin_activity_url(_), do: nil

  defp mbin_html_post_summary(article) do
    case Regex.run(
           ~r/<div\b[^>]*class\s*=\s*(['"])[^'"]*content short-desc[^'"]*\1[^>]*>(.*?)<\/div>/is,
           article
         ) do
      [_all, _quote, summary] ->
        summary
        |> source_item_strip_html()
        |> html_unescape()

      _ ->
        nil
    end
  end

  defp group_outbox_collection(%{"outbox" => outbox}) when is_binary(outbox) do
    source_items_fetch_json(outbox)
  end

  defp group_outbox_collection(%{"outbox" => %{} = outbox}), do: {:ok, outbox}
  defp group_outbox_collection(_), do: {:error, :empty_collection}

  @preview_unwrap_depth 3

  defp group_preview_item(item), do: group_preview_item(item, @preview_unwrap_depth)

  defp group_preview_item(%{"type" => type}, _depth)
       when type in @non_content_activity_types,
       do: nil

  defp group_preview_item(%{"type" => type, "object" => object} = activity, depth)
       when type in ["Add", "Create", "Announce", "Update"] do
    object
    |> group_preview_object(depth)
    |> group_preview_inherit_activity(activity)
  end

  defp group_preview_item(item, depth), do: group_preview_object(item, depth)

  defp group_preview_object(%{"type" => type, "object" => _object} = activity, depth)
       when type in ["Add", "Create", "Announce", "Update"] and depth > 0 do
    group_preview_item(activity, depth - 1)
  end

  defp group_preview_object(%{"type" => type}, _depth) when type in @non_content_activity_types,
    do: nil

  defp group_preview_object(%{} = object, _depth), do: object

  defp group_preview_object(url, depth) when is_binary(url) and depth > 0 do
    case source_items_fetch_json(url) do
      {:ok, %{} = object} -> group_preview_item(object, depth - 1)
      _ -> html_preview_object(url) || url
    end
  end

  defp group_preview_object(object, _depth), do: object

  defp group_preview_inherit_activity(%{} = object, %{} = activity) do
    object
    |> Map.put_new("published", activity["published"])
    |> Map.put_new("attributedTo", activity["actor"])
  end

  defp group_preview_inherit_activity(object, _activity), do: object

  defp source_preview_item(item), do: source_preview_item(item, @preview_unwrap_depth)

  defp source_preview_item(%{"type" => type}, _depth)
       when type in @non_content_activity_types,
       do: nil

  defp source_preview_item(%{"type" => "Announce"}, _depth), do: nil

  defp source_preview_item(%{"type" => type, "object" => object} = activity, depth)
       when type in ["Add", "Create", "Update"] do
    object
    |> source_preview_object(depth)
    |> source_preview_inherit_activity(activity)
  end

  defp source_preview_item(item, depth), do: source_preview_object(item, depth)

  defp source_preview_object(%{"type" => type, "object" => _object} = activity, depth)
       when type in ["Add", "Create", "Update"] and depth > 0 do
    source_preview_item(activity, depth - 1)
  end

  defp source_preview_object(%{"type" => type}, _depth) when type in @non_content_activity_types,
    do: nil

  defp source_preview_object(%{} = object, _depth), do: object

  defp source_preview_object(url, depth) when is_binary(url) and depth > 0 do
    case source_items_fetch_json(url) do
      {:ok, %{} = object} -> source_preview_item(object, depth - 1)
      _ -> html_preview_object(url) || url
    end
  end

  defp source_preview_object(object, _depth), do: object

  defp html_preview_object(url) do
    headers = [{"accept", "text/html, application/xhtml+xml"}]

    with {:ok, %{status: status, body: body}} when status in 200..299 <- HTTP.get(url, headers),
         title when is_binary(title) <- html_preview_title(body) do
      %{
        "id" => url,
        "type" => "Page",
        "name" => title,
        "summary" => html_preview_summary(body),
        "url" => url
      }
    else
      _ -> nil
    end
  rescue
    _ ->
      nil
  catch
    _, _ ->
      nil
  end

  defp html_preview_title(body) when is_binary(body) do
    html_meta(body, "og:title") ||
      html_meta(body, "twitter:title") ||
      html_title(body)
  end

  defp html_preview_title(_), do: nil

  defp html_preview_summary(body) when is_binary(body) do
    html_meta(body, "og:description") ||
      html_meta(body, "description") ||
      html_meta(body, "twitter:description")
  end

  defp html_meta(body, name) do
    ~r/<meta\b[^>]*(?:property|name)\s*=\s*(['"])#{Regex.escape(name)}\1[^>]*>/i
    |> Regex.run(body)
    |> case do
      [tag | _] -> html_attr(tag, "content")
      _ -> nil
    end
    |> empty_string_to_nil()
  end

  defp html_title(body) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, body) do
      [_all, title] ->
        title
        |> source_item_strip_html()
        |> html_unescape()
        |> source_item_text_limit(@source_item_title_limit)

      _ ->
        nil
    end
  end

  defp html_unescape(value) when is_binary(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
  end

  defp html_unescape(value), do: value

  defp source_preview_inherit_activity(%{} = object, %{} = activity) do
    object
    |> Map.put_new("published", activity["published"])
    |> Map.put_new("attributedTo", activity["actor"])
  end

  defp source_preview_inherit_activity(object, _activity), do: object

  defp source_preview_fallback_items(
         %User{} = source,
         source_context,
         reason,
         total_items,
         limit,
         reading_user
       ) do
    case owncast_stream_fallback_items(source, source_context, total_items) do
      {:ok, envelope} ->
        {:ok, envelope}

      _ ->
        case pixelfed_atom_fallback_items(
               source,
               source_context,
               limit,
               reading_user,
               total_items
             ) do
          {:ok, envelope} ->
            {:ok, envelope}

          _ ->
            case cached_source_status_fallback_items(
                   source,
                   source_context,
                   limit,
                   reading_user,
                   total_items
                 ) do
              {:ok, envelope} -> {:ok, envelope}
              _ -> source_actor_fallback_items(source, source_context, reason, total_items)
            end
        end
    end
  end

  defp owncast_stream_fallback_items(
         %User{} = source,
         %{platform: %{platform: "owncast"}} = source_context,
         total_items
       ) do
    with {:ok, %{} = status} <- owncast_fetch_json(source, "/api/status"),
         directory <- owncast_optional_json(source, "/api/yp"),
         %{} = item_data <- owncast_stream_status_item(source, status, directory),
         %{} = item <- render_source_item(item_data, source_context) do
      {:ok,
       %{
         items: [item],
         next: nil,
         total_items: total_items || 1
       }}
    else
      _ -> {:error, :empty_collection}
    end
  end

  defp owncast_stream_fallback_items(_, _, _), do: {:error, :not_owncast}

  defp cached_source_status_fallback_items(
         %User{} = source,
         source_context,
         limit,
         reading_user,
         total_items
       ) do
    items =
      source
      |> cached_source_status_query(preview_candidate_limit(limit))
      |> Repo.all()
      |> Enum.map(&cached_source_status_item(&1, source_context, reading_user))
      |> Enum.reject(&is_nil/1)
      |> unique_preview_items()
      |> Enum.take(limit)

    if items == [] do
      {:error, :empty_collection}
    else
      {:ok,
       %{
         items: items,
         next: nil,
         total_items: total_items || length(items)
       }}
    end
  rescue
    _ -> {:error, :empty_collection}
  catch
    _, _ -> {:error, :empty_collection}
  end

  defp cached_source_status_query(%User{ap_id: ap_id}, limit) when is_binary(ap_id) do
    Activity
    |> where([activity], activity.actor == ^ap_id)
    |> where([activity], fragment("?->>'type' = 'Create'", activity.data))
    |> Activity.with_preloaded_object(:inner)
    |> where(
      [activity, object: object],
      fragment("?->>'type'", object.data) in ^@source_item_status_types
    )
    |> order_by([activity], desc: activity.id)
    |> limit(^limit)
  end

  defp cached_source_status_query(_, _limit) do
    Activity
    |> where([activity], false and activity.id == activity.id)
  end

  defp cached_source_status_item(
         %Activity{object: %{data: %{} = object}, data: %{} = activity_data} = activity,
         source_context,
         reading_user
       ) do
    with true <- Visibility.visible_for_user?(activity, reading_user),
         status when is_map(status) <-
           StatusView.render("show.json", %{activity: activity, for: reading_user}),
         %{} = item <-
           object
           |> source_preview_inherit_activity(activity_data)
           |> render_source_item(source_context, reading_user, fetch_replies?: false) do
      Map.put_new(item, :status, status)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp cached_source_status_item(_, _, _), do: nil

  defp pixelfed_atom_fallback_items(
         %User{} = source,
         %{platform: %{platform: "pixelfed"}} = source_context,
         limit,
         reading_user,
         total_items
       ) do
    with atom_url when is_binary(atom_url) <- actor_updates_feed_url(source),
         {:ok, feed} <- fetch_rss_feed(atom_url) do
      items =
        feed.items
        |> Enum.take(preview_candidate_limit(limit))
        |> Enum.map(&render_source_item(&1, source_context, reading_user, fetch_replies?: false))
        |> Enum.reject(&is_nil/1)
        |> unique_preview_items()
        |> Enum.take(limit)

      if items == [] do
        {:error, :empty_collection}
      else
        {:ok,
         %{
           items: items,
           next: nil,
           total_items: total_items || length(feed.items)
         }}
      end
    end
  end

  defp pixelfed_atom_fallback_items(_, _, _, _, _), do: {:error, :not_pixelfed}

  defp actor_updates_feed_url(%User{} = source) do
    [source.nickname, actor_webfinger_identifier(source)]
    |> Enum.find_value(&fetch_actor_updates_feed_url/1)
  end

  defp actor_webfinger_identifier(%User{} = source) do
    with username when is_binary(username) <- actor_source_username(source),
         host when is_binary(host) <- host(source) do
      username <> "@" <> host
    end
  end

  defp actor_source_username(%User{ap_id: ap_id, nickname: nickname}) do
    nickname_username(nickname) || actor_url_username(ap_id)
  end

  defp nickname_username(nickname) when is_binary(nickname) do
    nickname
    |> String.split("@", parts: 2)
    |> case do
      [username, _host] when username != "" -> username
      _ -> nil
    end
  end

  defp nickname_username(_), do: nil

  defp actor_url_username(ap_id) when is_binary(ap_id) do
    ap_id
    |> path()
    |> case do
      path when is_binary(path) ->
        path
        |> String.split("/", trim: true)
        |> List.last()
        |> empty_string_to_nil()

      _ ->
        nil
    end
  end

  defp actor_url_username(_), do: nil

  defp fetch_actor_updates_feed_url(identifier) when is_binary(identifier) do
    with true <- safe_webfinger_identifier?(identifier),
         {:ok, _local, host, account} <- webfinger_identifier_parts(identifier),
         {:ok, %{"links" => links}} <-
           fetch_webfinger_json(
             "https://#{host}/.well-known/webfinger?resource=" <>
               URI.encode_www_form("acct:" <> account)
           ),
         url when is_binary(url) <- webfinger_updates_link(links),
         true <- safe_fetch_url?(url) do
      url
    else
      _ -> nil
    end
  end

  defp fetch_actor_updates_feed_url(_), do: nil

  defp webfinger_updates_link(links) when is_list(links) do
    Enum.find_value(links, fn
      %{
        "rel" => "http://schemas.google.com/g/2010#updates-from",
        "href" => href
      } = link
      when is_binary(href) ->
        type = String.downcase(link["type"] || "")

        if type in ["", "application/atom+xml", "application/rss+xml", "application/xml"] do
          href
        end

      _ ->
        nil
    end)
  end

  defp webfinger_updates_link(_), do: nil

  defp owncast_fetch_json(%User{} = source, path) do
    with url when is_binary(url) <- owncast_api_url(source, path),
         true <- safe_fetch_url?(url),
         {:ok, %{} = data} <- source_items_unsigned_fetch(url) do
      mark_source_items_fetch_reachable(url)
      {:ok, data}
    else
      _ -> {:error, :fetch_failed}
    end
  rescue
    _ -> {:error, :fetch_failed}
  catch
    _, _ -> {:error, :fetch_failed}
  end

  defp owncast_optional_json(%User{} = source, path) do
    case owncast_fetch_json(source, path) do
      {:ok, %{} = data} -> data
      _ -> nil
    end
  end

  defp owncast_api_url(%User{} = source, path) do
    with %URI{scheme: scheme, host: host} = uri
         when scheme in ["http", "https"] and is_binary(host) <-
           parse_uri(source.ap_id || source.uri || "") do
      uri
      |> Map.merge(%{path: path, query: nil, fragment: nil})
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  defp owncast_absolute_url(%User{} = source, path) when is_binary(path) do
    if String.starts_with?(path, ["http://", "https://"]) do
      path
    else
      with base when is_binary(base) <- owncast_api_url(source, "/") do
        base
        |> URI.merge(path)
        |> URI.to_string()
      end
    end
  rescue
    _ -> nil
  end

  defp owncast_absolute_url(_, _), do: nil

  defp owncast_stream_status_item(%User{} = source, %{} = status, directory) do
    actor_id = source.ap_id || source.uri

    if is_binary(actor_id) do
      state = if status["online"] == true, do: "Live now", else: "Offline"
      stream_title = owncast_stream_title(status, directory)
      site_name = owncast_directory_text(directory, ["name"]) || source.name || source.nickname
      title = owncast_status_title(state, stream_title, site_name)
      content = owncast_stream_status_content(state, stream_title, status, directory)

      %{
        "id" => actor_id <> "#owncast-stream-status",
        "type" => "StreamStatus",
        "to" => Pleroma.Constants.as_public(),
        "name" => title,
        "content" => content,
        "url" => owncast_stream_urls(source),
        "attributedTo" => actor_id,
        "published" => owncast_status_time(status),
        "image" => owncast_absolute_url(source, owncast_directory_text(directory, ["logo"]))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()
    end
  end

  defp owncast_status_title(state, stream_title, site_name) do
    cond do
      present_binary?(stream_title) -> "#{state}: #{stream_title}"
      present_binary?(site_name) -> "#{state}: #{site_name}"
      true -> "#{state}: Owncast stream"
    end
  end

  defp owncast_stream_urls(%User{} = source) do
    [
      %{
        "type" => "Link",
        "mediaType" => "text/html",
        "href" => owncast_api_url(source, "/")
      },
      %{
        "type" => "Link",
        "mediaType" => "application/x-mpegURL",
        "href" => owncast_api_url(source, "/hls/stream.m3u8")
      }
    ]
    |> Enum.reject(fn %{"href" => href} -> is_nil(href) or href == "" end)
  end

  defp owncast_stream_status_content(state, stream_title, status, directory) do
    [
      "<p><strong>#{html_escape(state)}</strong></p>",
      owncast_stream_title_html(stream_title),
      owncast_description_html(directory),
      owncast_viewer_count_html(status)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp owncast_stream_title_html(title) when is_binary(title) do
    "<p>Stream title: #{html_escape(title)}</p>"
  end

  defp owncast_stream_title_html(_), do: nil

  defp owncast_description_html(directory) do
    case owncast_directory_text(directory, ["description"]) do
      description when is_binary(description) -> "<p>#{html_escape(description)}</p>"
      _ -> nil
    end
  end

  defp owncast_viewer_count_html(status) do
    case normalized_integer(status["viewerCount"]) do
      count when is_integer(count) -> "<p>#{count} viewers</p>"
      _ -> nil
    end
  end

  defp owncast_status_time(status) do
    owncast_directory_text(status, ["lastConnectTime", "lastDisconnectTime", "serverTime"])
  end

  defp owncast_stream_title(status, directory) do
    owncast_directory_text(status, ["streamTitle"]) ||
      owncast_directory_text(directory, ["streamTitle"])
  end

  defp owncast_directory_text(%{} = data, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(data, key) do
        value when is_binary(value) ->
          value
          |> String.trim()
          |> empty_string_to_nil()

        _ ->
          nil
      end
    end)
  end

  defp owncast_directory_text(_, _), do: nil

  defp html_escape(value) when is_binary(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp source_actor_fallback_items(%User{} = source, source_context, reason, total_items) do
    with {:ok, %{} = actor} <- source_items_fetch_json(source.ap_id || source.uri),
         %{} = item <- render_source_item(actor, source_context) do
      {:ok,
       %{
         items: [Map.put(item, :preview_warning, source_preview_warning(reason))],
         next: nil,
         total_items: total_items
       }}
    else
      _ -> cached_source_fallback_items(source, source_context, reason, total_items)
    end
  end

  defp cached_source_fallback_items(
         %User{actor_type: "Person"} = source,
         source_context,
         reason,
         total_items
       ) do
    item_data = %{
      "id" => source.ap_id || source.uri,
      "type" => source.actor_type,
      "name" => source.name || source.nickname,
      "summary" => source.bio || source.raw_bio,
      "url" => source.uri || source.ap_id
    }

    case render_source_item(item_data, source_context) do
      %{} = item ->
        {:ok,
         %{
           items: [Map.put(item, :preview_warning, source_preview_warning(reason))],
           next: nil,
           total_items: total_items
         }}

      _ ->
        {:error, reason}
    end
  end

  defp cached_source_fallback_items(_, _, reason, _), do: {:error, reason}

  defp source_preview_warning(:empty_collection),
    do: "Remote source did not expose preview items."

  defp source_preview_warning(:invalid_body),
    do: "Remote source returned a non-ActivityPub preview body."

  defp source_preview_warning(:fetch_failed), do: "Remote source preview could not be fetched."
  defp source_preview_warning(_), do: "Remote source preview is unavailable."

  defp render_source_item(item, source_context, reading_user \\ nil, opts \\ [])

  defp render_source_item(item, source_context, _reading_user, _opts) when is_binary(item) do
    %{
      id: item,
      type: "Link",
      title: item,
      summary: nil,
      url: item,
      media_url: nil,
      media_type: nil,
      attributed_to: nil,
      published: nil,
      thumbnail_url: nil,
      duration: nil,
      media_bitrate: nil,
      media_size: nil,
      album: nil,
      album_url: nil,
      artists: [],
      license: nil,
      copyright: nil,
      disc: nil,
      position: nil,
      musicbrainz_id: nil,
      musicbrainz_url: nil,
      event_start: nil,
      location: nil,
      comments_count: nil,
      native: nil,
      render_hint: source_item_render_hint(source_context.platform.platform_family),
      source_kind: source_context.source_kind,
      source_kind_label: source_context.source_kind_label,
      capabilities: source_context.capabilities
    }
    |> Map.merge(source_context.platform)
  end

  defp render_source_item(%{} = item, source_context, reading_user, opts) do
    if source_item_public_preview?(item) do
      url = source_item_best_url(item)
      media = source_item_media(item)
      summary = source_item_summary(item)
      platform = source_item_platform(item, source_context.platform)
      comments_count = source_item_comments_count(item)

      %{
        id: source_item_id(item, url),
        type: item["type"] || "Object",
        title: source_item_title(item, summary, url),
        summary: summary,
        url: url,
        media_url: media[:href],
        media_type: media[:media_type],
        attributed_to: source_item_attributed_to(item["attributedTo"]),
        published: item["published"],
        thumbnail_url: source_item_thumbnail(item, media),
        duration: source_item_duration(item),
        media_bitrate: source_item_media_bitrate(item, media),
        media_size: source_item_media_size(item, media),
        album: source_item_album(item),
        album_url: source_item_album_url(item),
        artists: source_item_artists(item),
        license: source_item_license(item),
        copyright: source_item_copyright(item),
        disc: source_item_disc(item),
        position: source_item_position(item),
        musicbrainz_id: source_item_musicbrainz_id(item),
        musicbrainz_url: source_item_musicbrainz_url(item),
        event_start: source_item_event_start(item),
        location: source_item_location(item),
        comments_count: comments_count,
        native: source_item_native_presentation(item),
        render_hint: source_item_render_hint(platform.platform_family),
        source_kind: source_context.source_kind,
        source_kind_label: source_context.source_kind_label,
        capabilities: source_context.capabilities
      }
      |> Map.merge(platform)
      |> maybe_put(
        :status,
        source_item_status(item, source_context, reading_user, comments_count, opts)
      )
    end
  end

  defp render_source_item(_, _, _, _), do: nil

  defp source_item_native_presentation(item) do
    Pleroma.Web.ActivityPub.CustomActivity.presentation(item) ||
      Pleroma.Web.ActivityPub.CustomObject.presentation(item)
  end

  defp source_item_public_preview?(item) do
    addresses =
      [item["to"], item["cc"], item["audience"]]
      |> Enum.flat_map(&source_item_address_ids/1)
      |> Enum.map(&normalize_source_item_public_address/1)
      |> Enum.reject(&is_nil/1)

    cond do
      Pleroma.Constants.as_public() in addresses -> true
      addresses != [] -> false
      source_item_native_presentation(item) != nil -> false
      true -> true
    end
  end

  defp source_item_address_ids(value) when is_binary(value), do: [value]
  defp source_item_address_ids(%{"id" => id}) when is_binary(id), do: [id]

  defp source_item_address_ids(values) when is_list(values) do
    Enum.flat_map(values, &source_item_address_ids/1)
  end

  defp source_item_address_ids(_value), do: []

  defp normalize_source_item_public_address(value) when value in ["Public", "as:Public"],
    do: Pleroma.Constants.as_public()

  defp normalize_source_item_public_address(value), do: value

  defp source_item_status(
         %{} = item,
         %{source_kind: "rss_feed", source: %User{} = source},
         reading_user,
         comments_count,
         _opts
       ) do
    with id when is_binary(id) <- rss_source_item_object_id(source, item),
         %Activity{} = activity <- rss_source_item_activity(source, item, id),
         true <- Visibility.visible_for_user?(activity, reading_user),
         status when is_map(status) <-
           StatusView.render("show.json", %{activity: activity, for: reading_user}) do
      maybe_put_status_replies_count(status, comments_count)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp source_item_status(%{} = item, _source_context, reading_user, comments_count, opts) do
    with id when is_binary(id) <- source_item_object_id(item),
         %Activity{} = activity <- source_item_activity(item, id),
         true <- Visibility.visible_for_user?(activity, reading_user),
         :ok <- maybe_fetch_source_item_replies(activity, opts),
         %Activity{} = activity <- Activity.get_create_by_object_ap_id_with_object(id),
         status when is_map(status) <-
           StatusView.render("show.json", %{activity: activity, for: reading_user}) do
      maybe_put_status_replies_count(status, comments_count)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp maybe_fetch_source_item_replies(%Activity{} = activity, opts) do
    if Keyword.get(opts, :fetch_replies?, true) do
      fetch_source_item_replies(activity)
    else
      :ok
    end
  end

  defp fetch_source_item_replies(%Activity{} = activity) do
    RemoteReplies.fetch_for_activity(activity)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp maybe_put_status_replies_count(status, count) when is_integer(count) do
    existing_count =
      normalized_integer(status[:replies_count]) ||
        normalized_integer(status["replies_count"]) ||
        0

    if count > existing_count do
      Map.put(status, :replies_count, count)
    else
      status
    end
  end

  defp maybe_put_status_replies_count(status, _), do: status

  defp source_item_activity(item, id) do
    Activity.get_create_by_object_ap_id_with_object(id) ||
      maybe_fetch_source_item_activity(item, id) ||
      maybe_fetch_source_item_activity_with_resolved_id(item, id)
  end

  defp maybe_fetch_source_item_activity(%{"type" => type}, id)
       when type in @source_item_status_types do
    with {:ok, _object} <- Fetcher.fetch_object_from_id(id, depth: 0) do
      Activity.get_create_by_object_ap_id_with_object(id)
    else
      _ -> nil
    end
  end

  defp maybe_fetch_source_item_activity(_, _), do: nil

  defp maybe_fetch_source_item_activity_with_resolved_id(%{"type" => type}, id)
       when type in @source_item_status_types do
    with {:ok, %{"id" => resolved_id} = object} <- source_items_fetch_json(id),
         true <- is_binary(resolved_id) and resolved_id != id,
         resolved_type <- object["type"] || type,
         true <- resolved_type in @source_item_status_types do
      Activity.get_create_by_object_ap_id_with_object(resolved_id) ||
        maybe_fetch_source_item_activity(%{"type" => resolved_type}, resolved_id) ||
        maybe_create_source_item_activity(object, resolved_id)
    else
      _ -> nil
    end
  end

  defp maybe_fetch_source_item_activity_with_resolved_id(_, _), do: nil

  defp maybe_create_source_item_activity(%{"type" => type} = object, id)
       when type in @source_item_status_types do
    with actor when is_binary(actor) <- source_item_actor(object),
         %{} = create <- source_item_create_activity(object, actor, id),
         {:ok, %Activity{}} <- Transmogrifier.handle_incoming(create) do
      Activity.get_create_by_object_ap_id_with_object(id)
    else
      _ -> nil
    end
  end

  defp maybe_create_source_item_activity(_, _), do: nil

  defp source_item_actor(%{"actor" => actor}) when is_binary(actor), do: actor
  defp source_item_actor(%{"attributedTo" => actor}) when is_binary(actor), do: actor

  defp source_item_actor(%{"attributedTo" => actors}) when is_list(actors) do
    Enum.find(actors, &is_binary/1)
  end

  defp source_item_actor(_), do: nil

  defp source_item_create_activity(object, actor, id) do
    published = object["published"] || DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "id" => id <> "#create",
      "type" => "Create",
      "actor" => actor,
      "object" => object,
      "published" => published,
      "to" => source_item_recipients(object["to"], [Pleroma.Constants.as_public()]),
      "cc" => source_item_recipients(object["cc"], [])
    }
  end

  defp source_item_recipients(recipients, _default) when is_list(recipients), do: recipients
  defp source_item_recipients(recipient, _default) when is_binary(recipient), do: [recipient]
  defp source_item_recipients(_, default), do: default

  defp source_item_object_id(%{"activity_pub_object_id" => id}) when is_binary(id), do: id
  defp source_item_object_id(%{"activityPubObjectId" => id}) when is_binary(id), do: id
  defp source_item_object_id(%{"id" => id}) when is_binary(id), do: id
  defp source_item_object_id(_), do: nil

  defp rss_source_item_object_id(%User{} = source, %{} = item) do
    [item["id"], item["url"]]
    |> Enum.find(&same_host_url?(&1, source.ap_id))
    |> case do
      id when is_binary(id) ->
        id

      _ ->
        rss_source_item_synthetic_id(source, item)
    end
  end

  defp same_host_url?(value, actor_id) when is_binary(value) and is_binary(actor_id) do
    with true <- url?(value),
         %URI{host: host} when is_binary(host) <- parse_uri(value),
         %URI{host: actor_host} when is_binary(actor_host) <- parse_uri(actor_id) do
      String.downcase(host) == String.downcase(actor_host)
    else
      _ -> false
    end
  end

  defp same_host_url?(_, _), do: false

  defp rss_source_item_synthetic_id(%User{ap_id: ap_id}, item) when is_binary(ap_id) do
    if url?(ap_id) do
      ap_id <> "#item-" <> rss_source_item_hash(item)
    end
  end

  defp rss_source_item_synthetic_id(_, _), do: nil

  defp rss_source_item_hash(item) do
    [
      item["id"],
      item["url"],
      item["published"],
      item["name"],
      item["summary"]
    ]
    |> Enum.find(&is_binary/1)
    |> Kernel.||(inspect(item))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 32)
  end

  defp rss_source_item_activity(%User{} = source, item, id) do
    Activity.get_create_by_object_ap_id_with_object(id) ||
      maybe_create_rss_source_item_activity(source, item, id)
  end

  defp maybe_create_rss_source_item_activity(%User{} = source, item, id) do
    with %{} = create <- rss_source_item_create(source, item, id),
         {:ok, %Activity{}} <- Transmogrifier.handle_incoming(create) do
      Activity.get_create_by_object_ap_id_with_object(id)
    else
      _ -> nil
    end
  end

  defp rss_source_item_create(%User{} = source, item, id) do
    url = source_item_best_url(item) || id
    published = rss_source_item_published(item)
    context = id <> "#context"
    to = [Pleroma.Constants.as_public()]
    cc = [source.follower_address || source.ap_id]

    object =
      %{
        "id" => id,
        "type" => "Article",
        "actor" => source.ap_id,
        "attributedTo" => source.ap_id,
        "context" => context,
        "name" => source_item_title(item, source_item_summary(item), url),
        "content" => rss_source_item_content(item, url),
        "url" => url,
        "published" => published,
        "to" => to,
        "cc" => cc
      }
      |> maybe_put("image", source_item_image_url(item["image"]))
      |> maybe_put("source", rss_source_item_source(item))
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    %{
      "id" => id <> "#create",
      "type" => "Create",
      "actor" => source.ap_id,
      "object" => object,
      "published" => published,
      "to" => to,
      "cc" => cc
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp rss_source_item_content(item, url) do
    content =
      item["summary"] ||
        item["content"] ||
        item["name"] ||
        url ||
        "RSS feed item"

    content
    |> Pleroma.HTML.filter_tags()
    |> maybe_append_rss_source_item_link(url)
  end

  defp maybe_append_rss_source_item_link(content, url)
       when is_binary(content) and is_binary(url) do
    if String.contains?(content, url) do
      content
    else
      href =
        url
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()

      content <> ~s(<p><a href="#{href}" rel="ugc">Read original</a></p>)
    end
  end

  defp maybe_append_rss_source_item_link(content, _url), do: content

  defp rss_source_item_source(%{"summary" => summary}) when is_binary(summary) do
    %{"content" => summary, "mediaType" => "text/html"}
  end

  defp rss_source_item_source(_), do: nil

  defp rss_source_item_published(%{"published" => published}) when is_binary(published),
    do: published

  defp rss_source_item_published(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp source_item_platform(%{} = item, source_platform) do
    item
    |> Platform.classify()
    |> case do
      %{confidence: :unknown} ->
        source_platform

      %{confidence: :object} = classification ->
        item_platform = platform_metadata(classification)

        if source_platform.platform == "unknown" do
          item_platform
        else
          %{source_platform | platform_family: item_platform.platform_family}
        end

      classification ->
        platform_metadata(classification)
    end
  end

  defp source_item_render_hint("audio"), do: %{layout: "player", primary_action: "play"}
  defp source_item_render_hint("video"), do: %{layout: "player", primary_action: "play"}
  defp source_item_render_hint("longform"), do: %{layout: "article", primary_action: "read"}
  defp source_item_render_hint("microblog"), do: %{layout: "status", primary_action: "reply"}
  defp source_item_render_hint("photo"), do: %{layout: "gallery", primary_action: "view"}
  defp source_item_render_hint("games"), do: %{layout: "game", primary_action: "open"}
  defp source_item_render_hint("marketplace"), do: %{layout: "listing", primary_action: "open"}
  defp source_item_render_hint("culture"), do: %{layout: "catalog", primary_action: "open"}
  defp source_item_render_hint("books"), do: %{layout: "book", primary_action: "open"}
  defp source_item_render_hint("bookmarks"), do: %{layout: "link", primary_action: "open"}
  defp source_item_render_hint("groups"), do: %{layout: "community", primary_action: "join"}
  defp source_item_render_hint("events"), do: %{layout: "event", primary_action: "rsvp"}

  defp source_item_render_hint("development"),
    do: %{layout: "development", primary_action: "open"}

  defp source_item_render_hint("coordination"),
    do: %{layout: "coordination", primary_action: "open"}

  defp source_item_render_hint("publishing"),
    do: %{layout: "resource", primary_action: "open"}

  defp source_item_render_hint("routes"), do: %{layout: "route", primary_action: "open"}
  defp source_item_render_hint("local"), do: %{layout: "community", primary_action: "open"}
  defp source_item_render_hint(_), do: %{layout: "generic", primary_action: "open"}

  defp source_item_id(item, url) do
    item["id"] || url || Base.url_encode64(:crypto.hash(:sha256, inspect(item)), padding: false)
  end

  defp source_item_title(item, summary, url) do
    [
      item["name"],
      item["title"],
      source_item_track_title(item),
      summary,
      url,
      item["id"],
      "Remote item"
    ]
    |> Enum.find(&present_binary?/1)
    |> source_item_text_limit(@source_item_title_limit)
  end

  defp source_item_track_title(%{} = item) do
    track = source_item_nested(item, ["track"])

    source_item_named_value(track)
  end

  defp source_item_track_title(_), do: nil

  defp source_item_summary(%{"summary" => summary}) when is_binary(summary) do
    source_item_strip_html(summary)
  end

  defp source_item_summary(%{"content" => content}) when is_binary(content) do
    source_item_strip_html(content)
  end

  defp source_item_summary(_), do: nil

  defp source_item_strip_html(value) when is_binary(value) do
    value
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> empty_string_to_nil()
    |> source_item_text_limit(@source_item_summary_limit)
  end

  defp empty_string_to_nil(""), do: nil
  defp empty_string_to_nil(value), do: value

  defp present_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp source_item_text_limit(value, limit) when is_binary(value) do
    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "..."
    else
      value
    end
  end

  defp source_item_text_limit(value, _limit), do: value

  defp source_item_best_url(%{"url" => urls, "id" => id}) do
    source_item_html_url(urls) || source_item_any_url(urls) || id
  end

  defp source_item_best_url(%{"url" => urls}) do
    source_item_html_url(urls) || source_item_any_url(urls)
  end

  defp source_item_best_url(%{"id" => id}) when is_binary(id), do: id

  defp source_item_best_url(_), do: nil

  defp source_item_html_url(urls) when is_list(urls) do
    urls
    |> Enum.find_value(fn
      %{"href" => href} = url when is_binary(href) ->
        cond do
          source_item_url_media_type(url) == "text/html" -> href
          url["type"] == "Link" and is_nil(source_item_url_media_type(url)) -> href
          true -> nil
        end

      _ ->
        nil
    end)
  end

  defp source_item_html_url(%{"href" => href, "mediaType" => "text/html"}) when is_binary(href),
    do: href

  defp source_item_html_url(%{"href" => href, "mimeType" => "text/html"}) when is_binary(href),
    do: href

  defp source_item_html_url(_), do: nil

  defp source_item_any_url(url) when is_binary(url), do: url

  defp source_item_any_url(urls) when is_list(urls) do
    urls
    |> Enum.find_value(fn
      %{"href" => href} when is_binary(href) -> href
      href when is_binary(href) -> href
      _ -> nil
    end)
  end

  defp source_item_any_url(%{"href" => href}) when is_binary(href), do: href
  defp source_item_any_url(_), do: nil

  defp source_item_media(%{"url" => urls}) when is_list(urls) do
    urls
    |> Enum.find_value(%{href: nil, media_type: nil, bitrate: nil, size: nil}, fn
      %{"href" => href} = url when is_binary(href) ->
        media_type = source_item_url_media_type(url)

        if source_item_media_type?(media_type) do
          %{
            href: href,
            media_type: media_type,
            bitrate: normalized_integer(url["bitrate"]),
            size: normalized_integer(url["size"])
          }
        end

      _ ->
        nil
    end)
  end

  defp source_item_media(%{"url" => %{"href" => href} = url}) when is_binary(href) do
    media_type = source_item_url_media_type(url)

    if source_item_media_type?(media_type) do
      %{
        href: href,
        media_type: media_type,
        bitrate: normalized_integer(url["bitrate"]),
        size: normalized_integer(url["size"])
      }
    else
      %{href: nil, media_type: nil, bitrate: nil, size: nil}
    end
  end

  defp source_item_media(_), do: %{href: nil, media_type: nil, bitrate: nil, size: nil}

  defp source_item_url_media_type(%{"mediaType" => media_type}) when is_binary(media_type),
    do: media_type

  defp source_item_url_media_type(%{"mimeType" => media_type}) when is_binary(media_type),
    do: media_type

  defp source_item_url_media_type(_), do: nil

  defp source_item_media_type?(media_type) when is_binary(media_type) do
    media_type in ["application/x-mpegURL", "application/vnd.apple.mpegurl"] or
      String.starts_with?(media_type, "audio/") or String.starts_with?(media_type, "video/") or
      String.starts_with?(media_type, "image/")
  end

  defp source_item_media_type?(_), do: false

  defp source_item_thumbnail(item, %{href: href, media_type: media_type})
       when is_binary(href) and is_binary(media_type) do
    if String.starts_with?(media_type, "image/") do
      href
    else
      source_item_thumbnail(item, %{})
    end
  end

  defp source_item_thumbnail(item, _media) do
    source_item_image_url(item["image"]) ||
      source_item_image_url(item["icon"]) ||
      source_item_image_url(item["attachment"]) ||
      source_item_image_url(item["preview"]) ||
      source_item_image_url(source_item_nested(item, ["track", "image"])) ||
      source_item_image_url(source_item_nested(item, ["track", "album", "image"]))
  end

  defp source_item_image_url(value) when is_binary(value), do: value

  defp source_item_image_url(%{"url" => url}), do: source_item_image_url(url)
  defp source_item_image_url(%{"href" => href}) when is_binary(href), do: href

  defp source_item_image_url(values) when is_list(values) do
    Enum.find_value(values, &source_item_image_url/1)
  end

  defp source_item_image_url(_), do: nil

  defp source_item_duration(%{"duration" => duration}) when is_binary(duration), do: duration

  defp source_item_duration(%{"duration" => duration}) when is_integer(duration),
    do: Integer.to_string(duration)

  defp source_item_duration(%{"length" => duration}) when is_binary(duration), do: duration
  defp source_item_duration(%{"runtime" => duration}) when is_binary(duration), do: duration
  defp source_item_duration(_), do: nil

  defp source_item_media_bitrate(item, media) do
    media[:bitrate] ||
      normalized_integer(source_item_nested(item, ["bitrate"])) ||
      normalized_integer(source_item_nested(item, ["track", "bitrate"]))
  end

  defp source_item_media_size(item, media) do
    media[:size] ||
      normalized_integer(source_item_nested(item, ["size"])) ||
      normalized_integer(source_item_nested(item, ["track", "size"]))
  end

  defp source_item_album(item) do
    source_item_named_value(source_item_nested(item, ["track", "album"])) ||
      source_item_named_value(source_item_nested(item, ["album"]))
  end

  defp source_item_album_url(item) do
    source_item_object_url(source_item_nested(item, ["track", "album"])) ||
      source_item_object_url(source_item_nested(item, ["album"]))
  end

  defp source_item_artists(item) do
    [
      source_item_artist_values(source_item_nested(item, ["track", "artist_credit"])),
      source_item_artist_values(source_item_nested(item, ["artist_credit"])),
      source_item_artist_values(source_item_nested(item, ["track", "artist"])),
      source_item_artist_values(source_item_nested(item, ["artist"])),
      source_item_artist_values(source_item_nested(item, ["artists"]))
    ]
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp source_item_artist_values(values) when is_list(values) do
    Enum.flat_map(values, &source_item_artist_values/1)
  end

  defp source_item_artist_values(%{"credit" => credit}) when is_binary(credit) do
    [credit]
  end

  defp source_item_artist_values(%{"artist" => artist}) do
    source_item_artist_values(artist)
  end

  defp source_item_artist_values(%{} = artist) do
    case source_item_named_value(artist) do
      name when is_binary(name) -> [name]
      _ -> []
    end
  end

  defp source_item_artist_values(value) when is_binary(value) do
    if url?(value), do: [], else: [value]
  end

  defp source_item_artist_values(_), do: []

  defp source_item_license(item) do
    source_item_string(source_item_nested(item, ["track", "license"])) ||
      source_item_string(source_item_nested(item, ["license"]))
  end

  defp source_item_copyright(item) do
    source_item_string(source_item_nested(item, ["track", "copyright"])) ||
      source_item_string(source_item_nested(item, ["copyright"]))
  end

  defp source_item_disc(item) do
    normalized_integer(source_item_nested(item, ["track", "disc"])) ||
      normalized_integer(source_item_nested(item, ["disc"]))
  end

  defp source_item_position(item) do
    normalized_integer(source_item_nested(item, ["track", "position"])) ||
      normalized_integer(source_item_nested(item, ["position"]))
  end

  defp source_item_musicbrainz_id(item) do
    [
      source_item_nested(item, ["track", "musicbrainzId"]),
      source_item_nested(item, ["track", "musicbrainz_id"]),
      source_item_nested(item, ["musicbrainzId"]),
      source_item_nested(item, ["musicbrainz_id"])
    ]
    |> Enum.find_value(&source_item_string/1)
  end

  defp source_item_musicbrainz_url(item) do
    with id when is_binary(id) <- source_item_musicbrainz_id(item) do
      "https://musicbrainz.org/" <> source_item_musicbrainz_entity(item) <> "/" <> id
    end
  end

  defp source_item_musicbrainz_entity(%{"type" => "Artist"}), do: "artist"

  defp source_item_musicbrainz_entity(%{"type" => type}) when type in ["Album", "Release"],
    do: "release"

  defp source_item_musicbrainz_entity(_), do: "recording"

  defp source_item_named_value(%{"name" => name}) when is_binary(name), do: name
  defp source_item_named_value(%{"title" => title}) when is_binary(title), do: title

  defp source_item_named_value(%{"preferredUsername" => username}) when is_binary(username),
    do: username

  defp source_item_named_value(%{"username" => username}) when is_binary(username), do: username
  defp source_item_named_value(_), do: nil

  defp source_item_object_url(%{"id" => id}) when is_binary(id), do: id
  defp source_item_object_url(%{"url" => url}), do: source_item_any_url(url)
  defp source_item_object_url(value) when is_binary(value), do: if(url?(value), do: value)
  defp source_item_object_url(_), do: nil

  defp source_item_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> empty_string_to_nil()
  end

  defp source_item_string(_), do: nil

  defp source_item_nested(%{} = item, keys) when is_list(keys) do
    Enum.reduce_while(keys, item, fn
      key, %{} = map -> {:cont, Map.get(map, key)}
      _key, _ -> {:halt, nil}
    end)
  end

  defp source_item_nested(_, _), do: nil

  defp source_item_event_start(%{"startTime" => start_time}) when is_binary(start_time),
    do: start_time

  defp source_item_event_start(%{"start_time" => start_time}) when is_binary(start_time),
    do: start_time

  defp source_item_event_start(_), do: nil

  defp source_item_location(%{"location" => location}), do: source_item_location_value(location)
  defp source_item_location(_), do: nil

  defp source_item_comments_count(%{} = item) do
    [
      normalized_integer(item["commentsCount"]),
      normalized_integer(item["comments_count"]),
      normalized_integer(item["comment_count"]),
      normalized_integer(item["repliesCount"]),
      normalized_integer(item["replies_count"]),
      source_item_collection_count(item["comments"]),
      source_item_collection_count(item["replies"])
    ]
    |> Enum.find(&is_integer/1)
  end

  defp source_item_collection_count(%{"totalItems" => count}), do: normalized_integer(count)
  defp source_item_collection_count(%{"total_items" => count}), do: normalized_integer(count)

  defp source_item_collection_count(collection_url) when is_binary(collection_url) do
    with true <- safe_fetch_url?(collection_url),
         {:ok, %{} = collection} <- source_items_fetch_json(collection_url) do
      collection_total_items(collection) ||
        source_item_collection_count(collection["items"] || collection["orderedItems"])
    else
      _ -> nil
    end
  end

  defp source_item_collection_count(items) when is_list(items), do: length(items)
  defp source_item_collection_count(_), do: nil

  defp source_item_location_value(value) when is_binary(value), do: value
  defp source_item_location_value(%{"name" => name}) when is_binary(name), do: name
  defp source_item_location_value(%{"address" => address}) when is_binary(address), do: address
  defp source_item_location_value(_), do: nil

  defp source_item_attributed_to(value) when is_binary(value), do: value

  defp source_item_attributed_to(values) when is_list(values) do
    values
    |> Enum.find(&is_binary/1)
  end

  defp source_item_attributed_to(_), do: nil

  defp source_page_next(%{"next" => next}) when is_binary(next), do: next
  defp source_page_next(_), do: nil

  defp collection_total_items(%{"totalItems" => count}), do: normalized_integer(count)
  defp collection_total_items(%{"total_items" => count}), do: normalized_integer(count)
  defp collection_total_items(_), do: nil

  defp normalized_integer(value) when is_integer(value), do: value

  defp normalized_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      _ -> nil
    end
  end

  defp normalized_integer(_), do: nil
end
