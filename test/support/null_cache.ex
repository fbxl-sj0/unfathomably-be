# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.NullCache do
  @moduledoc """
  A module simulating a permanently empty cache.
  """
  @behaviour Pleroma.Caching

  @impl true
  def get!(_, _), do: nil

  @impl true
  def put(_, _, _, _ \\ nil), do: {:ok, true}

  @impl true
  def stream!(_, _), do: []

  @impl true
  def get(_, _), do: {:ok, nil}

  @impl true
  def fetch(_, key, func) do
    case run_fallback(func, key) do
      {:commit, value, _options} -> {:commit, value}
      {status, value} when status in [:commit, :ignore, :error] -> {status, value}
      value -> {:commit, value}
    end
  end

  @impl true
  def fetch!(_, key, func) do
    case fetch(nil, key, func) do
      {status, value} when status in [:ok, :commit, :ignore] ->
        value

      {:error, reason} ->
        raise Cachex.Error, message: "Cache fetch failed: #{inspect(reason)}"
    end
  end

  @impl true
  def get_and_update(_, _, func) do
    func.(nil)
  end

  @impl true
  def expire(_, _, _), do: {:ok, true}

  @impl true
  def expire_at(_, _, _), do: {:ok, true}

  @impl true
  def exists?(_, _), do: {:ok, false}

  @impl true
  def execute!(_, func) do
    func.(:nothing)
  end

  @impl true
  def del(_, _), do: {:ok, true}

  defp run_fallback(func, _key) when is_function(func, 0), do: func.()
  defp run_fallback(func, key) when is_function(func, 1), do: func.(key)
end
