# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.PostArchiveImportWorker do
  use Oban.Worker, queue: :backup, max_attempts: 1

  alias Oban.Job
  alias Pleroma.User.PostArchiveImport

  defguardp valid_job_id(id) when (is_binary(id) and byte_size(id) > 0) or is_integer(id)

  def process(%PostArchiveImport{} = import) do
    %{"op" => "process", "import_id" => import.id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "process", "import_id" => import_id}})
      when valid_job_id(import_id) do
    with %PostArchiveImport{} = import <- get_import(import_id) do
      PostArchiveImport.process(import)
    else
      nil -> {:cancel, :post_archive_import_not_found}
    end
  end

  def perform(%Job{}), do: :discard

  @impl Oban.Worker
  def timeout(_job), do: :infinity

  defp get_import(import_id) do
    PostArchiveImport.get(import_id)
  rescue
    _ -> nil
  end
end
