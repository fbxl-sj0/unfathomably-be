# Unfathomably BE
# ----------------
#
# File: workers/atproto_thread_fetch_worker.ex
#
# Purpose:
#   Hydrate an ATProto post thread when its local context is opened.
#
# Responsibilities:
#   - map a projected ActivityPub status back to its ATProto URI
#   - request the bounded AppView parent and reply tree through the bridge
#   - deduplicate concurrent context hydration for the same ATProto post
#
# This file intentionally does NOT render timelines, implement AppView HTTP,
# or translate records directly into ActivityPub objects.

defmodule Pleroma.Workers.ATProtoThreadFetchWorker do
  alias Pleroma.Activity
  alias Pleroma.ATProto.Bridge
  alias Pleroma.ATProto.Record
  alias Pleroma.ATProto.Store

  use Oban.Worker,
    queue: :remote_fetcher,
    max_attempts: 3,
    unique: [
      period: 300,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:op, :uri]
    ]

  @op "hydrate_atproto_thread"

  @spec enqueue_for_activity(Activity.t()) :: :scheduled | :ignored
  def enqueue_for_activity(%Activity{id: activity_id}) do
    case Store.get_by_ap_activity_id(activity_id) do
      %Record{uri: uri} when is_binary(uri) -> enqueue_uri(uri)
      _ -> :ignored
    end
  end

  def enqueue_for_activity(_), do: :ignored

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => @op, "uri" => uri}}) when is_binary(uri) do
    if Pleroma.Federation.enabled?() do
      case Bridge.resolve_uri(uri) do
        {:ok, _result} ->
          :ok

        {:error, :not_found} ->
          case Bridge.delete_projection(uri) do
            :ok -> {:cancel, :not_found}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:cancel, :federation_disabled}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :bad_request}

  defp enqueue_uri(uri) do
    %{"op" => @op, "uri" => uri}
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :scheduled
      {:error, _reason} -> :ignored
    end
  end
end

# end of workers/atproto_thread_fetch_worker.ex
