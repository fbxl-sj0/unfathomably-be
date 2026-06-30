# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.SearchIndexingWorker do
  use Pleroma.Workers.WorkerHelper, queue: "search_indexing"

  alias Pleroma.Config.Getting, as: Config

  defguardp valid_job_id(id) when (is_binary(id) and byte_size(id) > 0) or is_integer(id)

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "add_to_index", "activity" => activity_id}})
      when valid_job_id(activity_id) do
    with %Pleroma.Activity{} = activity <- get_activity(activity_id) do
      search_module = Config.get([Pleroma.Search, :module])

      search_module.add_to_index(activity)
    else
      nil -> {:cancel, :activity_not_found}
    end
  end

  def perform(%Job{args: %{"op" => "remove_from_index", "object" => object_id}})
      when valid_job_id(object_id) do
    with %Pleroma.Object{} = object <- get_object(object_id) do
      search_module = Config.get([Pleroma.Search, :module])

      search_module.remove_from_index(object)
    else
      nil -> {:cancel, :object_not_found}
    end
  end

  def perform(%Job{}), do: :discard

  defp get_activity(activity_id) do
    Pleroma.Activity.get_by_id_with_object(activity_id)
  rescue
    _ -> nil
  end

  defp get_object(object_id) do
    Pleroma.Object.get_by_id(object_id)
  rescue
    _ -> nil
  end
end

# end of search_indexing_worker.ex
