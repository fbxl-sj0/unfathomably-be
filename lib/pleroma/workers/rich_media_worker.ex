# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RichMediaWorker do
  alias Pleroma.Config
  alias Pleroma.Web.RichMedia.Backfill
  alias Pleroma.Web.RichMedia.Card

  use Oban.Worker, queue: :background, max_attempts: 3, unique: [period: :infinity]

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "expire", "url" => url} = _args}) when is_binary(url) do
    Card.delete(url)
  end

  def perform(%Job{args: %{"op" => "backfill", "url" => url} = args}) when is_binary(url) do
    case Backfill.run(args) do
      :ok ->
        :ok

      {:error, type}
      when type in [:invalid_metadata, :body_too_large, :content_type, :validate, :get, :head] ->
        {:cancel, type}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  @impl Oban.Worker
  def timeout(_job) do
    Config.get([:rich_media, :timeout], 5_000) + :timer.seconds(2)
  end
end
