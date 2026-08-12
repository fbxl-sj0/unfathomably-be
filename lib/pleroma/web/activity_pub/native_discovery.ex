# Unfathomably native federation discovery
# -----------------------------------------
#
# File: native_discovery.ex
#
# Purpose:
#   Discover specialized public objects through operator-approved ecosystem
#   indexes without treating arbitrary web hosts as trusted directories.
#
# Responsibilities:
#   - validate configured HTTPS discovery indexes
#   - verify PeerTube results against each index's accepted server links
#   - present accepted PeerTube communities without querying those peers
#   - bound remote requests, response sizes, result counts, and text fields
#   - normalize provider data into a stable frontend-facing envelope
#
# This file intentionally does not follow actors, import remote objects, or
# contact every server in a provider's federation graph.

defmodule Pleroma.Web.ActivityPub.NativeDiscovery do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.HTTP
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.AggregateFeedMembership
  alias Pleroma.Web.ActivityPub.CastlingDiscovery
  alias Pleroma.Web.ActivityPub.CoordinationDiscovery
  alias Pleroma.Web.ActivityPub.ForgeDiscovery
  alias Pleroma.Web.ActivityPub.ManyfoldDiscovery
  alias Pleroma.Web.ActivityPub.PhotoDiscovery
  alias Pleroma.Web.ActivityPub.PublishingDiscovery

  @graph_ttl_ms :timer.minutes(10)
  @directory_ttl_ms :timer.minutes(5)
  @http_timeout 15_000
  @provider_search_timeout 5_000
  @max_provider_concurrency 8
  @max_body_bytes 4_000_000
  @max_graph_pages 5
  @max_limit 24
  @max_offset 10_000
  @local_group_scan_limit 200
  @max_query_length 200
  @neodb_page_size 16
  @peer_page_size 100
  @gancio_search_scan_limit 100

  @mobilizon_query """
  query SearchEvents($term: String, $beginsOn: DateTime, $page: Int, $limit: Int) {
    searchEvents(term: $term, beginsOn: $beginsOn, page: $page, limit: $limit) {
      total
      elements {
        ... on Event {
          uuid
          title
          description
          beginsOn
          endsOn
          status
          url
          picture { url }
          physicalAddress { description locality region country }
          organizerActor { preferredUsername name domain url }
          attributedTo { preferredUsername name domain url }
          options {
            isOnline
            maximumAttendeeCapacity
            remainingAttendeeCapacity
            timezone
          }
        }
      }
    }
  }
  """

  @type result :: %{
          items: [map()],
          total: non_neg_integer(),
          has_more: boolean(),
          next_offset: non_neg_integer() | nil,
          providers: [map()],
          communities: [map()]
        }

  @local_status_candidate_keys [
    :activitypub_url,
    :canonical_url,
    :object_url,
    :ap_id,
    :status_url,
    :activity_url,
    :url,
    :source_url,
    :id
  ]

  @doc "Attach visible current and exact-revision status IDs to locally stored discovery items."
  @spec attach_local_status_ids(result(), Pleroma.User.t() | nil) :: result()
  def attach_local_status_ids(result, reading_user \\ nil)

  def attach_local_status_ids(%{items: items} = result, reading_user) when is_list(items) do
    object_ids =
      items
      |> Enum.flat_map(&local_status_candidates/1)
      |> Enum.uniq()

    activity_ids =
      items
      |> Enum.map(&discovery_value(&1, :id))
      |> Enum.filter(&local_activity_id?/1)
      |> Enum.uniq()

    if object_ids == [] and activity_ids == [] do
      result
    else
      object_status_records =
        object_ids
        |> Activity.create_by_object_ap_id()
        |> Repo.all()
        |> Repo.preload(:object)
        |> Enum.filter(&Pleroma.Web.ActivityPub.Visibility.visible_for_user?(&1, reading_user))
        |> Enum.sort_by(&local_status_sort_key/1, :asc)
        |> Enum.reduce(%{}, fn activity, status_records ->
          case create_object_id(activity) do
            object_id when is_binary(object_id) ->
              Map.put_new(status_records, object_id, local_status_record(activity, object_id))

            _ ->
              status_records
          end
        end)

      activity_status_records =
        activity_ids
        |> Activity.all_by_ids_with_object()
        |> Enum.filter(&Pleroma.Web.ActivityPub.Visibility.visible_for_user?(&1, reading_user))
        |> Enum.reduce(%{}, fn
          %Activity{id: id, data: %{"type" => "Create"}} = activity, status_records ->
            id = to_string(id)
            Map.put(status_records, id, local_status_record(activity, create_object_id(activity)))

          _activity, status_records ->
            status_records
        end)

      items =
        Enum.map(items, fn item ->
          revision_record = Map.get(activity_status_records, discovery_value(item, :id))

          candidate_record =
            item
            |> local_status_candidates()
            |> Enum.find_value(&Map.get(object_status_records, &1))

          current_record =
            candidate_record ||
              (revision_record &&
                 Map.get(object_status_records, revision_record.canonical_object_url))

          put_local_status_reference(item, current_record, revision_record)
        end)

      %{result | items: items}
    end
  end

  def attach_local_status_ids(%{"items" => items} = result, reading_user) when is_list(items) do
    %{items: items} = attach_local_status_ids(%{items: items}, reading_user)
    Map.put(result, "items", items)
  end

  def attach_local_status_ids(result, _reading_user), do: result

  defp local_status_candidates(item) when is_map(item) do
    @local_status_candidate_keys
    |> Enum.map(&discovery_value(item, &1))
    |> Enum.filter(&local_object_id?/1)
    |> Enum.uniq()
  end

  defp local_status_candidates(_item), do: []

  defp local_object_id?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp local_object_id?(_value), do: false

  defp local_activity_id?(value) when is_binary(value) and byte_size(value) <= 128 do
    value != "" and Regex.match?(~r/\A[A-Za-z0-9]+\z/, value)
  end

  defp local_activity_id?(_value), do: false

  defp create_object_id(%Activity{data: %{"object" => object_id}}) when is_binary(object_id),
    do: object_id

  defp create_object_id(%Activity{data: %{"object" => %{"id" => object_id}}})
       when is_binary(object_id),
       do: object_id

  defp create_object_id(_activity), do: nil

  defp local_status_record(%Activity{} = activity, object_id) do
    %{
      canonical_object_url: object_id,
      revision_activity_url: discovery_value(activity.data, :id),
      status_id: to_string(activity.id)
    }
  end

  defp local_status_sort_key(%Activity{} = activity) do
    object_data = if activity.object, do: activity.object.data, else: %{}

    {
      discovery_value(object_data, :updated) || discovery_value(object_data, :published) || "",
      discovery_value(activity.data, :published) || "",
      to_string(activity.id)
    }
  end

  defp put_local_status_reference(item, nil, nil), do: item

  defp put_local_status_reference(item, current_record, revision_record) do
    current_record = current_record || revision_record
    revision_record = revision_record || current_record

    item
    |> Map.put(:status_id, current_record.status_id)
    |> Map.put(:current_status_id, current_record.status_id)
    |> Map.put(:revision_status_id, revision_record.status_id)
    |> maybe_put_discovery_value(:canonical_object_url, current_record.canonical_object_url)
    |> maybe_put_discovery_value(:revision_activity_url, revision_record.revision_activity_url)
  end

  defp maybe_put_discovery_value(item, _key, nil), do: item
  defp maybe_put_discovery_value(item, key, value), do: Map.put(item, key, value)
  @spec search(map()) :: result()
  def search(%{"family" => "mobilizon_event"} = params) do
    Pleroma.Web.ActivityPub.MobilizonSearchDiscovery.search(params, :events)
  end

  def search(%{"family" => "mobilizon_group"} = params) do
    Pleroma.Web.ActivityPub.MobilizonSearchDiscovery.search(params, :groups)
  end

  def search(%{"family" => "groups"} = params) do
    limit = bounded_integer(params["limit"], 12, 1, @max_limit)
    offset = bounded_integer(params["offset"], 0, 0, @max_offset)

    merge_results(
      [
        aggregate_feed_result(params, limit, offset),
        local_group_result(params, limit, offset),
        Pleroma.Web.ActivityPub.MobilizonSearchDiscovery.search(params, :groups)
      ],
      limit,
      offset,
      params
    )
  end

  def search(%{"family" => "peertube_channel"} = params) do
    Pleroma.Web.ActivityPub.PeerTubeChannelDiscovery.search(params)
  end

  def search(%{"family" => "reading"} = params) do
    Pleroma.Web.ActivityPub.ReadingDiscovery.search(params)
  end

  def search(%{"family" => "neodb_activity"} = params) do
    Pleroma.Web.ActivityPub.NeoDBActivityDiscovery.search(params)
  end

  def search(%{"family" => "received_audio"} = params) do
    Pleroma.Web.ActivityPub.AudioObjectDiscovery.search(params)
  end

  def search(%{"family" => "music_catalog"} = params) do
    Pleroma.Web.ActivityPub.MusicCatalogDiscovery.search(params)
  end

  def search(%{"family" => "received_event"} = params) do
    Pleroma.Web.ActivityPub.EventObjectDiscovery.search(params)
  end

  def search(%{"family" => "received_market"} = params) do
    Pleroma.Web.ActivityPub.MarketplaceObjectDiscovery.search(params)
  end

  def search(%{"family" => "received_route"} = params) do
    Pleroma.Web.ActivityPub.RouteObjectDiscovery.search(params)
  end

  def search(%{"family" => "received_development"} = params) do
    Pleroma.Web.ActivityPub.ForgeFedObjectDiscovery.search(params)
  end

  def search(%{"family" => "received_model"} = params) do
    Pleroma.Web.ActivityPub.ManyfoldActorDiscovery.search(params)
  end

  def search(%{"family" => "received_video"} = params) do
    Pleroma.Web.ActivityPub.VideoObjectDiscovery.search(params)
  end

  def search(%{"family" => "received_playlist"} = params) do
    Pleroma.Web.ActivityPub.VideoPlaylistDiscovery.search(params)
  end

  def search(params) when is_map(params) do
    family = normalized_family(params)
    query = normalized_query(params)
    limit = bounded_integer(params["limit"], 12, 1, @max_limit)
    offset = bounded_integer(params["offset"], 0, 0, @max_offset)
    catalog_category = normalized_catalog_category(params)
    discovery_mode = normalized_discovery_mode(params)

    results =
      case family do
        "video" when discovery_mode == "communities" ->
          Enum.map(peertube_indexes(), fn index ->
            fn -> discover_peertube_communities(index, limit) end
          end)

        "video" ->
          Enum.map(peertube_indexes(), fn index ->
            fn -> search_peertube(index, query, limit, offset) end
          end) ++
            Enum.map(owncast_directory_indexes(), fn index ->
              fn -> search_owncast(index, query, limit, offset) end
            end) ++
            [
              fn -> Pleroma.Web.ActivityPub.VideoObjectDiscovery.search(params) end,
              fn -> Pleroma.Web.ActivityPub.VideoPlaylistDiscovery.search(params) end
            ]

        "event" ->
          Enum.map(mobilizon_indexes(), fn index ->
            fn -> search_mobilizon(index, query, limit, offset) end
          end) ++
            Enum.map(gancio_indexes(), fn index ->
              fn -> search_gancio(index, query, limit, offset) end
            end) ++
            [fn -> Pleroma.Web.ActivityPub.EventObjectDiscovery.search(params) end]

        "game" ->
          CastlingDiscovery.searches(query, limit, offset)

        "development" ->
          ForgeDiscovery.searches(query, limit, offset) ++
            [fn -> Pleroma.Web.ActivityPub.ForgeFedObjectDiscovery.search(params) end]

        "livestream" ->
          Enum.map(owncast_directory_indexes(), &search_owncast(&1, query, limit, offset))

        "coordination" ->
          CoordinationDiscovery.searches(query, limit, offset)

        "photo" ->
          PhotoDiscovery.searches(query, limit, offset)

        family when family in ["bookmarks", "longform", "publishing"] ->
          PublishingDiscovery.searches(family, query, limit, offset)

        "audio" when query == "" ->
          [
            fn -> Pleroma.Web.ActivityPub.AudioObjectDiscovery.search(params) end,
            fn -> Pleroma.Web.ActivityPub.MusicCatalogDiscovery.search(params) end
          ]

        "audio" ->
          Enum.map(funkwhale_indexes(), &search_funkwhale(&1, query, limit, offset)) ++
            [
              fn -> Pleroma.Web.ActivityPub.AudioObjectDiscovery.search(params) end,
              fn -> Pleroma.Web.ActivityPub.MusicCatalogDiscovery.search(params) end
            ]

        "catalog" ->
          Enum.map(neodb_indexes(), &search_neodb(&1, catalog_category, query, limit, offset)) ++
            bookwyrm_searches(catalog_category, query, limit, offset) ++
            local_catalog_searches(catalog_category, params)

        "market" ->
          Enum.map(flohmarkt_indexes(), &search_flohmarkt(&1, query, limit, offset)) ++
            [fn -> Pleroma.Web.ActivityPub.MarketplaceObjectDiscovery.search(params) end]

        "route" ->
          Enum.map(wanderer_indexes(), &search_wanderer(&1, limit, offset)) ++
            [fn -> Pleroma.Web.ActivityPub.RouteObjectDiscovery.search(params) end]

        "model" ->
          ManyfoldDiscovery.searches(query, limit, offset) ++
            [fn -> Pleroma.Web.ActivityPub.ManyfoldActorDiscovery.search(params) end]

        "all" ->
          Enum.map(peertube_indexes(), &search_peertube(&1, query, limit, offset)) ++
            Enum.map(owncast_directory_indexes(), &search_owncast(&1, query, limit, offset)) ++
            Enum.map(mobilizon_indexes(), &search_mobilizon(&1, query, limit, offset)) ++
            Enum.map(gancio_indexes(), &search_gancio(&1, query, limit, offset)) ++
            Enum.map(funkwhale_indexes(), &search_funkwhale(&1, query, limit, offset)) ++
            Enum.map(wanderer_indexes(), &search_wanderer(&1, limit, offset)) ++
            CoordinationDiscovery.searches(query, limit, offset) ++
            PhotoDiscovery.searches(query, limit, offset) ++
            PublishingDiscovery.searches("bookmarks", query, limit, offset) ++
            PublishingDiscovery.searches("longform", query, limit, offset) ++
            PublishingDiscovery.searches("publishing", query, limit, offset)

        _ ->
          []
      end

    merge_results(results, limit, offset, params)
  end

  def search(_params), do: empty_result()

  defp local_group_result(params, limit, offset) do
    query = normalized_query(params) |> String.downcase()

    matching_groups =
      @local_group_scan_limit
      |> Pleroma.Web.FederatedTarget.public_native_groups()
      |> Enum.filter(&local_group_matches?(&1, query))

    items =
      matching_groups
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(&local_group_item/1)

    total = length(matching_groups)

    %{
      items: items,
      total: total,
      has_more: total > offset + limit,
      next_offset: if(total > offset + limit, do: offset + limit, else: nil),
      provider: %{
        host: Pleroma.Web.Endpoint.url() |> URI.parse() |> Map.get(:host),
        status: "ready"
      },
      communities: []
    }
  end

  defp aggregate_feed_result(params, limit, offset) do
    query = normalized_query(params)

    %{entries: entries, total: total} =
      AggregateFeedMembership.search_communities(query, limit, offset)

    items = Enum.map(entries, &aggregate_feed_item/1)

    %{
      items: items,
      total: total,
      has_more: total > offset + length(items),
      next_offset: if(total > offset + length(items), do: offset + length(items), else: nil),
      provider: %{
        host: Pleroma.Web.Endpoint.url() |> URI.parse() |> Map.get(:host),
        status: "ready",
        type: "aggregate_feed"
      },
      communities: []
    }
  end

  defp aggregate_feed_item({%User{} = community, %User{} = feed}) do
    ap_id = Map.get(community, :ap_id)
    nickname = Map.get(community, :nickname)

    %{
      id: "group:" <> to_string(Map.get(community, :id)),
      family: "group",
      kind: "group",
      title: Map.get(community, :name) || nickname || ap_id,
      handle: nickname,
      summary: text(Map.get(community, :bio), 320),
      url: ap_id,
      source_host:
        case URI.parse(ap_id || "") do
          %URI{host: host} when is_binary(host) -> host
          _ -> nil
        end,
      account: %{name: Map.get(community, :name) || nickname, url: ap_id},
      curated_by: %{
        id: to_string(Map.get(feed, :id)),
        title: Map.get(feed, :name) || Map.get(feed, :nickname) || Map.get(feed, :ap_id),
        handle: Map.get(feed, :nickname),
        url: Map.get(feed, :ap_id)
      }
    }
  end

  defp local_group_matches?(_group, ""), do: true

  defp local_group_matches?(%User{} = group, query) do
    [:name, :nickname, :ap_id, :bio]
    |> Enum.map(&(Map.get(group, &1) || ""))
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> String.contains?(query)
  end

  defp local_group_item(%User{} = group) do
    ap_id = Map.get(group, :ap_id)
    nickname = Map.get(group, :nickname)

    %{
      id: "group:" <> to_string(Map.get(group, :id)),
      family: "group",
      kind: "group",
      title: Map.get(group, :name) || nickname || ap_id,
      handle: nickname,
      summary: text(Map.get(group, :bio), 320),
      url: ap_id,
      source_host:
        case URI.parse(ap_id || "") do
          %URI{host: host} when is_binary(host) -> host
          _ -> nil
        end,
      account: %{name: Map.get(group, :name) || nickname, url: ap_id}
    }
  end

  defp search_peertube(index, query, limit, offset) do
    with {:ok,
          %{
            graph: %{hosts: accepted_hosts, peers: peers},
            videos: payload
          }} <- fetch_peertube_search_data(index, query, limit, offset) do
      raw_items = if is_list(payload["data"]), do: payload["data"], else: []

      items =
        raw_items
        |> Enum.filter(&safe_peertube_video?(&1, accepted_hosts, index))
        |> Enum.map(&normalize_peertube_video(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      raw_total = non_negative_integer(payload["total"])
      consumed = length(raw_items)

      %{
        items: items,
        total: raw_total,
        has_more: consumed > 0 and offset + consumed < raw_total,
        provider: provider_metadata(index, "ready", MapSet.size(accepted_hosts)),
        communities: peertube_communities(peers, index, query, limit)
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0),
          communities: []
        }
    end
  end

  # The accepted-host graph validates video origins, but it does not depend on
  # the video response itself. Fetch both concurrently so a cold graph refresh
  # does not add its latency to the recent-video request.
  defp fetch_peertube_search_data(index, query, limit, offset) do
    [
      {:graph, fn -> accepted_peertube_graph(index) end},
      {:videos, fn -> fetch_peertube_videos(index, query, limit, offset) end}
    ]
    |> Task.async_stream(
      fn {key, fetch} -> {key, fetch.()} end,
      ordered: false,
      max_concurrency: 2,
      timeout: @provider_search_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {key, {:ok, value}}}, {:ok, values} ->
        {:cont, {:ok, Map.put(values, key, value)}}

      _failed_result, _values ->
        {:halt, {:error, :provider_unavailable}}
    end)
    |> case do
      {:ok, %{graph: graph, videos: videos}} -> {:ok, %{graph: graph, videos: videos}}
      _incomplete -> {:error, :provider_unavailable}
    end
  end

  # PeerTube's accepted-server graph is useful community discovery in its own
  # right. Keep it separate from video search so a person can deliberately
  # inspect connected communities without loading an arbitrary video page.
  defp discover_peertube_communities(index, limit) do
    with {:ok, %{hosts: accepted_hosts, peers: peers}} <- accepted_peertube_graph(index) do
      %{
        items: [],
        total: 0,
        has_more: false,
        provider: provider_metadata(index, "ready", MapSet.size(accepted_hosts)),
        communities: peertube_communities(peers, index, "", limit)
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0),
          communities: []
        }
    end
  end

  defp search_mobilizon(index, query, limit, offset) do
    with {:ok, payload} <- fetch_mobilizon_events(index, query, limit, offset),
         %{"data" => %{"searchEvents" => search}} when is_map(search) <- payload do
      raw_items = if is_list(search["elements"]), do: search["elements"], else: []

      items =
        raw_items
        |> Enum.filter(&safe_mobilizon_event?/1)
        |> Enum.map(&normalize_mobilizon_event/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      total = non_negative_integer(search["total"])

      %{
        items: items,
        total: total,
        has_more: raw_items != [] and offset + limit < total,
        provider: provider_metadata(index, "ready", 0, "mobilizon")
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0, "mobilizon")
        }
    end
  end

  defp fetch_mobilizon_events(index, "", limit, 0) do
    cached_provider_response({:mobilizon_upcoming_events, index, limit}, fn ->
      do_fetch_mobilizon_events(index, "", limit, 0)
    end)
  end

  defp fetch_mobilizon_events(index, query, limit, offset) do
    do_fetch_mobilizon_events(index, query, limit, offset)
  end

  defp do_fetch_mobilizon_events(index, query, limit, offset) do
    page = div(offset, limit) + 1

    body =
      Jason.encode!(%{
        query: @mobilizon_query,
        variables: %{
          term: query,
          beginsOn: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          page: page,
          limit: limit
        }
      })

    post_json(index <> "/api", body)
  end

  defp search_gancio(index, "", limit, 0) do
    with {:ok, events} when is_list(events) <- fetch_gancio_events(index, limit) do
      items =
        events
        |> Enum.filter(&safe_gancio_event?/1)
        |> Enum.map(&normalize_gancio_event(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      %{
        items: items,
        total: length(items),
        has_more: false,
        provider: provider_metadata(index, "ready", 0, "gancio")
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0, "gancio")
        }
    end
  end

  # Gancio's public endpoint is browse-only. For an explicit Worlds search we
  # inspect one bounded upcoming-event window locally rather than pretending
  # the provider has no matching data or attempting a server-wide crawl.
  defp search_gancio(index, query, limit, 0) when is_binary(query) do
    with {:ok, events} when is_list(events) <-
           fetch_gancio_events(index, @gancio_search_scan_limit) do
      items =
        events
        |> Enum.filter(&safe_gancio_event?/1)
        |> Enum.filter(&matches_gancio_query?(&1, query))
        |> Enum.map(&normalize_gancio_event(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      %{
        items: items,
        total: length(items),
        has_more: false,
        provider: provider_metadata(index, "ready", 0, "gancio")
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0, "gancio")
        }
    end
  end

  # Gancio does not expose an offset-aware public search endpoint. Its first
  # page is a bounded local filter over upcoming events; subsequent offsets
  # are therefore exhausted rather than issuing duplicate provider requests
  # or leaving the combined event search without a matching function clause.
  defp search_gancio(index, _query, _limit, offset) when offset > 0 do
    %{
      items: [],
      total: 0,
      has_more: false,
      provider: provider_metadata(index, "ready", 0, "gancio")
    }
  end

  defp search_funkwhale(index, query, limit, offset) do
    with {:ok, payload} <- fetch_funkwhale_tracks(index, query, limit, offset) do
      raw_items = if is_list(payload["results"]), do: payload["results"], else: []

      items =
        raw_items
        |> Enum.filter(&safe_funkwhale_track?/1)
        |> Enum.map(&normalize_funkwhale_track(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      total = non_negative_integer(payload["count"])

      %{
        items: items,
        total: total,
        has_more: raw_items != [] and offset + limit < total,
        provider: provider_metadata(index, "ready", 0, "funkwhale")
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0, "funkwhale")
        }
    end
  end

  defp search_neodb(index, _category, "", _limit, _offset) do
    %{
      items: [],
      total: 0,
      has_more: false,
      provider: provider_metadata(index, "ready", 0, "neodb")
    }
  end

  defp search_neodb(index, category, query, limit, offset) do
    with {:ok, payload} <- fetch_neodb_catalog(index, category, query, offset) do
      raw_items = if is_list(payload["data"]), do: payload["data"], else: []

      items =
        raw_items
        |> Enum.filter(&safe_neodb_item?(&1, category))
        |> Enum.map(&normalize_neodb_item(&1, index, category))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      total = non_negative_integer(payload["count"])
      consumed = length(raw_items)

      %{
        items: items,
        total: total,
        has_more: consumed > 0 and offset + consumed < total,
        provider: provider_metadata(index, "ready", 0, "neodb")
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0, "neodb")
        }
    end
  end

  defp bookwyrm_searches("book", query, limit, offset) do
    Enum.map(bookwyrm_indexes(), &search_bookwyrm(&1, query, limit, offset))
  end

  defp bookwyrm_searches(_category, _query, _limit, _offset), do: []

  defp local_catalog_searches("book", params) do
    [
      fn -> Pleroma.Web.ActivityPub.ReadingDiscovery.search(params) end,
      fn -> Pleroma.Web.ActivityPub.NeoDBActivityDiscovery.search(params) end
    ]
  end

  defp local_catalog_searches(_category, params) do
    [fn -> Pleroma.Web.ActivityPub.NeoDBActivityDiscovery.search(params) end]
  end

  defp search_bookwyrm(index, _query, _limit, offset) when offset > 0 do
    %{
      items: [],
      total: 0,
      has_more: false,
      provider: provider_metadata(index, "ready", 0, "bookwyrm")
    }
  end

  defp search_bookwyrm(index, "", _limit, _offset) do
    %{
      items: [],
      total: 0,
      has_more: false,
      provider: provider_metadata(index, "ready", 0, "bookwyrm")
    }
  end

  defp search_bookwyrm(index, query, limit, 0) do
    with {:ok, document} <- fetch_bookwyrm_search(index, query) do
      items =
        document
        |> Floki.find("li.local-book-search-result")
        |> Enum.map(&normalize_bookwyrm_item(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      %{
        items: items,
        total: length(items),
        has_more: false,
        provider: provider_metadata(index, "ready", 0, "bookwyrm")
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0, "bookwyrm")
        }
    end
  end

  # Flohmarkt applies its own locality rules to its public search endpoint. We
  # query only operator-approved peers, omit client coordinates, and retain the
  # result URL on the responding peer instead of expanding into its federation
  # graph. This makes marketplace discovery useful without becoming a crawler.
  defp search_flohmarkt(index, "", _limit, _offset) do
    %{
      items: [],
      total: 0,
      has_more: false,
      provider: provider_metadata(index, "ready", 0, "flohmarkt")
    }
  end

  defp search_flohmarkt(index, query, limit, offset) do
    with {:ok, payload} when is_list(payload) <- fetch_flohmarkt_items(index, query, offset) do
      items =
        payload
        |> Enum.filter(&safe_flohmarkt_item?/1)
        |> Enum.map(&normalize_flohmarkt_item(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      %{
        items: items,
        total: length(items),
        has_more: length(payload) > length(items),
        provider: provider_metadata(index, "ready", 0, "flohmarkt")
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0, "flohmarkt")
        }
    end
  end

  # Wanderer's recommendation endpoint is a bounded public browse feed, not a
  # general search service. We intentionally do not query every Wanderer peer
  # or follow authors: operators choose the source and people choose follows.
  defp search_wanderer(index, _limit, offset) when offset > 0 do
    %{
      items: [],
      total: 0,
      has_more: false,
      provider: provider_metadata(index, "ready", 0, "wanderer")
    }
  end

  defp search_wanderer(index, limit, 0) do
    with {:ok, trails} when is_list(trails) <- cached_wanderer_recommendations(index) do
      items =
        trails
        |> Enum.filter(&safe_wanderer_trail?/1)
        |> Enum.map(&normalize_wanderer_trail(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      %{
        items: items,
        total: length(items),
        has_more: false,
        provider: provider_metadata(index, "ready", 0, "wanderer")
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0, "wanderer")
        }
    end
  end

  # Owncast's official directory publishes an opt-in IPTV playlist. We only
  # retain HTTPS stream origins from operator-approved directory endpoints and
  # direct people to the originating Owncast page, never to an embedded HLS
  # player or a server-wide scan.
  defp search_owncast(index, query, limit, offset) do
    with {:ok, playlist} <- cached_owncast_playlist(index) do
      matching_streams =
        playlist
        |> parse_owncast_playlist()
        |> Enum.filter(&safe_owncast_stream?/1)
        |> Enum.filter(&matches_owncast_query?(&1, query))
        |> Enum.map(&normalize_owncast_stream(&1, index))
        |> Enum.reject(&is_nil/1)

      items =
        matching_streams
        |> Enum.drop(offset)
        |> Enum.take(limit)

      %{
        items: items,
        total: length(matching_streams),
        has_more: length(matching_streams) > offset + length(items),
        provider: provider_metadata(index, "ready", 0, "owncast")
      }
    else
      _ ->
        %{
          items: [],
          total: 0,
          has_more: false,
          provider: provider_metadata(index, "unavailable", 0, "owncast")
        }
    end
  end

  defp fetch_gancio_events(index, limit) do
    cached_provider_response({:gancio_upcoming_events, index, limit}, fn ->
      do_fetch_gancio_events(index, limit)
    end)
  end

  defp do_fetch_gancio_events(index, limit) do
    params = %{
      "start" => DateTime.utc_now() |> DateTime.to_unix(),
      "max" => limit,
      "show_recurrent" => false
    }

    index
    |> endpoint("/api/events", params)
    |> get_json()
  end

  defp fetch_funkwhale_tracks(index, query, limit, offset) do
    params =
      %{
        "page" => div(offset, limit) + 1,
        "page_size" => limit
      }
      |> maybe_put_funkwhale_search(query)

    index
    |> endpoint("/api/v1/tracks/", params)
    |> get_json()
  end

  defp fetch_neodb_catalog(index, category, query, offset) do
    params = %{
      "category" => category,
      "page" => div(offset, @neodb_page_size) + 1,
      "query" => query
    }

    index
    |> endpoint("/api/catalog/search", params)
    |> get_json()
  end

  defp fetch_bookwyrm_search(index, query) do
    index
    |> endpoint("/search/", %{"q" => query, "type" => "book"})
    |> get_html()
  end

  defp fetch_flohmarkt_items(index, query, offset) do
    index
    |> endpoint("/api/v1/item/search", %{"q" => query, "skip" => offset})
    |> get_json()
  end

  defp fetch_wanderer_recommendations(index) do
    index
    |> endpoint("/api/v1/trail/recommend", %{})
    |> get_json()
  end

  defp cached_wanderer_recommendations(index) do
    cached_provider_response({:wanderer_recommendations, index}, fn ->
      fetch_wanderer_recommendations(index)
    end)
  end

  defp fetch_owncast_playlist(index), do: get_text(index)

  defp cached_owncast_playlist(index) do
    cached_provider_response({:owncast_playlist, index}, fn -> fetch_owncast_playlist(index) end)
  end

  # Discovery directories are shared, read-only resources. Cache a successful
  # bounded response across local users so opening Worlds does not multiply
  # requests against a small ecosystem service. Failed requests are never
  # cached, allowing a provider to recover without waiting for the TTL.
  defp cached_provider_response(cache_suffix, fetch) when is_function(fetch, 0) do
    cache_key = {__MODULE__, :provider_response, cache_suffix}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      {expires_at, response} when expires_at > now ->
        {:ok, response}

      _ ->
        case :global.trans(
               {cache_key, self()},
               fn -> refresh_provider_response(cache_key, now, fetch) end
             ) do
          {:aborted, _reason} -> {:error, :provider_unavailable}
          result -> result
        end
    end
  end

  defp refresh_provider_response(cache_key, now, fetch) do
    case :persistent_term.get(cache_key, nil) do
      {expires_at, response} when expires_at > now ->
        {:ok, response}

      _ ->
        case fetch.() do
          {:ok, response} ->
            :persistent_term.put(cache_key, {now + @directory_ttl_ms, response})
            {:ok, response}

          error ->
            error
        end
    end
  end

  defp parse_owncast_playlist(playlist) when is_binary(playlist) do
    playlist
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reduce({nil, []}, fn line, {metadata, streams} ->
      cond do
        String.starts_with?(line, "#EXTINF:") ->
          {owncast_playlist_metadata(line), streams}

        valid_https_url?(line) and is_map(metadata) ->
          {nil, [Map.put(metadata, "stream_url", line) | streams]}

        String.starts_with?(line, "#") ->
          {nil, streams}

        true ->
          {nil, streams}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp parse_owncast_playlist(_playlist), do: []

  defp owncast_playlist_metadata(line) do
    %{
      "name" => owncast_playlist_title(line),
      "logo" => owncast_playlist_attribute(line, ~r/tvg-logo="([^"]*)"/),
      "tags" => owncast_playlist_attribute(line, ~r/tvg-tags="([^"]*)"/)
    }
  end

  defp owncast_playlist_title(line) do
    case Regex.run(~r/,([^,]+)$/, line) do
      [_, title] -> text(title, 300)
      _ -> nil
    end
  end

  defp owncast_playlist_attribute(line, pattern) do
    case Regex.run(pattern, line) do
      [_, value] -> text(value, 1_000)
      _ -> nil
    end
  end

  defp safe_owncast_stream?(%{"name" => name, "stream_url" => stream_url}) do
    is_binary(name) and is_binary(stream_url) and valid_https_url?(stream_url)
  end

  defp safe_owncast_stream?(_stream), do: false

  defp matches_owncast_query?(_stream, ""), do: true

  defp matches_owncast_query?(stream, query) when is_map(stream) do
    haystack = [stream["name"], stream["tags"]] |> Enum.filter(&is_binary/1) |> Enum.join(" ")
    String.contains?(String.downcase(haystack), String.downcase(query))
  end

  defp matches_owncast_query?(_stream, _query), do: false

  defp normalize_owncast_stream(stream, _directory) when is_map(stream) do
    stream_url = stream["stream_url"]
    name = text(stream["name"], 300)
    uri = URI.parse(stream_url || "")
    host = uri.host

    if name && host && valid_https_url?(stream_url) do
      source_url = URI.to_string(%URI{scheme: uri.scheme, host: host, port: uri.port})
      tags = owncast_tags(stream["tags"])

      %{
        id: "owncast:" <> String.downcase(host),
        family: "video",
        kind: "live_stream",
        title: name,
        summary: nil,
        url: source_url,
        thumbnail_url: owncast_thumbnail_url(stream["logo"]),
        published_at: nil,
        duration: 0,
        live: true,
        listed_live: true,
        tags: tags,
        sensitive: sensitive_owncast_tags?(tags),
        source_host: host,
        channel: %{name: name, url: source_url, host: host},
        activitypub_url: source_url,
        resolution_kind: "source_origin",
        local_action: "resolve"
      }
    end
  end

  defp normalize_owncast_stream(_stream, _directory), do: nil

  defp owncast_thumbnail_url(value) do
    case safe_url(value) do
      nil -> nil
      url -> Pleroma.Web.MediaProxy.browser_url(url)
    end
  end

  defp owncast_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",", trim: true)
    |> Enum.map(&text(&1, 80))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(12)
  end

  defp owncast_tags(_tags), do: []

  defp sensitive_owncast_tags?(tags) when is_list(tags) do
    Enum.any?(tags, fn tag ->
      tag = String.downcase(tag)
      tag in ["nsfw", "adult", "18+", "mature"]
    end)
  end

  defp sensitive_owncast_tags?(_tags), do: false

  defp safe_wanderer_trail?(%{"public" => true, "id" => id, "name" => name})
       when is_binary(id) and is_binary(name) do
    byte_size(id) <= 80 and byte_size(name) <= 300 and String.match?(id, ~r/^[A-Za-z0-9]+$/)
  end

  defp safe_wanderer_trail?(_trail), do: false

  defp normalize_wanderer_trail(trail, index) when is_map(trail) do
    id = text(trail["id"], 80)
    title = text(trail["name"], 300)
    host = URI.parse(index).host

    if id && title && host do
      activitypub_url = index <> "/api/v1/activitypub/trail/" <> id

      %{
        id: "wanderer:" <> host <> ":" <> id,
        family: "route",
        kind: "trail",
        title: title,
        summary: text(trail["description"], 1_000),
        url: canonical_wanderer_trail_url(index, id, trail["author_name"]) || activitypub_url,
        activitypub_url: activitypub_url,
        source_url: index,
        source_host: host,
        author: text(trail["author_name"], 200),
        category: text(trail["category"], 200),
        location: text(trail["location"], 300),
        distance: optional_non_negative_number(trail["distance"]),
        duration: optional_non_negative_number(trail["duration"]),
        elevation_gain: optional_non_negative_number(trail["elevation_gain"]),
        elevation_loss: optional_non_negative_number(trail["elevation_loss"]),
        published_at: unix_to_iso8601(trail["created"])
      }
    end
  end

  defp normalize_wanderer_trail(_trail, _index), do: nil

  # Wanderer's recommendation API identifies a trail by an API resource, but
  # its ActivityPub representation links to a stable browser route based on
  # the publishing handle. Keep both URLs: people open the browser route while
  # local resolution fetches the ActivityPub object with the expected Accept
  # header. The handle is constrained before it becomes part of a path.
  defp canonical_wanderer_trail_url(index, id, author_name) do
    author_name = text(author_name, 80)

    if is_binary(author_name) and
         String.match?(author_name, ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/) do
      index <> "/trail/view/@" <> author_name <> "/" <> id
    end
  end

  defp wanderer_indexes do
    Config.get([:native_discovery, :wanderer_indexes], [])
    |> configured_indexes()
  end

  defp owncast_directory_indexes do
    Config.get([:native_discovery, :owncast_directory_indexes], [])
    |> configured_directory_indexes()
  end

  defp fetch_peertube_videos(index, "", limit, 0) do
    cached_provider_response({:peertube_recent_videos, index, limit}, fn ->
      do_fetch_peertube_videos(index, "", limit, 0)
    end)
  end

  defp fetch_peertube_videos(index, query, limit, offset) do
    do_fetch_peertube_videos(index, query, limit, offset)
  end

  defp do_fetch_peertube_videos(index, query, limit, offset) do
    path = if query == "", do: "/api/v1/videos", else: "/api/v1/search/videos"

    params =
      %{
        "start" => offset,
        "count" => limit,
        "sort" => "-publishedAt"
      }
      |> maybe_put_search(query)

    index
    |> endpoint(path, params)
    |> get_json()
  end

  @doc false
  def accepted_peertube_graph(index) do
    cache_key = {__MODULE__, :accepted_peertube_hosts, index}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      {expires_at, graph} when expires_at > now ->
        {:ok, graph}

      _ ->
        case :global.trans(
               {cache_key, self()},
               fn -> refresh_peertube_hosts(cache_key, index) end
             ) do
          {:aborted, _reason} -> {:error, :provider_unavailable}
          result -> result
        end
    end
  end

  defp refresh_peertube_hosts(cache_key, index) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      {expires_at, hosts} when expires_at > now ->
        {:ok, hosts}

      _ ->
        graph = %{hosts: MapSet.new(), peers: []}

        with {:ok, graph} <- fetch_peer_directions(index, graph) do
          graph = %{
            hosts: MapSet.put(graph.hosts, URI.parse(index).host),
            peers: graph.peers |> merge_peer_directions() |> Enum.sort_by(& &1.host)
          }

          :persistent_term.put(cache_key, {now + @graph_ttl_ms, graph})
          {:ok, graph}
        end
    end
  end

  # PeerTube records server links in both directions. Reading both local API
  # collections avoids treating an outbound-only view as the whole federation
  # graph, while still never contacting any remote peer from Worlds.
  defp fetch_peer_directions(index, graph) do
    [
      {"/api/v1/server/following", "following"},
      {"/api/v1/server/followers", "follower"}
    ]
    |> Task.async_stream(
      fn {path, actor_key} ->
        fetch_peer_pages(
          index,
          path,
          actor_key,
          0,
          %{hosts: MapSet.new(), peers: []},
          @max_graph_pages
        )
      end,
      ordered: true,
      max_concurrency: 2,
      timeout: @provider_search_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce({0, graph}, fn
      {:ok, {:ok, direction_graph}}, {available, current_graph} ->
        {available + 1, merge_peer_graphs(current_graph, direction_graph)}

      _failed_direction, state ->
        state
    end)
    |> case do
      {0, _graph} -> {:error, :peer_graph_unavailable}
      {_available, updated_graph} -> {:ok, updated_graph}
    end
  end

  defp merge_peer_graphs(left, right) do
    %{
      hosts: MapSet.union(left.hosts, right.hosts),
      peers: right.peers ++ left.peers
    }
  end

  defp fetch_peer_pages(_index, _path, _actor_key, _start, graph, 0), do: {:ok, graph}

  defp fetch_peer_pages(index, path, actor_key, start, graph, pages_left) do
    params = %{"start" => start, "count" => @peer_page_size, "state" => "accepted"}

    with {:ok, payload} <- get_json(endpoint(index, path, params)),
         rows when is_list(rows) <- payload["data"] do
      graph = Enum.reduce(rows, graph, &put_accepted_peer(&1, actor_key, &2))
      total = non_negative_integer(payload["total"])
      next_start = start + length(rows)

      if rows == [] or next_start >= total do
        {:ok, graph}
      else
        fetch_peer_pages(index, path, actor_key, next_start, graph, pages_left - 1)
      end
    else
      _ -> {:error, :peer_graph_unavailable}
    end
  end

  defp put_accepted_peer(%{"state" => "accepted"} = row, actor_key, graph)
       when actor_key in ["following", "follower"] do
    case peertube_peer(Map.get(row, actor_key), actor_key) do
      nil -> graph
      peer -> %{hosts: MapSet.put(graph.hosts, peer.host), peers: [peer | graph.peers]}
    end
  end

  defp put_accepted_peer(_row, _actor_key, graph), do: graph

  defp peertube_peer(%{"host" => host} = actor, direction)
       when is_binary(host) and direction in ["following", "follower"] do
    host = host |> String.trim() |> String.downcase()

    with true <- valid_peer_host?(host),
         account_url when is_binary(account_url) <- peertube_server_actor_url(actor["url"], host) do
      %{
        host: host,
        name: text(actor["displayName"] || actor["name"], 200),
        account_url: account_url,
        local_url: locally_cached_profile_url(account_url),
        federation_directions: [direction]
      }
    end
  end

  defp peertube_peer(_actor, _direction), do: nil

  # The PeerTube API may include ordinary ActivityPub followers in its server
  # relationship feed. Only the conventional PeerTube server actor is a video
  # community; all other actors are intentionally excluded from this surface.
  defp peertube_server_actor_url(url, expected_host) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: actor_host,
        userinfo: nil,
        path: "/accounts/peertube",
        query: nil,
        fragment: nil
      }
      when is_binary(actor_host) ->
        if String.downcase(actor_host) == expected_host, do: safe_url(url)

      _ ->
        nil
    end
  end

  defp peertube_server_actor_url(_url, _expected_host), do: nil

  defp merge_peer_directions(peers) do
    peers
    |> Enum.group_by(& &1.host)
    |> Enum.map(fn {_host, [peer | same_host_peers]} ->
      directions =
        [peer | same_host_peers]
        |> Enum.flat_map(&Map.get(&1, :federation_directions, []))
        |> Enum.uniq()
        |> Enum.sort()

      %{peer | federation_directions: directions}
    end)
  end

  # The accepted-peer graph may expose a server actor URL. Consult only the
  # local cache before offering an internal profile route; an absent actor is
  # normal and must not trigger discovery traffic to that peer.
  defp locally_cached_profile_url(actor_url) do
    if is_binary(actor_url) do
      case User.get_cached_by_ap_id(actor_url) do
        %User{nickname: nickname} -> safe_local_profile_url(nickname)
        _ -> nil
      end
    end
  end

  defp safe_local_profile_url(nickname) when is_binary(nickname) do
    nickname = String.trim(nickname)

    if byte_size(nickname) in 1..255 and
         Regex.match?(~r/^[[:alnum:]_.-]+(?:@[[:alnum:].-]+)?$/u, nickname) do
      "/@#{nickname}"
    end
  end

  defp safe_local_profile_url(_nickname), do: nil

  defp valid_peer_host?(host) when is_binary(host) do
    case URI.parse("https://" <> host) do
      %URI{
        scheme: "https",
        host: parsed_host,
        userinfo: nil,
        path: path,
        query: nil,
        fragment: nil
      }
      when parsed_host == host and path in [nil, ""] ->
        true

      _ ->
        false
    end
  end

  defp valid_peer_host?(_host), do: false

  defp peertube_communities(peers, index, query, limit) do
    index_host = URI.parse(index).host

    peers
    |> Enum.filter(&matches_peertube_peer_query?(&1, query))
    |> Enum.map(&normalize_peertube_community(&1, index_host))
    |> Enum.take(limit)
  end

  defp matches_peertube_peer_query?(_peer, ""), do: true

  defp matches_peertube_peer_query?(peer, query) when is_map(peer) do
    haystack = [peer.host, peer.name] |> Enum.filter(&is_binary/1) |> Enum.join(" ")
    String.contains?(String.downcase(haystack), String.downcase(query))
  end

  defp matches_peertube_peer_query?(_peer, _query), do: false

  defp normalize_peertube_community(%{host: host} = peer, index_host)
       when is_binary(index_host) do
    %{
      id: "peertube-peer:" <> host,
      family: "video",
      kind: "video_community",
      title: "PeerTube on " <> host,
      summary: peertube_peer_summary(peer.federation_directions, index_host),
      url: "https://" <> host,
      source_host: host,
      local_url: peer.local_url,
      federation_directions: peer.federation_directions,
      channel: %{name: peer.name || "PeerTube", url: peer.account_url, host: host}
    }
  end

  defp peertube_peer_summary(["follower", "following"], index_host),
    do: "Accepted two-way federation link with " <> index_host <> "."

  defp peertube_peer_summary(["following"], index_host),
    do: "This PeerTube server follows " <> index_host <> "."

  defp peertube_peer_summary(["follower"], index_host),
    do: index_host <> " follows this PeerTube server."

  defp peertube_peer_summary(_directions, index_host),
    do: "Accepted federation peer of " <> index_host <> "."

  defp safe_peertube_video?(video, accepted_hosts, index) when is_map(video) do
    host = peertube_video_host(video)
    url = video["url"]

    video["privacy"]["id"] == 1 and video["nsfw"] == false and is_binary(url) and
      valid_https_url?(url) and is_binary(host) and
      (MapSet.member?(accepted_hosts, String.downcase(host)) or host == URI.parse(index).host)
  rescue
    _ -> false
  end

  defp safe_peertube_video?(_video, _accepted_hosts, _index), do: false

  defp normalize_peertube_video(video, index) when is_map(video) do
    channel = if is_map(video["channel"]), do: video["channel"], else: %{}
    account = if is_map(video["account"]), do: video["account"], else: %{}
    host = peertube_video_host(video)
    uuid = text(video["uuid"], 80)
    url = text(video["url"], 2_000)
    title = text(video["name"], 300)

    if uuid && url && title && host do
      %{
        id: "peertube:" <> uuid,
        family: "video",
        kind: "video",
        title: title,
        summary: text(video["truncatedDescription"] || video["description"], 1_000),
        url: url,
        thumbnail_url:
          index
          |> absolute_provider_url(video["thumbnailPath"])
          |> Pleroma.Web.MediaProxy.browser_url(),
        preview_url:
          index
          |> absolute_provider_url(video["previewPath"])
          |> Pleroma.Web.MediaProxy.browser_url(),
        embed_url: absolute_provider_url(index, video["embedPath"]),
        published_at: text(video["publishedAt"], 80),
        duration: non_negative_integer(video["duration"]),
        language: nested_label(video["language"]),
        category: nested_label(video["category"]),
        licence: nested_label(video["licence"]),
        live: video["isLive"] == true,
        source_host: host,
        channel: %{
          name: text(channel["displayName"] || channel["name"], 200),
          handle: channel_handle(channel),
          url: safe_url(channel["url"]),
          host: text(channel["host"], 255)
        },
        account: %{
          name: text(account["displayName"] || account["name"], 200),
          url: safe_url(account["url"])
        }
      }
    end
  end

  defp normalize_peertube_video(_video, _index), do: nil

  defp safe_mobilizon_event?(event) when is_map(event) do
    event["status"] == "CONFIRMED" and valid_https_url?(event["url"]) and
      future_datetime?(event["beginsOn"])
  end

  defp safe_mobilizon_event?(_event), do: false

  defp normalize_mobilizon_event(event) when is_map(event) do
    uuid = text(event["uuid"], 80)
    url = text(event["url"], 2_000)
    title = text(event["title"], 300)
    source_host = URI.parse(url || "").host
    address = if is_map(event["physicalAddress"]), do: event["physicalAddress"], else: %{}
    options = if is_map(event["options"]), do: event["options"], else: %{}
    actor = event_actor(event)

    if uuid && url && title && source_host do
      %{
        id: "mobilizon:" <> uuid,
        family: "event",
        kind: "event",
        title: title,
        summary: event["description"] |> plain_text() |> text(1_000),
        url: url,
        image_url:
          event
          |> Map.get("picture", %{})
          |> nested_url()
          |> Pleroma.Web.MediaProxy.browser_url(),
        begins_at: text(event["beginsOn"], 80),
        ends_at: text(event["endsOn"], 80),
        source_host: source_host,
        online: options["isOnline"] == true,
        timezone: text(options["timezone"], 100),
        capacity: optional_non_negative_integer(options["maximumAttendeeCapacity"]),
        remaining_capacity: optional_non_negative_integer(options["remainingAttendeeCapacity"]),
        location: %{
          name: first_text([address["description"], address["locality"]], 250),
          locality: text(address["locality"], 150),
          region: text(address["region"], 150),
          country: text(address["country"], 150)
        },
        organizer: %{
          name: first_text([actor["name"], actor["preferredUsername"]], 200),
          handle: actor_handle(actor),
          url: safe_url(actor["url"])
        }
      }
    end
  end

  defp normalize_mobilizon_event(_event), do: nil

  defp safe_gancio_event?(event) when is_map(event) do
    is_binary(event["title"]) and is_binary(event["slug"]) and
      future_unix?(event["start_datetime"])
  end

  defp safe_gancio_event?(_event), do: false

  defp matches_gancio_query?(_event, ""), do: true

  defp matches_gancio_query?(event, query) when is_map(event) and is_binary(query) do
    place = if is_map(event["place"]), do: event["place"], else: %{}

    haystack =
      [
        event["title"],
        event["slug"],
        event["description"],
        place["name"],
        place["address"] | gancio_tags(event["tags"])
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, String.downcase(query))
  end

  defp matches_gancio_query?(_event, _query), do: false

  defp normalize_gancio_event(event, index) when is_map(event) do
    identifier = to_string(event["id"] || "")
    slug = text(event["slug"], 300)
    title = text(event["title"], 300)
    start_at = unix_to_iso8601(event["start_datetime"])
    place = if is_map(event["place"]), do: event["place"], else: %{}
    host = URI.parse(index).host

    if identifier != "" && slug && title && start_at && host do
      %{
        id: "gancio:" <> host <> ":" <> identifier,
        family: "event",
        kind: "event",
        title: title,
        summary: nil,
        url: absolute_provider_url(index, "/event/" <> URI.encode(slug)),
        image_url:
          index
          |> gancio_image_url(event["media"])
          |> Pleroma.Web.MediaProxy.browser_url(),
        begins_at: start_at,
        ends_at: unix_to_iso8601(event["end_datetime"]),
        source_host: host,
        online: gancio_online?(event["online_locations"]),
        timezone: nil,
        capacity: nil,
        remaining_capacity: nil,
        tags: gancio_tags(event["tags"]),
        location: %{
          name: text(place["name"], 250),
          locality: text(place["address"], 250),
          region: nil,
          country: nil
        },
        organizer: %{name: nil, handle: nil, url: nil}
      }
    end
  end

  defp normalize_gancio_event(_event, _index), do: nil

  defp safe_funkwhale_track?(track) when is_map(track) do
    is_integer(track["id"]) and track["id"] > 0 and track["is_playable"] == true and
      is_binary(track["title"])
  end

  defp safe_funkwhale_track?(_track), do: false

  defp safe_flohmarkt_item?(item) when is_map(item) do
    is_binary(item["id"]) and byte_size(item["id"]) in 1..255 and
      is_binary(item["name"]) and String.trim(item["name"]) != "" and
      is_binary(item["url"]) and String.starts_with?(item["url"], "/~") and
      not String.contains?(item["url"], ["\\", "?", "#"])
  end

  defp safe_flohmarkt_item?(_item), do: false

  defp normalize_flohmarkt_item(item, index) when is_map(item) do
    identifier = text(item["id"], 255)
    title = text(item["name"], 300)
    url = absolute_provider_url(index, item["url"])
    host = URI.parse(index).host

    if identifier && title && valid_https_url?(url) && host do
      %{
        id: "flohmarkt:" <> host <> ":" <> identifier,
        family: "market",
        kind: "classified",
        title: title,
        summary: text(item["description"], 1_000),
        url: url,
        price: text(item["price"], 100),
        currency: text(item["currency"], 100),
        tags: flohmarkt_tags(item["tags"]),
        source_host: host
      }
    end
  end

  defp normalize_flohmarkt_item(_item, _index), do: nil

  defp flohmarkt_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&text(&1, 100))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp flohmarkt_tags(_tags), do: []

  defp normalize_funkwhale_track(track, index) when is_map(track) do
    identifier = track["id"]
    title = text(track["title"], 300)
    host = URI.parse(index).host
    artist = if is_map(track["artist"]), do: track["artist"], else: %{}
    album = if is_map(track["album"]), do: track["album"], else: %{}
    actor = if is_map(track["attributed_to"]), do: track["attributed_to"], else: %{}

    if (is_integer(identifier) and title) && host do
      %{
        id: "funkwhale:" <> host <> ":" <> Integer.to_string(identifier),
        family: "audio",
        kind: "track",
        title: title,
        summary: nil,
        url: absolute_provider_url(index, "/library/tracks/" <> Integer.to_string(identifier)),
        image_url:
          (track["cover"] || album["cover"])
          |> funkwhale_cover_url()
          |> Pleroma.Web.MediaProxy.browser_url(),
        published_at: text(track["creation_date"], 80),
        duration: non_negative_integer(first_upload_value(track["uploads"], "duration")),
        artist: text(artist["name"], 200),
        album: text(album["title"], 300),
        release_date: text(album["release_date"], 20),
        licence: funkwhale_label(track["license"]),
        tags: gancio_tags(track["tags"]),
        source_host: host,
        account: %{
          name: first_text([actor["name"], actor["preferred_username"]], 200),
          handle: text(actor["full_username"], 300),
          url: safe_url(actor["url"])
        }
      }
    end
  end

  defp normalize_funkwhale_track(_track, _index), do: nil

  defp safe_neodb_item?(item, category) when is_map(item) do
    is_binary(item["uuid"]) and is_binary(item["display_title"] || item["title"]) and
      item["category"] == category and is_binary(item["url"])
  end

  defp safe_neodb_item?(_item, _category), do: false

  defp normalize_neodb_item(item, index, category) when is_map(item) do
    identifier = text(item["uuid"], 100)
    title = text(item["display_title"] || item["title"], 300)
    url = absolute_provider_url(index, item["url"])

    if identifier && title && url do
      %{
        id: "neodb:" <> URI.parse(index).host <> ":" <> identifier,
        family: "catalog",
        kind: text(item["type"], 100),
        category: category,
        title: title,
        summary: item["brief"] || item["description"] |> plain_text() |> text(1_000),
        url: url,
        image_url: item["cover_image_url"] |> safe_url() |> Pleroma.Web.MediaProxy.browser_url(),
        rating: optional_non_negative_number(item["rating"]),
        rating_count: non_negative_integer(item["rating_count"]),
        tags: gancio_tags(item["tags"]),
        credits: neodb_credits(item["credits"]),
        year: neodb_year(item),
        languages: gancio_tags(item["language"]),
        local_action: "resolve",
        source_host: URI.parse(index).host
      }
    end
  end

  defp normalize_neodb_item(_item, _index, _category), do: nil

  defp normalize_bookwyrm_item(item, index) do
    book_path =
      item
      |> Floki.find("a[href^='/book/']")
      |> List.first()
      |> floki_attribute("href")

    title =
      item
      |> Floki.find("a[href^='/book/']")
      |> List.first()
      |> floki_text()
      |> text(300)

    author_names =
      item
      |> Floki.find("a.author")
      |> Enum.map(&(Floki.text(&1) |> text(200)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(4)

    url = absolute_provider_url(index, book_path)

    if book_path && title && url do
      %{
        id: "bookwyrm:" <> URI.parse(index).host <> ":" <> book_path,
        family: "catalog",
        kind: "Book",
        category: "book",
        title: title,
        summary: nil,
        url: url,
        image_url:
          index
          |> bookwyrm_cover_url(item)
          |> Pleroma.Web.MediaProxy.browser_url(),
        rating: nil,
        rating_count: 0,
        tags: [],
        credits: Enum.map(author_names, &%{role: "author", name: &1}),
        year: bookwyrm_year(item),
        languages: [],
        local_action: "source_only",
        source_host: URI.parse(index).host
      }
    end
  end

  defp event_actor(event) do
    cond do
      is_map(event["attributedTo"]) -> event["attributedTo"]
      is_map(event["organizerActor"]) -> event["organizerActor"]
      true -> %{}
    end
  end

  defp actor_handle(%{"preferredUsername" => username, "domain" => domain})
       when is_binary(username) and is_binary(domain),
       do: "@#{username}@#{domain}"

  defp actor_handle(%{"preferredUsername" => username, "url" => url})
       when is_binary(username) and is_binary(url) do
    case URI.parse(url).host do
      host when is_binary(host) -> "@#{username}@#{host}"
      _ -> nil
    end
  end

  defp actor_handle(_actor), do: nil

  defp peertube_video_host(video) do
    channel = if is_map(video["channel"]), do: video["channel"], else: %{}
    account = if is_map(video["account"]), do: video["account"], else: %{}

    channel["host"] || account["host"] || URI.parse(to_string(video["url"] || "")).host
  end

  defp channel_handle(%{"name" => name, "host" => host})
       when is_binary(name) and is_binary(host),
       do: "@#{name}@#{host}"

  defp channel_handle(_channel), do: nil

  defp merge_results(results, limit, offset, params) do
    results = materialize_results(results)

    all_items =
      results
      |> Enum.flat_map(&(discovery_value(&1, :items) |> List.wrap()))
      |> Enum.uniq_by(&(discovery_value(&1, :id) || :erlang.phash2(&1)))
      |> sort_discovery_items()
      |> prefer_discovery_language(params)
      |> diversify_discovery_participants()

    items =
      all_items
      |> Enum.take(limit)

    has_more = Enum.any?(results, &(discovery_value(&1, :has_more) == true))

    %{
      items: items,
      total:
        Enum.reduce(results, 0, fn result, total ->
          total +
            (discovery_value(result, :total) || length(List.wrap(discovery_value(result, :items))))
        end),
      has_more: has_more,
      next_offset: if(has_more, do: offset + limit, else: nil),
      distinct_participants:
        all_items
        |> Enum.map(&discovery_participant_key/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
        |> MapSet.size(),
      languages:
        all_items
        |> Enum.map(&discovery_language/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.take(12),
      providers:
        results
        |> Enum.flat_map(fn result ->
          List.wrap(discovery_value(result, :provider)) ++
            List.wrap(discovery_value(result, :providers))
        end)
        |> Enum.reject(&is_nil/1),
      communities:
        results
        |> Enum.flat_map(&(discovery_value(&1, :communities) |> List.wrap()))
        |> Enum.uniq_by(&(discovery_value(&1, :id) || :erlang.phash2(&1)))
    }
  end

  # Provider and local-cache searches are independent. Materialize them
  # concurrently so one slow directory does not make every other source wait,
  # then retain the original result order for deterministic merging.
  defp materialize_results([]), do: []

  defp materialize_results(results) do
    results
    |> Task.async_stream(&materialize_result/1,
      ordered: true,
      max_concurrency: min(length(results), @max_provider_concurrency),
      timeout: @provider_search_timeout,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, result} when not is_nil(result) -> [result]
      {:ok, nil} -> []
      {:exit, _reason} -> []
    end)
  end

  defp materialize_result(result) when is_function(result, 0), do: result.()
  defp materialize_result(result), do: result

  defp sort_discovery_items(items) do
    {events, other_items} =
      Enum.split_with(items, &(discovery_value(&1, :family) == "event"))

    Enum.sort_by(events, &(discovery_value(&1, :begins_at) || "")) ++
      Enum.sort_by(
        other_items,
        &(discovery_value(&1, :published_at) || discovery_value(&1, :updated_at) || ""),
        :desc
      )
  end

  defp prefer_discovery_language(items, params) do
    case preferred_discovery_language(params) do
      nil -> items
      preferred -> Enum.sort_by(items, &language_rank(&1, preferred))
    end
  end

  defp preferred_discovery_language(params) do
    case discovery_value(params, :language) || discovery_value(params, :lang) do
      language when is_binary(language) and byte_size(language) <= 32 ->
        language |> String.trim() |> String.downcase() |> String.split("-") |> List.first()

      _language ->
        nil
    end
  end

  defp language_rank(item, preferred) do
    case discovery_language(item) do
      ^preferred -> 0
      nil -> 1
      _language -> 2
    end
  end

  defp discovery_language(item) do
    value =
      discovery_value(item, :language) ||
        discovery_value(item, :resource_language) ||
        discovery_value(item, :book) |> discovery_value(:languages) |> List.wrap() |> List.first()

    case value do
      language when is_binary(language) and byte_size(language) <= 32 ->
        language |> String.trim() |> String.downcase() |> String.split("-") |> List.first()

      _language ->
        nil
    end
  end

  # Keep one prolific actor, channel, or host from filling an entire page.
  # Occurrence rounds retain the existing chronological relevance within each
  # participant while presenting distinct participants before repeats.
  defp diversify_discovery_participants(items) do
    {ranked, _counts} =
      items
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {item, index}, counts ->
        key = discovery_participant_key(item) || {:item, index}
        occurrence = Map.get(counts, key, 0)
        {{occurrence, index, item}, Map.put(counts, key, occurrence + 1)}
      end)

    ranked
    |> Enum.sort_by(fn {occurrence, index, _item} -> {occurrence, index} end)
    |> Enum.map(fn {_occurrence, _index, item} -> item end)
  end

  defp discovery_participant_key(item) do
    account = discovery_value(item, :account)
    channel = discovery_value(item, :channel)

    direct =
      discovery_value(item, :actor_url) ||
        discovery_value(item, :author_url) ||
        discovery_value(item, :attributed_to) ||
        discovery_value(account, :id) ||
        discovery_value(account, :url) ||
        discovery_value(channel, :id) ||
        discovery_value(channel, :url)

    cond do
      is_binary(direct) and direct != "" -> {:participant, direct}
      host = discovery_source_host(item) -> {:host, host}
      true -> nil
    end
  end

  defp discovery_source_host(item) do
    case discovery_value(item, :source_host) || discovery_value(item, :host) do
      host when is_binary(host) and host != "" -> String.downcase(host)
      _host -> discovery_item_url_host(item)
    end
  end

  defp discovery_item_url_host(item) do
    url =
      discovery_value(item, :activitypub_url) ||
        discovery_value(item, :canonical_url) ||
        discovery_value(item, :url) ||
        discovery_value(item, :id)

    case url do
      value when is_binary(value) -> URI.parse(value).host
      _value -> nil
    end
  end

  defp discovery_value(item, key) when is_map(item) do
    Map.get(item, key) || Map.get(item, Atom.to_string(key))
  end

  defp discovery_value(_item, _key), do: nil

  defp provider_metadata(index, status, peer_count, type \\ "peertube") do
    %{
      type: type,
      host: URI.parse(index).host,
      status: status,
      accepted_peer_count: peer_count
    }
  end

  defp peertube_indexes do
    Config.get([:native_discovery, :peertube_indexes], [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&valid_index_url?/1)
    |> Enum.uniq()
    |> Enum.take(3)
  end

  defp mobilizon_indexes do
    Config.get([:native_discovery, :mobilizon_indexes], [])
    |> configured_indexes()
  end

  defp gancio_indexes do
    Config.get([:native_discovery, :gancio_indexes], [])
    |> configured_indexes()
  end

  defp funkwhale_indexes do
    Config.get([:native_discovery, :funkwhale_indexes], [])
    |> configured_indexes()
  end

  defp neodb_indexes do
    Config.get([:native_discovery, :neodb_indexes], [])
    |> configured_indexes()
  end

  defp bookwyrm_indexes do
    Config.get([:native_discovery, :bookwyrm_indexes], [])
    |> configured_indexes()
  end

  defp flohmarkt_indexes do
    Config.get([:native_discovery, :flohmarkt_indexes], [])
    |> configured_indexes()
  end

  defp configured_indexes(indexes) do
    indexes
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&valid_index_url?/1)
    |> Enum.uniq()
    |> Enum.take(3)
  end

  # Most ecosystem APIs build a known endpoint under a configured server root.
  # Owncast's official directory is different: operators configure the complete
  # public playlist URL, including its required path. Keep that exception
  # narrow so a directory entry cannot carry credentials, a query, or a
  # fragment into the server-side request.
  defp configured_directory_indexes(indexes) do
    indexes
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&valid_directory_url?/1)
    |> Enum.uniq()
    |> Enum.take(3)
  end

  defp valid_index_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and path in [nil, "", "/"] ->
        true

      _ ->
        false
    end
  end

  defp valid_directory_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and is_binary(path) and byte_size(path) <= 1_024 ->
        path in ["", "/"] or String.starts_with?(path, "/")

      _ ->
        false
    end
  end

  defp valid_https_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) -> true
      _ -> false
    end
  end

  defp safe_url(url) when is_binary(url) do
    if valid_https_url?(url), do: text(url, 2_000)
  end

  defp safe_url(_url), do: nil

  defp endpoint(index, path, params) do
    query = URI.encode_query(params)
    index |> URI.parse() |> URI.merge(path <> "?" <> query) |> to_string()
  end

  defp get_json(url) do
    headers = [{"accept", "application/json"}]

    case HTTP.get(url, headers, pool: :default, recv_timeout: @http_timeout) do
      {:ok, %{status: 200, body: body}}
      when is_binary(body) and byte_size(body) <= @max_body_bytes ->
        Jason.decode(body)

      _ ->
        {:error, :provider_unavailable}
    end
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    _, _ -> {:error, :provider_unavailable}
  end

  defp get_html(url) do
    headers = [{"accept", "text/html,application/xhtml+xml"}]

    with {:ok, %{status: 200, body: body}}
         when is_binary(body) and byte_size(body) <= @max_body_bytes <-
           HTTP.get(url, headers, pool: :default, recv_timeout: @http_timeout) do
      Floki.parse_document(body)
    else
      _ -> {:error, :provider_unavailable}
    end
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    _, _ -> {:error, :provider_unavailable}
  end

  defp get_text(url) do
    headers = [{"accept", "application/x-mpegurl,application/vnd.apple.mpegurl,text/plain"}]

    case HTTP.get(url, headers, pool: :default, recv_timeout: @http_timeout) do
      {:ok, %{status: 200, body: body}}
      when is_binary(body) and byte_size(body) <= @max_body_bytes ->
        {:ok, body}

      _ ->
        {:error, :provider_unavailable}
    end
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    _, _ -> {:error, :provider_unavailable}
  end

  defp post_json(url, body) do
    headers = [{"accept", "application/json"}, {"content-type", "application/json"}]

    case HTTP.post(url, body, headers, pool: :default, recv_timeout: @http_timeout) do
      {:ok, %{status: 200, body: response_body}}
      when is_binary(response_body) and byte_size(response_body) <= @max_body_bytes ->
        Jason.decode(response_body)

      _ ->
        {:error, :provider_unavailable}
    end
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    _, _ -> {:error, :provider_unavailable}
  end

  defp absolute_provider_url(_index, nil), do: nil

  defp absolute_provider_url(index, path) when is_binary(path) do
    url = index |> URI.parse() |> URI.merge(path) |> to_string()
    if valid_https_url?(url), do: url
  rescue
    _ -> nil
  end

  defp absolute_provider_url(_index, _path), do: nil

  defp normalized_family(params) do
    case params["family"] do
      family
      when family in [
             "all",
             "audio",
             "bookmarks",
             "catalog",
             "event",
             "game",
             "development",
             "livestream",
             "longform",
             "coordination",
             "market",
             "model",
             "photo",
             "publishing",
             "route",
             "video"
           ] ->
        family

      "books" ->
        "catalog"

      "culture" ->
        "catalog"

      "events" ->
        "event"

      "games" ->
        "game"

      "marketplace" ->
        "market"

      "models" ->
        "model"

      "photos" ->
        "photo"

      "routes" ->
        "route"

      nil ->
        "all"

      "" ->
        "all"

      _ ->
        "unknown"
    end
  end

  defp normalized_catalog_category(params) do
    case {params["category"], params["family"]} do
      {category, _family}
      when category in ["book", "game", "movie", "music", "podcast", "tv"] ->
        category

      {_category, "culture"} ->
        "movie"

      _ ->
        "book"
    end
  end

  defp normalized_discovery_mode(params) do
    if params["mode"] == "communities", do: "communities", else: "search"
  end

  defp normalized_query(params) do
    params
    |> Map.get("q", "")
    |> to_string()
    |> String.trim()
    |> String.slice(0, @max_query_length)
  end

  defp maybe_put_search(params, ""), do: params
  defp maybe_put_search(params, query), do: Map.put(params, "search", query)

  defp maybe_put_funkwhale_search(params, ""), do: params
  defp maybe_put_funkwhale_search(params, query), do: Map.put(params, "q", query)

  defp bounded_integer(value, default, minimum, maximum) do
    parsed =
      case value do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {integer, ""} -> integer
            _ -> default
          end

        _ ->
          default
      end

    parsed |> max(minimum) |> min(maximum)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp optional_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp optional_non_negative_integer(_value), do: nil

  defp optional_non_negative_number(value) when is_number(value) and value >= 0, do: value
  defp optional_non_negative_number(_value), do: nil

  defp nested_label(%{"label" => label}), do: text(label, 100)
  defp nested_label(_value), do: nil

  defp nested_url(%{"url" => url}), do: safe_url(url)
  defp nested_url(_value), do: nil

  defp future_datetime?(value) when is_binary(value) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      DateTime.compare(datetime, DateTime.add(DateTime.utc_now(), -3_600, :second)) in [:gt, :eq]
    else
      _ -> false
    end
  end

  defp future_datetime?(_value), do: false

  defp future_unix?(value) when is_integer(value) do
    value >= DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_unix()
  end

  defp future_unix?(_value), do: false

  defp unix_to_iso8601(value) when is_integer(value) do
    value
    |> DateTime.from_unix()
    |> case do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp unix_to_iso8601(_value), do: nil

  defp gancio_image_url(index, [first | _]) when is_map(first) do
    case text(first["url"], 500) do
      nil -> nil
      filename -> absolute_provider_url(index, "/media/" <> URI.encode(filename))
    end
  end

  defp gancio_image_url(_index, _media), do: nil

  defp gancio_online?(value) when is_list(value), do: value != []
  defp gancio_online?(value) when is_binary(value), do: String.trim(value) != ""
  defp gancio_online?(_value), do: false

  defp gancio_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&text(&1, 80))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp gancio_tags(_tags), do: []

  defp funkwhale_cover_url(%{"urls" => urls}) when is_map(urls) do
    safe_url(urls["medium_square_crop"] || urls["original"])
  end

  defp funkwhale_cover_url(_cover), do: nil

  defp funkwhale_label(value) when is_binary(value), do: text(value, 200)

  defp funkwhale_label(value) when is_map(value) do
    first_text([value["full_name"], value["name"], value["code"]], 200)
  end

  defp funkwhale_label(_value), do: nil

  defp first_upload_value([upload | _], key) when is_map(upload), do: upload[key]
  defp first_upload_value(_uploads, _key), do: nil

  defp neodb_credits(credits) when is_list(credits) do
    credits
    |> Enum.reduce([], fn credit, result ->
      role = if is_map(credit), do: text(credit["role"], 80)
      name = if is_map(credit), do: text(credit["name"], 200)

      if role && name, do: [%{role: role, name: name} | result], else: result
    end)
    |> Enum.reverse()
    |> Enum.take(4)
  end

  defp neodb_credits(_credits), do: []

  defp neodb_year(item) when is_map(item) do
    case item["pub_year"] || item["year"] || item["release_date"] do
      year when is_integer(year) and year >= 0 -> Integer.to_string(year)
      year when is_binary(year) -> text(year, 20)
      _ -> nil
    end
  end

  defp bookwyrm_cover_url(index, item) do
    path =
      item
      |> Floki.find("img.book-cover")
      |> List.first()
      |> floki_attribute("src")

    if is_binary(path) and not String.ends_with?(path, "/no_cover.jpg") do
      absolute_provider_url(index, path)
    end
  end

  defp bookwyrm_year(item) do
    case Regex.run(~r/\b(?:1[0-9]{3}|20[0-9]{2})\b/u, Floki.text(item)) do
      [year] -> year
      _ -> nil
    end
  end

  defp floki_attribute(nil, _attribute), do: nil

  defp floki_attribute(node, attribute) do
    node
    |> Floki.attribute(attribute)
    |> List.first()
  end

  defp floki_text(nil), do: nil
  defp floki_text(node), do: Floki.text(node)

  defp plain_text(value) when is_binary(value) do
    value
    |> String.replace(~r/<[^>]*>/u, " ")
    |> String.replace(~r/\s+/u, " ")
  end

  defp plain_text(_value), do: nil

  defp first_text(values, maximum) do
    Enum.find_value(values, &text(&1, maximum))
  end

  defp text(value, maximum) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, maximum)
    |> case do
      "" -> nil
      result -> result
    end
  end

  defp text(_value, _maximum), do: nil

  defp empty_result do
    %{items: [], total: 0, has_more: false, next_offset: nil, providers: [], communities: []}
  end
end

# end of native_discovery.ex
