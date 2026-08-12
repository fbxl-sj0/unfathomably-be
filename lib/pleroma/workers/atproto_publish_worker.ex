# Unfathomably BE
# ----------------
#
# File: workers/atproto_publish_worker.ex
#
# Purpose:
#   Export committed local activities to linked AT Protocol repositories.
#
# Responsibilities:
#   - load the final activity after its database transaction commits
#   - invoke the idempotent AT Protocol publisher with bounded retries
#
# This file intentionally does NOT translate records or access credentials.

defmodule Pleroma.Workers.ATProtoPublishWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "atproto",
    max_attempts: 4,
    unique: [period: 86_400, states: :incomplete]

  alias Pleroma.Activity
  alias Pleroma.ATProto.Publisher

  def enqueue_activity(id) do
    __MODULE__.new(%{"id" => id}) |> Oban.insert()
    :ok
  end

  @impl Oban.Worker
  def perform(%Job{args: %{"id" => id}}) do
    case Activity.get_by_id(id) do
      %Activity{} = activity -> Publisher.publish(activity)
      nil -> {:cancel, :not_found}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}
end

# end of workers/atproto_publish_worker.ex
