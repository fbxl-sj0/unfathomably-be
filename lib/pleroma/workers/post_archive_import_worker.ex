# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.PostArchiveImportWorker do
  use Oban.Worker, queue: :backup, max_attempts: 1

  alias Oban.Job
  alias Pleroma.User.PostArchiveImport

  def process(%PostArchiveImport{} = import) do
    %{"op" => "process", "import_id" => import.id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "process", "import_id" => import_id}}) do
    import_id
    |> PostArchiveImport.get()
    |> PostArchiveImport.process()
  end

  @impl Oban.Worker
  def timeout(_job), do: :infinity
end
