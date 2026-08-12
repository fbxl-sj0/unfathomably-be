# Unfathomably appendable collection confirmation worker
#
# File: appendable_collection_worker.ex
#
# Purpose:
#   Confirm an accepted FEP-400e contribution after its Create transaction.

defmodule Pleroma.Workers.AppendableCollectionWorker do
  use Oban.Worker,
    queue: :background,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:object, :owner]]

  alias Pleroma.Web.ActivityPub.AppendableCollection
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Utils

  require Pleroma.Constants

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"object" => object_id, "owner" => owner_id}}) do
    with {:ok, owner, object} <- AppendableCollection.confirmation_owner(object_id, owner_id),
         data <- %{
           "id" => Utils.generate_activity_id(),
           "type" => "Add",
           "actor" => owner.ap_id,
           "object" => object.data["id"],
           "target" => AppendableCollection.collection_id(owner),
           "to" => [Pleroma.Constants.as_public()],
           "cc" => [owner.follower_address]
         },
         {:ok, _activity, _meta} <- Pipeline.common_pipeline(data, local: true) do
      :ok
    end
  end
end

# end of appendable_collection_worker.ex
