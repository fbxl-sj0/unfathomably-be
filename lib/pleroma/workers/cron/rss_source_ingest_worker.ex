# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.RssSourceIngestWorker do
  @moduledoc """
  Polls followed RSS and Atom sources so new entries appear in normal timelines.

  RSS feeds do not send ActivityPub deliveries to the instance. The source UI can
  fetch a feed on demand, but the home timeline only sees activities already in
  the local cache. This worker bridges that gap by polling followed feeds at a
  modest cadence and letting `FederatedTarget` materialize recent entries as
  remote Article activities addressed to the feed's follower collection.
  """

  use Oban.Worker, queue: "background", max_attempts: 1

  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.FederatedTarget

  require Logger

  @default_item_limit 20
  @default_source_limit 200

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    if enabled?() do
      source_id
      |> source_by_id()
      |> ingest_source()
      |> result_for_one()
    else
      {:ok, %{sources: 0, items: 0}}
    end
  end

  def perform(%Oban.Job{}) do
    if enabled?() do
      sources = FederatedTarget.followed_rss_sources(source_limit())

      items =
        sources
        |> Enum.map(&ingest_source/1)
        |> Enum.sum()

      {:ok, %{sources: length(sources), items: items}}
    else
      {:ok, %{sources: 0, items: 0}}
    end
  end

  def schedule_source(%User{} = source) do
    if FederatedTarget.rss_source?(source) do
      %{"source_id" => to_string(source.id)}
      |> new()
      |> Oban.insert()
    else
      {:ok, :ignored}
    end
  end

  def schedule_source(_), do: {:ok, :ignored}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(3)

  defp ingest_source(%User{} = source) do
    case FederatedTarget.source_items_result(source, %{"limit" => item_limit()}, nil) do
      {:ok, %{items: items}} when is_list(items) ->
        length(items)

      {:error, reason} ->
        Logger.debug("RSS source ingest skipped #{inspect(source.ap_id)}: #{inspect(reason)}")
        0
    end
  rescue
    error ->
      Logger.warning("RSS source ingest failed for #{inspect(source.ap_id)}: #{inspect(error)}")
      0
  catch
    :exit, reason ->
      Logger.warning("RSS source ingest exited for #{inspect(source.ap_id)}: #{inspect(reason)}")

      0
  end

  defp ingest_source(_), do: 0

  defp result_for_one(0), do: {:ok, %{sources: 0, items: 0}}
  defp result_for_one(items), do: {:ok, %{sources: 1, items: items}}

  defp source_by_id(id) when is_binary(id) do
    User.get_cached_by_id(id) || source_by_display_id(id)
  rescue
    _ -> source_by_display_id(id)
  catch
    _, _ -> source_by_display_id(id)
  end

  defp source_by_id(id) when is_integer(id) do
    Repo.get(User, id) || source_by_display_id(id)
  rescue
    _ -> source_by_display_id(id)
  catch
    _, _ -> source_by_display_id(id)
  end

  defp source_by_id(_), do: nil

  defp source_by_display_id(id) do
    User
    |> where([user], fragment("?::text = ?", user.id, ^to_string(id)))
    |> Repo.one()
  end

  defp enabled? do
    config_boolean(:enabled, true)
  end

  defp item_limit do
    config_integer(:item_limit, @default_item_limit)
    |> max(1)
    |> min(40)
  end

  defp source_limit do
    config_integer(:source_limit, @default_source_limit)
    |> max(1)
    |> min(1_000)
  end

  defp config_integer(key, default) do
    case Config.get([__MODULE__, key], default) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp config_boolean(key, default) do
    case Config.get([__MODULE__, key], default) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(value) in ~w(true 1 yes on)
      _ -> default
    end
  end
end
