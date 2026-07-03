# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RichMediaWorker do
  alias Pleroma.Web.RichMedia.Backfill
  alias Pleroma.Web.RichMedia.Card

  use Oban.Worker, queue: :background, max_attempts: 3, unique: [period: 300]

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "expire", "url" => url} = _args}) when is_binary(url) do
    Card.delete(url)
  end

  def perform(%Job{args: %{"op" => "backfill", "url" => url} = args}) when is_binary(url) do
    args
    |> Backfill.run()
    |> handle_backfill_result()
  end

  def perform(%Job{}), do: :discard

  defp handle_backfill_result({:error, reason}) when reason in [:body_too_large, :content_type] do
    {:cancel, reason}
  end

  defp handle_backfill_result(result), do: result
end
