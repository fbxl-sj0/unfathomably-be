# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.CachexProxy do
  @behaviour Pleroma.Caching

  @impl true
  defdelegate get!(cache, key), to: Cachex

  @impl true
  defdelegate stream!(cache, key), to: Cachex

  @impl true
  defdelegate put(cache, key, value, options), to: Cachex

  @impl true
  defdelegate put(cache, key, value), to: Cachex

  @impl true
  defdelegate get_and_update(cache, key, func), to: Cachex

  @impl true
  defdelegate get(cache, key), to: Cachex

  @impl true
  def fetch(cache, key, func) do
    result =
      if Pleroma.Config.get(:env) == :test do
        fetch_in_caller(cache, key, func)
      else
        Cachex.fetch(cache, key, func)
      end

    case result do
      {:commit, value, _options} -> {:commit, value}
      result -> result
    end
  end

  @impl true
  def fetch!(cache, key, func) do
    case fetch(cache, key, func) do
      {status, value} when status in [:ok, :commit, :ignore] ->
        value

      {:error, reason} ->
        raise Cachex.Error, message: "Cache fetch failed: #{inspect(reason)}"
    end
  end

  @impl true
  defdelegate expire(cache, key, expiration), to: Cachex

  @impl true
  defdelegate expire_at(cache, str, num), to: Cachex

  @impl true
  defdelegate exists?(cache, key), to: Cachex

  @impl true
  defdelegate del(cache, key), to: Cachex

  @impl true
  defdelegate execute!(cache, func), to: Cachex

  # Cachex runs a miss fallback in its Courier process to collapse concurrent
  # work. Ecto's SQL sandbox intentionally grants database ownership only to
  # the test process, so a database-backed fallback cannot run in that Courier.
  # Production retains Courier deduplication; tests execute the same fallback
  # and cache writes in the sandbox owner process.
  defp fetch_in_caller(cache, key, func) do
    case Cachex.get(cache, key) do
      {:ok, nil} -> run_fallback_in_caller(cache, key, func)
      {:ok, value} -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp run_fallback_in_caller(cache, key, func) do
    result = if is_function(func, 1), do: func.(key), else: func.()

    case result do
      {:commit, value, options} ->
        with {:ok, true} <- Cachex.put(cache, key, value, options), do: {:commit, value}

      {:commit, value} ->
        with {:ok, true} <- Cachex.put(cache, key, value), do: {:commit, value}

      {:ignore, value} ->
        {:ignore, value}

      value ->
        with {:ok, true} <- Cachex.put(cache, key, value), do: {:commit, value}
    end
  end
end
