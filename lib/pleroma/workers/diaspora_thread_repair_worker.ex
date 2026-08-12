# Unfathomably BE
# ----------------
#
# File: workers/diaspora_thread_repair_worker.ex
#
# Purpose:
#   Repair diaspora* comment ancestry after native records arrive out of order.
#
# Responsibilities:
#   - resolve parent GUIDs through the local diaspora* record store
#   - attach projected comments to their projected parent activities
#   - schedule bounded descendant repair after a parent becomes available
#
# This file intentionally does NOT fetch diaspora* pods, parse XML envelopes,
# or expose private conversation data through public thread contexts.

defmodule Pleroma.Workers.DiasporaThreadRepairWorker do
  alias Pleroma.Activity
  alias Pleroma.Diaspora.Record
  alias Pleroma.Diaspora.Store
  alias Pleroma.Federation.ThreadLink

  use Oban.Worker,
    queue: :remote_fetcher,
    max_attempts: 3,
    unique: [
      period: 300,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:op, :activity_id]
    ]

  @op "repair_diaspora_thread"

  @spec enqueue_for_activity(Activity.t()) :: :scheduled | :ignored
  def enqueue_for_activity(%Activity{id: activity_id}), do: enqueue_for_activity_id(activity_id)
  def enqueue_for_activity(_), do: :ignored

  @spec enqueue_for_activity_id(binary()) :: :scheduled | :ignored
  def enqueue_for_activity_id(activity_id) when is_binary(activity_id) do
    case Store.get_by_ap_activity_id(activity_id) do
      %Record{} -> enqueue(activity_id)
      _ -> :ignored
    end
  end

  def enqueue_for_activity_id(_), do: :ignored

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => @op, "activity_id" => activity_id}})
      when is_binary(activity_id) do
    if Pleroma.Federation.enabled?() do
      case Store.get_by_ap_activity_id(activity_id) do
        %Record{} = record -> repair_record(record)
        nil -> {:cancel, :record_not_found}
      end
    else
      {:cancel, :federation_disabled}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :bad_request}

  defp repair_record(%Record{} = record) do
    with :ok <- repair_parent(record) do
      record.guid
      |> Store.projected_children_of()
      |> Enum.each(&enqueue_for_activity_id(&1.ap_activity_id))

      :ok
    end
  end

  defp repair_parent(%Record{data: %{"parent_guid" => parent_guid}, ap_activity_id: reply_id})
       when is_binary(parent_guid) and is_binary(reply_id) do
    with %Record{ap_activity_id: parent_id} when is_binary(parent_id) <- Store.get(parent_guid),
         %Activity{} = reply_activity <- Activity.get_by_id(reply_id),
         %Activity{} = parent_activity <- Activity.get_by_id(parent_id),
         {:ok, _activity} <- ThreadLink.repair(reply_activity, parent_activity) do
      :ok
    else
      nil -> :ok
      %Record{} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp repair_parent(%Record{}), do: :ok

  defp enqueue(activity_id) do
    %{"op" => @op, "activity_id" => activity_id}
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :scheduled
      {:error, _reason} -> :ignored
    end
  end
end

# end of workers/diaspora_thread_repair_worker.ex
