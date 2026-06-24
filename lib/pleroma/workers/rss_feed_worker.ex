# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RSSFeedWorker do
  @moduledoc """
  Refreshes one followed RSS or Atom source.
  """

  use Oban.Worker,
    queue: "remote_fetcher",
    max_attempts: 3,
    unique: [period: 300, fields: [:worker, :args]]

  alias Oban.Job
  alias Pleroma.RSSFeed
  alias Pleroma.User

  def enqueue(%User{id: id}) do
    %{"source_id" => to_string(id)}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Job{args: %{"source_id" => source_id}}) do
    with %User{} = source <- User.get_cached_by_id(source_id),
         true <- RSSFeed.rss_source?(source),
         {:ok, _result} <- RSSFeed.import_source(source) do
      :ok
    else
      nil -> {:cancel, :not_found}
      false -> {:cancel, :not_rss_feed}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)
end
