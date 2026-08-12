# Unfathomably BE
# ----------------
#
# File: workers/native_thread_hydration.ex
#
# Purpose:
#   Dispatch context-open hydration to non-ActivityPub bridge protocols.
#
# Responsibilities:
#   - map a rendered ActivityPub object back to its Create activity
#   - ask ATProto to fetch its bounded AppView thread
#   - ask diaspora* to repair locally delivered comment ancestry
#
# This file intentionally does NOT enqueue ActivityPub or Nostr hydration;
# those protocols retain their existing specialized context paths.

defmodule Pleroma.Workers.NativeThreadHydration do
  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Workers.ATProtoThreadFetchWorker
  alias Pleroma.Workers.DiasporaThreadRepairWorker

  @spec enqueue_for_object(Object.t()) :: :scheduled | :ignored
  def enqueue_for_object(%Object{data: %{"id" => object_id}}) when is_binary(object_id) do
    case Activity.get_create_by_object_ap_id(object_id) do
      %Activity{} = activity ->
        results = [
          ATProtoThreadFetchWorker.enqueue_for_activity(activity),
          DiasporaThreadRepairWorker.enqueue_for_activity(activity)
        ]

        if :scheduled in results, do: :scheduled, else: :ignored

      _ ->
        :ignored
    end
  end

  def enqueue_for_object(_), do: :ignored
end

# end of workers/native_thread_hydration.ex
