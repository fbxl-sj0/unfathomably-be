# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Instances.Cache do
  @moduledoc """
  Keeps the small host reachability set in memory.

  The database remains the source of truth. This process maintains a read
  snapshot for hot checks that only need to know whether a host is currently
  considered unreachable or dormant.
  """

  use GenServer

  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.Instances
  alias Pleroma.Instances.Instance
  alias Pleroma.Repo

  @state_key {__MODULE__, :state}
  @default_refresh_interval :timer.minutes(5)
  @empty_state %{
    loaded?: false,
    refreshed_at: nil,
    unreachable_since_by_host: %{}
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, @empty_state, {:continue, :refresh}}
  end

  def filter_reachable([]), do: {:ok, %{}}

  def filter_reachable(urls_or_hosts) when is_list(urls_or_hosts) do
    case state() do
      %{loaded?: true, unreachable_since_by_host: unreachable_since_by_host} ->
        threshold = Instances.reachability_datetime_threshold()

        result =
          urls_or_hosts
          |> Enum.filter(&is_binary/1)
          |> Enum.reduce(%{}, fn entry, acc ->
            host = normalize_host(entry)
            unreachable_since = Map.get(unreachable_since_by_host, host)

            if host && reachable_since?(unreachable_since, threshold) do
              Map.put(acc, entry, unreachable_since)
            else
              acc
            end
          end)

        {:ok, result}

      _ ->
        :error
    end
  end

  def reachable?(url_or_host) when is_binary(url_or_host) do
    with %{loaded?: true, unreachable_since_by_host: unreachable_since_by_host} <- state(),
         host when is_binary(host) <- normalize_host(url_or_host) do
      unreachable_since = Map.get(unreachable_since_by_host, host)
      {:ok, reachable_since?(unreachable_since, Instances.reachability_datetime_threshold())}
    else
      _ -> :error
    end
  end

  def reachable?(_), do: :error

  def dormant?(url_or_host) when is_binary(url_or_host) do
    with %{loaded?: true, unreachable_since_by_host: unreachable_since_by_host} <- state(),
         host when is_binary(host) <- normalize_host(url_or_host) do
      unreachable_since = Map.get(unreachable_since_by_host, host)
      {:ok, dormant_since?(unreachable_since, Instances.dormant_datetime_threshold())}
    else
      _ -> :error
    end
  end

  def dormant?(_), do: :error

  def any_dormant? do
    case state() do
      %{loaded?: true, unreachable_since_by_host: unreachable_since_by_host} ->
        threshold = Instances.dormant_datetime_threshold()

        any_dormant? =
          Enum.any?(unreachable_since_by_host, fn {_host, since} ->
            dormant_since?(since, threshold)
          end)

        {:ok, any_dormant?}

      _ ->
        :error
    end
  end

  def sync(%Instance{} = instance), do: sync(instance.host, instance.unreachable_since)
  def sync(_), do: :ok

  def sync(host, unreachable_since) when is_binary(host) do
    update_loaded_state(fn state ->
      unreachable_since_by_host =
        case unreachable_since do
          nil ->
            Map.delete(state.unreachable_since_by_host, normalize_host(host))

          %NaiveDateTime{} = unreachable_since ->
            Map.put(state.unreachable_since_by_host, normalize_host(host), unreachable_since)

          _ ->
            state.unreachable_since_by_host
        end

      %{state | unreachable_since_by_host: unreachable_since_by_host}
    end)
  end

  def sync(_, _), do: :ok

  @impl true
  def handle_continue(:refresh, state) do
    state = refresh_state(state)
    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = refresh_state(state)
    schedule_refresh()
    {:noreply, state}
  end

  defp refresh_state(_state) do
    unreachable_since_by_host =
      Instance
      |> where([i], not is_nil(i.unreachable_since))
      |> select([i], {i.host, i.unreachable_since})
      |> Repo.all()
      |> Map.new(fn {host, unreachable_since} ->
        {normalize_host(host), unreachable_since}
      end)

    state = %{
      loaded?: true,
      refreshed_at: DateTime.utc_now(),
      unreachable_since_by_host: unreachable_since_by_host
    }

    put_state(state)
    state
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, refresh_interval())
  end

  defp update_loaded_state(fun) when is_function(fun, 1) do
    case state() do
      %{loaded?: true} = state ->
        state
        |> fun.()
        |> put_state()

      _ ->
        :ok
    end
  end

  defp state do
    :persistent_term.get(@state_key, @empty_state)
  end

  defp put_state(state) do
    :persistent_term.put(@state_key, state)
  end

  defp refresh_interval do
    [:instances, :cache_refresh_interval]
    |> Config.get(@default_refresh_interval)
    |> normalize_refresh_interval()
  end

  defp normalize_refresh_interval(interval) when is_integer(interval) and interval > 0,
    do: interval

  defp normalize_refresh_interval(_), do: @default_refresh_interval

  defp reachable_since?(nil, _threshold), do: true

  defp reachable_since?(unreachable_since, threshold) do
    NaiveDateTime.compare(unreachable_since, threshold) == :gt
  end

  defp dormant_since?(nil, _threshold), do: false

  defp dormant_since?(unreachable_since, threshold) do
    NaiveDateTime.compare(unreachable_since, threshold) != :gt
  end

  defp normalize_host(nil), do: nil

  defp normalize_host(url_or_host) when is_binary(url_or_host) do
    url_or_host
    |> Instances.host()
    |> case do
      host when is_binary(host) ->
        host
        |> String.trim()
        |> String.downcase()
        |> case do
          "" -> nil
          host -> host
        end

      _ ->
        nil
    end
  end

  defp normalize_host(_), do: nil
end
