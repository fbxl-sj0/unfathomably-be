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
      from(u in User,
        where: u.is_active == true,
        where: u.local == true,
        where: not is_nil(u.nickname),
        where: not u.invisible
      )

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
