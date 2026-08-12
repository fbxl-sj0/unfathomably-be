# Unfathomably BE
# ----------------
#
# File: workers/atproto_sync_worker.ex
#
# Purpose:
#   Refresh the bounded feeds belonging to locally followed AT identities.
#
# Responsibilities:
#   - schedule one unique job for each locally relevant identity
#   - fetch only that identity's author feed through the configured AppView
#   - keep failures isolated so one PDS cannot stall other identities
#
# This file intentionally does NOT consume a relay firehose or discover global
# accounts and posts.

defmodule Pleroma.Workers.ATProtoSyncWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "atproto",
    max_attempts: 4,
    unique: [period: 240, states: :incomplete]

  alias Pleroma.ATProto
  alias Pleroma.ATProto.Bridge
  alias Pleroma.ATProto.Identity
  alias Pleroma.Repo

  @impl Oban.Worker
  def perform(%Job{args: %{"identity_id" => id}}) do
    case Repo.get(Identity, id) do
      %Identity{} = identity -> Bridge.ingest_author_feed(identity)
      nil -> {:cancel, :not_found}
    end
  end

  def perform(%Job{args: args}) when args == %{} do
    if ATProto.enabled?() do
      Bridge.followed_identities()
      |> Enum.each(fn identity ->
        __MODULE__.new(%{"identity_id" => identity.id}) |> Oban.insert()
      end)
    end

    :ok
  end

  def perform(%Job{}), do: {:cancel, :bad_request}
end

# end of workers/atproto_sync_worker.ex
