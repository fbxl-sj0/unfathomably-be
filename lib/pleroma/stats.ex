# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Stats do
  use GenServer

  import Ecto.Query
  require Logger

  alias Pleroma.CounterCache
  alias Pleroma.Repo
  alias Pleroma.User

  @default_interval :timer.minutes(5)
  # PostgreSQL does not expose a general-purpose index skip scan. Walking to
  # the next greater host lets a federation-heavy instance visit each distinct
  # host once instead of scanning every remote user whenever stats refresh.
  @peer_hosts_query """
  WITH RECURSIVE peer_hosts(host) AS (
    (
      SELECT lower(split_part(nickname::text, '@', 2)) AS host
      FROM users
      WHERE local = false
        AND nickname IS NOT NULL
        AND lower(split_part(nickname::text, '@', 2)) <> ''
      ORDER BY lower(split_part(nickname::text, '@', 2))
      LIMIT 1
    )

    UNION ALL

    SELECT next_host.host
    FROM peer_hosts AS current_host
    CROSS JOIN LATERAL (
      SELECT lower(split_part(nickname::text, '@', 2)) AS host
      FROM users
      WHERE local = false
        AND nickname IS NOT NULL
        AND lower(split_part(nickname::text, '@', 2)) <> ''
        AND lower(split_part(nickname::text, '@', 2)) > current_host.host
      ORDER BY lower(split_part(nickname::text, '@', 2))
      LIMIT 1
    ) AS next_host
  )
  SELECT host
  FROM peer_hosts
  ORDER BY host
  """
  @weekly_activity_query """
  WITH bounds(first_week, last_week) AS (
    SELECT
      date_trunc('week', timezone('UTC', now())) - interval '11 weeks',
      date_trunc('week', timezone('UTC', now()))
  ),
  weeks(week) AS (
    SELECT generate_series(first_week, last_week, interval '1 week')
    FROM bounds
  ),
  status_totals AS (
    SELECT date_trunc('week', activity.inserted_at) AS week, count(*) AS statuses
    FROM activities AS activity
    JOIN users AS actor ON actor.ap_id = activity.data->>'actor'
    LEFT JOIN nostr_entities AS nostr_origin
      ON nostr_origin.user_id = actor.id
      AND nostr_origin.kind IN ('mirror_profile', 'mirror_group')
    CROSS JOIN bounds
    WHERE activity.local = true
      AND activity.data->>'type' = 'Create'
      AND activity.inserted_at >= bounds.first_week
      AND actor.local = true
      AND nostr_origin.id IS NULL
    GROUP BY 1
  ),
  registration_totals AS (
    SELECT date_trunc('week', account.inserted_at) AS week, count(*) AS registrations
    FROM users AS account
    LEFT JOIN nostr_entities AS nostr_origin
      ON nostr_origin.user_id = account.id
      AND nostr_origin.kind IN ('mirror_profile', 'mirror_group')
    CROSS JOIN bounds
    WHERE account.local = true
      AND account.actor_type = 'Person'
      AND account.nickname IS NOT NULL
      AND account.invisible = false
      AND account.inserted_at >= bounds.first_week
      AND nostr_origin.id IS NULL
    GROUP BY 1
  )
  SELECT
    extract(epoch FROM weeks.week AT TIME ZONE 'UTC')::bigint,
    coalesce(status_totals.statuses, 0)::bigint,
    coalesce(registration_totals.registrations, 0)::bigint
  FROM weeks
  LEFT JOIN status_totals USING (week)
  LEFT JOIN registration_totals USING (week)
  ORDER BY weeks.week DESC
  """
  @compatibility_site_stats_query """
  WITH local_creates AS (
    SELECT
      activity.inserted_at,
      activity.data->>'actor' AS actor,
      coalesce(
        nullif(object.data->>'inReplyTo', ''),
        nullif(activity.data #>> '{object,inReplyTo}', '')
      ) AS in_reply_to
    FROM activities AS activity
    JOIN users AS account ON account.ap_id = activity.data->>'actor'
    LEFT JOIN objects AS object
      ON object.data->>'id' = associated_object_id(activity.data)
    LEFT JOIN nostr_entities AS nostr_origin
      ON nostr_origin.user_id = account.id
      AND nostr_origin.kind IN ('mirror_profile', 'mirror_group')
    WHERE activity.local = true
      AND activity.data->>'type' = 'Create'
      AND account.local = true
      AND nostr_origin.id IS NULL
  ),
  local_accounts AS (
    SELECT account.inserted_at, account.actor_type, account.is_active, account.is_discoverable
    FROM users AS account
    LEFT JOIN nostr_entities AS nostr_origin
      ON nostr_origin.user_id = account.id
      AND nostr_origin.kind IN ('mirror_profile', 'mirror_group')
    WHERE account.local = true
      AND account.nickname IS NOT NULL
      AND account.invisible = false
      AND nostr_origin.id IS NULL
  )
  SELECT
    count(*) FILTER (WHERE in_reply_to IS NULL)::bigint,
    count(*) FILTER (WHERE in_reply_to IS NOT NULL)::bigint,
    (
      SELECT count(*)
      FROM local_accounts
      WHERE actor_type = 'Group'
        AND is_active = true
        AND is_discoverable = true
    )::bigint,
    count(DISTINCT actor) FILTER (WHERE inserted_at >= now() - interval '1 day')::bigint,
    count(DISTINCT actor) FILTER (WHERE inserted_at >= now() - interval '7 days')::bigint,
    count(DISTINCT actor) FILTER (WHERE inserted_at >= now() - interval '1 month')::bigint,
    count(DISTINCT actor) FILTER (WHERE inserted_at >= now() - interval '6 months')::bigint,
    (SELECT min(inserted_at) FROM local_accounts)
  FROM local_creates
  """
  @weekly_activity_cache_key {__MODULE__, :weekly_activity}
  @weekly_activity_cache_ttl :timer.minutes(15)
  @compatibility_site_stats_cache_key {__MODULE__, :compatibility_site_stats}
  @compatibility_site_stats_cache_ttl :timer.minutes(15)
  @state_key {__MODULE__, :state}
  @empty_state %{
    peers: [],
    stats: %{
      domain_count: 0,
      status_count: 0,
      user_count: 0
    }
  }

  def start_link(_) do
    GenServer.start_link(
      __MODULE__,
      nil,
      name: __MODULE__
    )
  end

  @impl true
  def init(_args) do
    if Pleroma.Config.get(:env) != :test do
      {:ok, nil, {:continue, :calculate_stats}}
    else
      stats = calculate_stat_data()
      cache_state(stats)
      {:ok, stats}
    end
  end

  @doc "Performs update stats"
  def force_update do
    GenServer.call(__MODULE__, :force_update)
  end

  @doc "Returns stats data"
  @spec get_stats() :: %{
          domain_count: non_neg_integer(),
          status_count: non_neg_integer(),
          user_count: non_neg_integer()
        }
  def get_stats do
    %{stats: stats} = cached_state()

    stats
  end

  @doc "Returns list peers"
  @spec get_peers() :: list(String.t())
  def get_peers do
    %{peers: peers} = cached_state()

    peers
  end

  @doc "Returns the twelve-week activity shape used by Mastodon-compatible clients."
  @spec get_weekly_activity() :: list(map())
  def get_weekly_activity do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@weekly_activity_cache_key, nil) do
      {expires_at, activity} when expires_at > now -> activity
      _expired_or_missing -> refresh_weekly_activity(now)
    end
  end

  defp refresh_weekly_activity(now) do
    case Repo.query(@weekly_activity_query) do
      {:ok, %{rows: rows}} ->
        activity =
          Enum.map(rows, fn [week, statuses, registrations] ->
            %{
              week: Integer.to_string(week),
              statuses: Integer.to_string(statuses),
              # Pleroma does not retain a weekly login history. Reporting zero is
              # preferable to presenting token creation or posting as a login.
              logins: "0",
              registrations: Integer.to_string(registrations)
            }
          end)

        :persistent_term.put(
          @weekly_activity_cache_key,
          {now + @weekly_activity_cache_ttl, activity}
        )

        activity

      {:error, error} ->
        Logger.warning("Could not calculate weekly instance activity: #{inspect(error)}")
        []
    end
  end

  @doc "Returns bounded local counts for read-only compatibility discovery."
  @spec get_compatibility_site_stats() :: map()
  def get_compatibility_site_stats do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@compatibility_site_stats_cache_key, nil) do
      {expires_at, site_stats} when expires_at > now -> site_stats
      _expired_or_missing -> refresh_compatibility_site_stats(now)
    end
  end

  defp refresh_compatibility_site_stats(now) do
    case Repo.query(@compatibility_site_stats_query) do
      {:ok,
       %{
         rows: [
           [posts, comments, communities, day, week, month, half_year, published_at]
         ]
       }} ->
        site_stats = %{
          posts: posts,
          comments: comments,
          communities: communities,
          users_active_day: day,
          users_active_week: week,
          users_active_month: month,
          users_active_half_year: half_year,
          published_at: published_at
        }

        :persistent_term.put(
          @compatibility_site_stats_cache_key,
          {now + @compatibility_site_stats_cache_ttl, site_stats}
        )

        site_stats

      {:error, error} ->
        Logger.warning("Could not calculate compatibility site stats: #{inspect(error)}")
        compatibility_site_stats_fallback()
    end
  end

  @spec calculate_stat_data() :: %{
          peers: list(),
          stats: %{
            domain_count: non_neg_integer(),
            status_count: non_neg_integer(),
            user_count: non_neg_integer()
          }
        }
  def calculate_stat_data do
    peers = remote_peer_hosts()

    domain_count = Enum.count(peers)

    status_count = Repo.aggregate(User.Query.build(%{local: true}), :sum, :note_count)

    users_query =
      %{account_local: true}
      |> User.Query.build()
      |> where([u], u.is_active == true)
      |> where([u], not is_nil(u.nickname))
      |> where([u], not u.invisible)

    user_count = Repo.aggregate(users_query, :count, :id)

    %{
      peers: peers,
      stats: %{
        domain_count: domain_count,
        status_count: status_count || 0,
        user_count: user_count
      }
    }
  end

  @spec get_status_visibility_count(String.t() | nil) :: map()
  def get_status_visibility_count(instance \\ nil) do
    if is_nil(instance) do
      CounterCache.get_sum()
    else
      CounterCache.get_by_instance(instance)
    end
  end

  @impl true
  def handle_continue(:calculate_stats, _) do
    stats = calculate_stat_data()
    cache_state(stats)
    warm_compatibility_caches()

    unless Pleroma.Config.get(:env) == :test do
      Process.send_after(self(), :run_update, refresh_interval())
    end

    {:noreply, stats}
  end

  @impl true
  def handle_call(:force_update, _from, _state) do
    new_stats = calculate_stat_data()
    cache_state(new_stats)
    {:reply, new_stats, new_stats}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:run_update, _) do
    new_stats = calculate_stat_data()
    cache_state(new_stats)
    Process.send_after(self(), :run_update, refresh_interval())
    {:noreply, new_stats}
  end

  defp cache_state(state) do
    :persistent_term.put(@state_key, state)
  end

  defp cached_state do
    :persistent_term.get(@state_key, @empty_state)
  end

  defp compatibility_site_stats_fallback do
    %{status_count: status_count} = get_stats()

    %{
      posts: status_count,
      comments: 0,
      communities: 0,
      users_active_day: 0,
      users_active_week: 0,
      users_active_month: 0,
      users_active_half_year: 0,
      published_at: nil
    }
  end

  # The endpoint process should never pay the first aggregate cost after a
  # normal boot. Cache warming remains detached so stats startup and request
  # serving do not wait on compatibility-only projections.
  defp warm_compatibility_caches do
    Task.start(fn ->
      get_weekly_activity()
      get_compatibility_site_stats()
    end)

    :ok
  end

  defp remote_peer_hosts do
    case Repo.query(@peer_hosts_query) do
      {:ok, %{rows: rows}} ->
        List.flatten(rows)

      {:error, error} ->
        Logger.warning("Could not refresh remote peer host stats: #{inspect(error)}")
        []
    end
  end

  defp refresh_interval do
    [:instance, :stats_refresh_interval]
    |> Pleroma.Config.get(@default_interval)
    |> normalize_refresh_interval()
  end

  defp normalize_refresh_interval(interval) when is_integer(interval) and interval > 0,
    do: interval

  defp normalize_refresh_interval(_), do: @default_interval
end
