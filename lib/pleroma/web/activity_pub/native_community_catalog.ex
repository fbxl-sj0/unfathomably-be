# Unfathomably native community catalog
# --------------------------------------
#
# File: native_community_catalog.ex
#
# Purpose:
#   Present operator-approved public native-federation communities before the
#   local server has received a followable actor from each ecosystem.
#
# Responsibilities:
#   - expose only configured HTTPS community origins
#   - expose a small set of official ecosystem guides for decentralized systems
#   - allow operators to name additional verified specialized communities
#   - derive passive publisher cards from native objects already received
#   - group sources by their concrete native-object family
#   - describe the workflow a visitor can expect at each origin
#
# This file intentionally does not request remote data, resolve actors, or
# create local follows.

defmodule Pleroma.Web.ActivityPub.NativeCommunityCatalog do
  alias Pleroma.Config
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.FederatedTarget

  @supported_families ~w(
    audio books bookmarks coordination culture development events games groups
    longform marketplace models photo publishing routes video
  )
  @max_custom_communities 24
  @known_local_cache_key {__MODULE__, :known_local_communities}
  @known_local_cache_ttl_ms :timer.minutes(5)
  @known_local_family_limit 3
  @known_local_limit 18
  # The public card surface renders at most three groups. Keep a small buffer
  # for stale or malformed cached actors without classifying an entire remote
  # group inventory on the first anonymous Worlds request.
  @known_local_group_window_limit 24
  @received_native_per_family_limit 250
  @received_native_query_timeout 15_000
  @received_native_publisher_families ~w(
    audio books bookmarks coordination culture development events games
    longform marketplace models photo publishing routes video
  )

  @received_native_publishers_query """
  SELECT DISTINCT recent.family, recent.actor
  FROM unnest($2::text[]) AS requested(family)
  CROSS JOIN LATERAL (
    SELECT requested.family AS family,
      CASE
      WHEN jsonb_typeof(data->'actor') = 'string' THEN data->>'actor'
      WHEN jsonb_typeof(data->'actor') = 'array'
        AND jsonb_typeof(data->'actor'->0) = 'string' THEN data->'actor'->>0
      WHEN jsonb_typeof(data->'attributedTo') = 'string' THEN data->>'attributedTo'
      WHEN jsonb_typeof(data->'attributedTo') = 'array'
        AND jsonb_typeof(data->'attributedTo'->0) = 'string' THEN data->'attributedTo'->>0
      ELSE NULL
      END AS actor
    FROM objects
    WHERE unfathomably_native_discoverable(data)
      AND unfathomably_native_family(data) = requested.family
    ORDER BY id DESC
    LIMIT $1
  ) AS recent
  WHERE recent.actor LIKE 'https://%'
  """

  @community_specs [
    %{
      config_key: :bonfire_communities,
      family: "coordination",
      platform: "bonfire",
      title: "Bonfire community",
      workflow:
        "Open this operator-reviewed community, then resolve a complete public group, offer, need, resource, or proposal URL here."
    },
    %{
      config_key: :bookwyrm_indexes,
      family: "books",
      platform: "bookwyrm",
      title: "BookWyrm",
      workflow: "Search books, reviews, shelves, and reading activity."
    },
    %{
      config_key: :funkwhale_indexes,
      family: "audio",
      platform: "funkwhale",
      title: "Funkwhale",
      workflow: "Browse public music libraries and listen on the publishing source."
    },
    %{
      config_key: :neodb_indexes,
      family: "culture",
      platform: "neodb",
      title: "NeoDB",
      workflow: "Search cultural works, ratings, and reviews."
    },
    %{
      config_key: :mobilizon_indexes,
      family: "events",
      platform: "mobilizon",
      title: "Mobilizon",
      workflow: "Find public events, places, organizers, and RSVPs."
    },
    %{
      config_key: :gancio_indexes,
      family: "events",
      platform: "gancio",
      title: "Gancio",
      workflow: "Browse a community calendar and its upcoming events."
    },
    %{
      config_key: :flohmarkt_indexes,
      family: "marketplace",
      platform: "flohmarkt",
      title: "Flohmarkt",
      workflow: "Search listings and start a direct marketplace conversation."
    },
    %{
      config_key: :wanderer_indexes,
      family: "routes",
      platform: "wanderer",
      title: "Wanderer",
      workflow: "Browse public trails, routes, and geographic details."
    },
    %{
      config_key: :peertube_indexes,
      family: "video",
      platform: "peertube",
      title: "PeerTube",
      workflow: "Browse public videos and connected video communities."
    },
    %{
      config_key: :owncast_directory_indexes,
      family: "video",
      platform: "owncast",
      title: "Owncast",
      workflow: "Browse opted-in live streams through the public directory."
    }
  ]

  # Some specialized ecosystems deliberately have no global instance directory.
  # Their official project or maturity page is still a useful and stable entry
  # point, provided the UI does not present it as a community or federation
  # endpoint. Operator-configured cards are assembled first and may override a
  # guide with a reviewed local workflow for the same family and host.
  @built_in_entry_points [
    %{
      family: "bookmarks",
      platform: "postmarks",
      title: "Postmarks social bookmarking",
      entry_type: "guide",
      workflow:
        "Review the single-user bookmark server workflow, then resolve a specific Postmarks actor by its complete handle.",
      url: "https://github.com/ckolderup/postmarks"
    },
    %{
      family: "development",
      platform: "forgefed",
      title: "ForgeFed implementations",
      entry_type: "guide",
      workflow:
        "Review current ForgeFed implementations before resolving a project or repository actor published by its maintainer.",
      url: "https://forgefed.org/"
    },
    %{
      family: "coordination",
      platform: "bonfire_valueflows",
      title: "Bonfire Coordination status",
      entry_type: "guide",
      workflow:
        "Review the in-development Coordination and ValueFlows status; connect only to explicitly shared actors on deployments whose operators enable federation.",
      url: "https://bonfirenetworks.org/app/coordination/"
    },
    %{
      family: "coordination",
      platform: "activitypods",
      title: "ActivityPods Mutual Aid",
      entry_type: "guide",
      workflow:
        "Review the private-by-default mutual-aid workflow, then connect to a specific Pod shared by someone in your trusted network.",
      url: "https://activitypods.org/"
    },
    %{
      family: "photo",
      platform: "pixelfed",
      title: "Pixelfed server directory",
      entry_type: "directory",
      workflow:
        "Choose an operator-submitted photo community, then resolve a photographer's complete handle here.",
      url: "https://pixelfed.org/servers"
    },
    %{
      family: "books",
      platform: "bookwyrm",
      title: "BookWyrm community directory",
      entry_type: "directory",
      workflow:
        "Choose a small reading community, then resolve a reader, review, or book URL here.",
      url: "https://joinbookwyrm.com/instances/"
    },
    %{
      family: "culture",
      platform: "neodb",
      title: "NeoDB server directory",
      entry_type: "directory",
      workflow:
        "Choose a cultural catalog community, then resolve a member or catalog item from that server.",
      url: "https://neodb.net/servers/"
    },
    %{
      family: "marketplace",
      platform: "flohmarkt",
      title: "Flohmarkt instance directory",
      entry_type: "directory",
      workflow:
        "Choose a marketplace serving your location or community, browse listings at the source, and contact sellers directly.",
      url: "https://codeberg.org/flohmarkt/flohmarkt/wiki/flohmarkt-instances"
    },
    %{
      family: "models",
      platform: "manyfold",
      title: "Manyfold instance directory",
      entry_type: "directory",
      workflow:
        "Choose a publicly sharing federated model server, then resolve a Creator, Model, or Collection actor here.",
      url: "https://manyfold.app/about/instances.html"
    },
    %{
      family: "audio",
      platform: "funkwhale",
      title: "Funkwhale pod directory",
      entry_type: "directory",
      workflow:
        "Choose a home pod by registration policy and community, then discover public libraries, channels, music, and podcasts.",
      url: "https://www.funkwhale.audio/join/"
    },
    %{
      family: "events",
      platform: "mobilizon",
      title: "Mobilizon instance directory",
      entry_type: "directory",
      workflow:
        "Choose an event community by language, location, signup policy, and health, then resolve its groups or events here.",
      url: "https://instances.joinmobilizon.org/instances"
    },
    %{
      family: "events",
      platform: "gancio",
      title: "Gancio instance directory",
      entry_type: "directory",
      workflow:
        "Choose a local or thematic shared calendar, then resolve its published event actor or event URL here.",
      url: "https://gancio.org/v2/instances"
    }
  ]

  @spec list(map()) :: %{items: [map()], refreshing: boolean()}
  def list(params) when is_map(params) do
    family = normalized_family(params)
    {known_local_items, refreshing} = known_local_items()

    items =
      @community_specs
      |> Enum.flat_map(&configured_items/1)
      |> Kernel.++(custom_community_items())
      |> Kernel.++(built_in_entry_point_items())
      |> Kernel.++(known_local_items)
      |> Enum.filter(&(family == "all" or &1.family == family))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&{&1.family, &1.title, &1.source_host})

    %{items: items, refreshing: refreshing}
  end

  def list(_params), do: %{items: [], refreshing: false}

  defp configured_items(spec) do
    Config.get([:native_discovery, spec.config_key], [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&community_item(&1, spec))
    |> Enum.reject(&is_nil/1)
  end

  # Not every specialized ecosystem has a trustworthy common directory. The
  # operator may therefore publish a small, explicit catalog of communities
  # they have reviewed. These records remain outbound links only; they are not
  # evidence that an actor is locally known or that a federation relationship
  # exists.
  defp custom_community_items do
    Config.get([:native_discovery, :community_catalog], [])
    |> List.wrap()
    |> Enum.take(@max_custom_communities)
    |> Enum.map(&custom_community_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp built_in_entry_point_items do
    @built_in_entry_points
    |> Enum.map(&custom_community_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp custom_community_item(entry) when is_map(entry) do
    with family when family in @supported_families <- entry_text(entry, :family, 40),
         title when is_binary(title) <- entry_text(entry, :title, 160),
         workflow when is_binary(workflow) <- entry_text(entry, :workflow, 500),
         url when is_binary(url) <- entry_text(entry, :url, 2_000),
         {:ok, origin, host} <- safe_catalog_url(url) do
      platform = entry_text(entry, :platform, 80) || "community"
      access_mode = custom_entry_access_mode(entry)

      %{
        id: "custom:#{family}:#{host}",
        family: family,
        platform: platform,
        title: title,
        workflow: workflow,
        url: origin,
        origin_type: custom_entry_origin_type(entry),
        access_mode: access_mode,
        resolver_enabled: resolver_enabled?(platform, access_mode),
        resolver_label: resolver_label(platform),
        source_host: host
      }
    end
  end

  defp custom_community_item(_entry), do: nil

  # A curated directory is useful discovery evidence but does not identify one
  # specific community. Keep that distinction in the API so clients can make
  # the destination and call to action clear without inferring it from a URL.
  defp custom_entry_origin_type(entry) do
    case entry_text(entry, :entry_type, 32) do
      "directory" -> "reviewed_directory"
      "guide" -> "ecosystem_guide"
      _ -> "reviewed_community"
    end
  end

  # Keep the action a client should offer separate from provenance. A reviewed
  # community is an external starting point, while a directory only helps a
  # person choose a community. Neither form implies an existing federation
  # relationship or authorizes a client to resolve a remote actor on display.
  defp custom_entry_access_mode(entry) do
    case custom_entry_origin_type(entry) do
      "reviewed_directory" -> "directory"
      "ecosystem_guide" -> "guide"
      _ -> "external"
    end
  end

  # Locally known actors are useful discovery evidence, but they are neither
  # a source-directory endorsement nor proof of a follow. The bounded public
  # projection can take noticeable time to classify after a restart, so never
  # block an anonymous Worlds request on it. Static reviewed cards return
  # immediately and a single background task warms the local projection.
  defp known_local_items do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@known_local_cache_key, nil) do
      {expires_at, items} when expires_at > now ->
        {items, false}

      {:refreshing, items} when is_list(items) ->
        {items, true}

      {_expires_at, items} when is_list(items) ->
        schedule_known_local_refresh(now, items)
        {items, true}

      _ ->
        schedule_known_local_refresh(now, [])
        {[], true}
    end
  end

  defp schedule_known_local_refresh(now, fallback_items) do
    lock = {@known_local_cache_key, self()}

    case :global.trans(lock, fn -> claim_known_local_refresh(now, fallback_items) end) do
      {:start, _items} ->
        {:ok, _pid} = Task.start(fn -> refresh_known_local_items() end)
        :ok

      _ ->
        :ok
    end
  end

  defp claim_known_local_refresh(now, fallback_items) do
    case :persistent_term.get(@known_local_cache_key, nil) do
      {expires_at, items} when expires_at > now ->
        {:ready, items}

      {:refreshing, items} when is_list(items) ->
        {:refreshing, items}

      {_expires_at, items} when is_list(items) ->
        :persistent_term.put(@known_local_cache_key, {:refreshing, items})
        {:start, items}

      _ ->
        :persistent_term.put(@known_local_cache_key, {:refreshing, fallback_items})
        {:start, fallback_items}
    end
  end

  defp refresh_known_local_items do
    items = fetch_known_local_items()
    now = System.monotonic_time(:millisecond)
    :persistent_term.put(@known_local_cache_key, {now + @known_local_cache_ttl_ms, items})
  end

  defp fetch_known_local_items do
    source_items =
      FederatedTarget.native_source_catalog(80)
      |> Enum.map(&known_local_item/1)
      |> Enum.reject(&is_nil/1)

    group_items =
      @known_local_group_window_limit
      |> FederatedTarget.public_native_groups()
      |> Enum.map(&known_local_group_item/1)
      |> Enum.reject(&is_nil/1)

    received_native_items = received_native_publisher_items()

    source_items
    |> Kernel.++(received_native_items)
    |> Kernel.++(group_items)
    |> Enum.uniq_by(& &1.url)
    |> balanced_known_local_items()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Some specialized publishers use ordinary Person or Service actors, so an
  # actor-only classifier cannot always identify their ecosystem. Received
  # native objects are stronger evidence: the immutable database classifier
  # recognizes their concrete vocabulary. The existing partial recency index
  # bounds this sample before classification, avoiding a family-wide table
  # scan. This query never fetches or resolves an actor. It only
  # promotes a cached, active remote user that already authored such an object.
  defp received_native_publisher_items do
    case Repo.query(
           @received_native_publishers_query,
           [@received_native_per_family_limit, @received_native_publisher_families],
           timeout: @received_native_query_timeout
         ) do
      {:ok, %{rows: rows}} ->
        users_by_ap_id =
          rows
          |> Enum.map(&List.last/1)
          |> Enum.uniq()
          |> User.get_all_by_ap_id()
          |> Map.new(&{&1.ap_id, &1})

        rows
        |> Enum.map(fn [family, actor] ->
          received_native_publisher_item(Map.get(users_by_ap_id, actor), family)
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp received_native_publisher_item(
         %User{local: false, is_active: true, invisible: false} = user,
         family
       )
       when family in @received_native_publisher_families do
    with {:ok, actor_url, host} <- safe_actor_url(user.ap_id) do
      community_name = bounded_text(user.name, 160) || bounded_text(user.nickname, 160) || host
      platform = FederatedTarget.source_platform(user).platform
      {title, workflow} = received_native_descriptor(family)

      %{
        id: "received:#{family}:#{user.id}",
        family: family,
        platform: platform,
        title: title,
        community_name: community_name,
        workflow: workflow,
        url: actor_url,
        local_url: safe_local_profile_url(user.nickname),
        origin_type: "known_actor",
        access_mode: "local",
        source_host: host,
        known_locally: true
      }
    else
      _ -> nil
    end
  end

  defp received_native_publisher_item(_user, _family), do: nil

  defp received_native_descriptor("audio"),
    do: {"Audio publisher", "Browse this actor's received tracks, audio, and listening activity."}

  defp received_native_descriptor("books"),
    do:
      {"Book publisher",
       "Browse this actor's received books, reviews, shelves, and reading activity."}

  defp received_native_descriptor("bookmarks"),
    do:
      {"Bookmark publisher", "Browse this actor's received bookmarks and saved-link collections."}

  defp received_native_descriptor("coordination"),
    do:
      {"Coordination publisher",
       "Browse this actor's received offers, needs, resources, and coordination records."}

  defp received_native_descriptor("culture"),
    do: {"Cultural catalog", "Browse this actor's received cultural items, ratings, and reviews."}

  defp received_native_descriptor("development"),
    do:
      {"Software forge",
       "Browse this actor's received projects, repositories, issues, and development activity."}

  defp received_native_descriptor("events"),
    do:
      {"Event publisher",
       "Browse this actor's received events, places, comments, and attendance activity."}

  defp received_native_descriptor("games"),
    do: {"Game publisher", "Browse this actor's received games, moves, and related activity."}

  defp received_native_descriptor("longform"),
    do: {"Long-form publisher", "Browse this actor's received articles and long-form writing."}

  defp received_native_descriptor("marketplace"),
    do:
      {"Marketplace publisher", "Browse this actor's received listings and marketplace activity."}

  defp received_native_descriptor("models"),
    do:
      {"3D model publisher",
       "Browse this actor's received models, files, and fabrication details."}

  defp received_native_descriptor("photo"),
    do: {"Photo publisher", "Browse this actor's received photographs and media collections."}

  defp received_native_descriptor("publishing"),
    do:
      {"Publication", "Browse this actor's received publication entries and editorial activity."}

  defp received_native_descriptor("routes"),
    do:
      {"Route publisher", "Browse this actor's received routes, trails, and geographic details."}

  defp received_native_descriptor("video"),
    do:
      {"Video publisher",
       "Browse this actor's received videos, channels, and live-stream activity."}

  # A busy platform must not crowd every other native family out of the public
  # catalog just because its records happen to be encountered first. Preserve
  # each bounded query's recency order within a family, then expose one actor
  # from every family before returning a second actor from any of them.
  defp balanced_known_local_items(items) do
    items
    |> Enum.group_by(& &1.family)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {family, family_items} ->
      {family, Enum.take(family_items, @known_local_family_limit)}
    end)
    |> round_robin_known_local_items()
    |> Enum.take(@known_local_limit)
  end

  defp round_robin_known_local_items(families) do
    {round, remaining} =
      Enum.reduce(families, {[], []}, fn
        {family, [item | rest]}, {round, remaining} ->
          {[item | round], [{family, rest} | remaining]}

        {_family, []}, result ->
          result
      end)

    case round do
      [] -> []
      _ -> Enum.reverse(round) ++ round_robin_known_local_items(Enum.reverse(remaining))
    end
  end

  defp known_local_item(user) do
    case {FederatedTarget.native_source_family(user), safe_actor_url(user.ap_id)} do
      {family, {:ok, actor_url, host}} when family in @supported_families ->
        community_name = bounded_text(user.name, 160) || bounded_text(user.nickname, 160) || host
        source_kind = FederatedTarget.source_kind_label(user)
        platform = FederatedTarget.source_platform(user).platform
        {title, workflow} = known_local_descriptor(platform, source_kind)

        %{
          id: "known:#{user.id}",
          family: family,
          platform: FederatedTarget.source_kind(user),
          title: title,
          community_name: community_name,
          workflow: workflow,
          url: actor_url,
          local_url: safe_local_profile_url(user.nickname),
          origin_type: "known_actor",
          access_mode: "local",
          source_host: host,
          known_locally: true
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Remote Group actors are a distinct discovery surface from source actors.
  # The query supplying them is bounded and indexed in FederatedTarget, while
  # this projection stays passive: it exposes no membership state and performs
  # no remote lookup when an anonymous visitor opens Worlds.
  defp known_local_group_item(user) do
    case {FederatedTarget.group?(user), safe_actor_url(user.ap_id)} do
      {true, {:ok, actor_url, host}} ->
        community_name = bounded_text(user.name, 160) || bounded_text(user.nickname, 160) || host
        platform = FederatedTarget.group_platform(user).platform
        {title, workflow} = known_local_group_descriptor(platform)

        %{
          id: "known-group:#{user.id}",
          family: "groups",
          platform: platform,
          title: title,
          community_name: community_name,
          workflow: workflow,
          url: actor_url,
          local_url: safe_local_profile_url(user.nickname),
          origin_type: "known_actor",
          access_mode: "local",
          source_host: host,
          known_locally: true
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Actor kinds such as OrderedCollection are correct ActivityPub storage
  # terms, but they do not tell a person what will be available after opening
  # the card. The platform classifier has already made a bounded structural
  # decision, so use it to provide a human-oriented discovery label without
  # inferring a platform from a hostname or making another remote request.
  defp known_local_descriptor("peertube", _source_kind),
    do:
      {"PeerTube channel",
       "Browse this PeerTube channel's federated videos. It is already known to this server."}

  defp known_local_descriptor("pixelfed", _source_kind),
    do:
      {"Pixelfed profile",
       "Browse this Pixelfed profile's public photographs. It is already known to this server."}

  defp known_local_descriptor("owncast", _source_kind),
    do:
      {"Owncast stream",
       "Open this Owncast stream's public service profile. It is already known to this server."}

  defp known_local_descriptor("funkwhale", _source_kind),
    do:
      {"Funkwhale library",
       "Browse this Funkwhale library and its public audio. It is already known to this server."}

  defp known_local_descriptor("bookwyrm", _source_kind),
    do:
      {"BookWyrm reader",
       "Browse this BookWyrm reader's shelves and reading activity. It is already known to this server."}

  defp known_local_descriptor("manyfold", _source_kind),
    do:
      {"Manyfold model source",
       "Browse this Manyfold actor's public 3D models and files. It is already known to this server."}

  defp known_local_descriptor("mobilizon", _source_kind),
    do:
      {"Mobilizon organizer",
       "Browse this Mobilizon organizer's public events. It is already known to this server."}

  defp known_local_descriptor("gancio", _source_kind),
    do:
      {"Gancio calendar",
       "Browse this Gancio calendar's public events. It is already known to this server."}

  defp known_local_descriptor("neodb", _source_kind),
    do:
      {"NeoDB catalog",
       "Browse this NeoDB actor's public cultural catalog. It is already known to this server."}

  defp known_local_descriptor("wanderer", _source_kind),
    do:
      {"Wanderer routes",
       "Browse this Wanderer actor's public routes and trails. It is already known to this server."}

  defp known_local_descriptor("flohmarkt", _source_kind),
    do:
      {"Marketplace profile",
       "Browse this marketplace actor's public listings. It is already known to this server."}

  defp known_local_descriptor("bonfire", _source_kind),
    do:
      {"Bonfire community",
       "Browse this Bonfire actor's received public coordination records. It is already known to this server."}

  defp known_local_descriptor(platform, _source_kind)
       when platform in ["forgefed", "vervis", "forgejo", "gitea", "gitlab"],
       do:
         {"Federated forge",
          "Browse this federated forge's public projects and development activity. It is already known to this server."}

  defp known_local_descriptor(platform, _source_kind)
       when platform in ["castling", "castling_club"],
       do:
         {"Chess player",
          "Browse this actor's public chess games and activity. It is already known to this server."}

  defp known_local_descriptor("writefreely", _source_kind),
    do:
      {"WriteFreely publication",
       "Browse this publication's public writing. It is already known to this server."}

  defp known_local_descriptor("rss", _source_kind),
    do:
      {"RSS feed",
       "Browse this feed's imported public entries. It is already known to this server."}

  defp known_local_descriptor(_platform, source_kind),
    do:
      {source_kind, "This #{String.downcase(source_kind)} actor is already known to this server."}

  defp known_local_group_descriptor("lemmy"),
    do:
      {"Lemmy community",
       "Browse this Lemmy community's public discussions. It is already known to this server."}

  defp known_local_group_descriptor("mbin"),
    do:
      {"Mbin magazine",
       "Browse this Mbin magazine's public posts and discussions. It is already known to this server."}

  defp known_local_group_descriptor("piefed"),
    do:
      {"PieFed community",
       "Browse this PieFed community's public discussions. It is already known to this server."}

  defp known_local_group_descriptor("nodebb"),
    do:
      {"NodeBB category",
       "Browse this NodeBB category's public topics. It is already known to this server."}

  defp known_local_group_descriptor("discourse"),
    do:
      {"Discourse category",
       "Browse this Discourse category's public topics. It is already known to this server."}

  defp known_local_group_descriptor("hubzilla"),
    do:
      {"Hubzilla channel",
       "Browse this Hubzilla channel's public posts. It is already known to this server."}

  defp known_local_group_descriptor("friendica"),
    do:
      {"Friendica forum",
       "Browse this Friendica forum's public discussions. It is already known to this server."}

  defp known_local_group_descriptor("bonfire"),
    do:
      {"Bonfire group",
       "Browse this Bonfire group's public activity. It is already known to this server."}

  defp known_local_group_descriptor(_platform),
    do:
      {"Federated group",
       "Browse this federated group's public discussions. It is already known to this server."}

  defp community_item(url, spec) do
    with {:ok, origin, host} <- safe_origin(url) do
      %{
        id: "#{spec.platform}:#{host}",
        family: spec.family,
        platform: spec.platform,
        title: spec.title,
        workflow: spec.workflow,
        url: origin,
        origin_type: "operator_index",
        access_mode: "external",
        resolver_enabled: true,
        resolver_label: resolver_label(spec.platform),
        source_host: host
      }
    end
  end

  # Directories and ecosystem guides are only the first half of discovery.
  # These labels explain which concrete ActivityPub identifier the shared local
  # resolver can accept after a person chooses a remote target. ActivityPods is
  # intentionally excluded because its useful records are normally private and
  # invitation-bound rather than anonymously resolvable.
  defp resolver_enabled?("activitypods", _access_mode), do: false
  defp resolver_enabled?(_platform, "local"), do: false
  defp resolver_enabled?(_platform, _access_mode), do: true

  defp resolver_label("bookwyrm"), do: "Resolve reader, book, or review"
  defp resolver_label("neodb"), do: "Resolve member or catalogue item"
  defp resolver_label("castling"), do: "Resolve player or chess game"
  defp resolver_label("castling.club"), do: "Resolve player or chess game"
  defp resolver_label("manyfold"), do: "Resolve creator, model, or collection"
  defp resolver_label("flohmarkt"), do: "Resolve seller or listing"
  defp resolver_label("wanderer"), do: "Resolve route author or trail"
  defp resolver_label("forgefed"), do: "Resolve project or repository"
  defp resolver_label("bonfire"), do: "Resolve public actor or coordination record"
  defp resolver_label("postmarks"), do: "Resolve bookmark actor or item"
  defp resolver_label("mobilizon"), do: "Resolve group or event"
  defp resolver_label("gancio"), do: "Resolve event service or event"
  defp resolver_label("funkwhale"), do: "Resolve library, channel, or track"
  defp resolver_label("peertube"), do: "Resolve channel or video"
  defp resolver_label("owncast"), do: "Resolve stream service"
  defp resolver_label("pixelfed"), do: "Resolve photographer or post"
  defp resolver_label(_platform), do: "Resolve actor or item"

  defp safe_origin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, port: port}
      when is_binary(host) and byte_size(host) <= 255 ->
        host = String.downcase(host)
        {:ok, URI.to_string(%URI{scheme: "https", host: host, port: port}), host}

      _ ->
        :error
    end
  end

  defp safe_origin(_url), do: :error

  # Reviewed community cards are outbound browser links, not provider API
  # endpoints. Preserve a safe path so operators can point at a maintained
  # public directory while keeping configured API indexes root-only.
  defp safe_catalog_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        query: nil,
        fragment: nil,
        port: port,
        path: path
      }
      when is_binary(host) and byte_size(host) <= 255 ->
        with {:ok, path} <- safe_catalog_path(path) do
          host = String.downcase(host)
          {:ok, URI.to_string(%URI{scheme: "https", host: host, port: port, path: path}), host}
        end

      _ ->
        :error
    end
  end

  defp safe_catalog_path(nil), do: {:ok, nil}
  defp safe_catalog_path(""), do: {:ok, nil}

  defp safe_catalog_path(path) when is_binary(path) and byte_size(path) <= 1_000 do
    decoded_path = URI.decode(path)
    segments = String.split(decoded_path, "/", trim: true)

    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
         not String.contains?(decoded_path, ["\\", <<0>>]) and
         not String.match?(decoded_path, ~r/[\x01-\x1F\x7F]/) and
         Enum.all?(segments, &(&1 not in [".", ".."])) do
      {:ok, path}
    else
      :error
    end
  end

  defp safe_catalog_path(_path), do: :error

  defp safe_actor_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and byte_size(host) <= 255 and byte_size(url) <= 2_000 ->
        {:ok, url, String.downcase(host)}

      _ ->
        :error
    end
  end

  defp safe_actor_url(_url), do: :error

  # Worlds routes remote account records through /@account@host. Do not expose
  # an internal route unless the stored nickname is a bounded account handle;
  # imported or malformed legacy nicknames must remain inert catalog metadata.
  defp safe_local_profile_url(nickname) when is_binary(nickname) do
    nickname = String.trim(nickname)

    if byte_size(nickname) in 1..255 and
         Regex.match?(~r/^[[:alnum:]_.-]+(?:@[[:alnum:].-]+)?$/u, nickname) do
      "/@#{nickname}"
    end
  end

  defp safe_local_profile_url(_nickname), do: nil

  defp entry_text(entry, key, maximum) do
    entry
    |> Map.get(key, Map.get(entry, Atom.to_string(key)))
    |> bounded_text(maximum)
  end

  defp bounded_text(value, maximum) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, maximum)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp bounded_text(_value, _maximum), do: nil

  defp normalized_family(params) do
    case Map.get(params, "family") do
      family when family in @supported_families -> family
      _ -> "all"
    end
  end
end

# end of native_community_catalog.ex
