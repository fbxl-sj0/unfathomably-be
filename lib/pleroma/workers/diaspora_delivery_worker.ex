# Unfathomably BE
# ----------------
#
# File: workers/diaspora_delivery_worker.ex
#
# Purpose:
#   Deliver one serialized Diaspora entity to one remote pod.
#
# Responsibilities:
#   - keep delivery retries independent for each destination
#   - distinguish temporary HTTP failures from permanent rejection
#   - bound retry backoff and suppress duplicate incomplete deliveries
#
# This file intentionally does NOT select recipients, serialize entities, or
# manage Diaspora identities.

defmodule Pleroma.Workers.DiasporaDeliveryWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "diaspora",
    max_attempts: 5,
    unique: [period: 86_400, states: :incomplete]

  alias Pleroma.HTTP
  alias Pleroma.Workers.WorkerHelper

  @temporary_statuses [408, 425, 429]
  @content_types ["application/json", "application/magic-envelope+xml"]

  def enqueue_delivery(url, body, content_type)
      when is_binary(url) and is_binary(body) and content_type in @content_types do
    if valid_destination?(url) do
      __MODULE__.new(%{
        "body" => body,
        "content_type" => content_type,
        "url" => url
      })
      |> Oban.insert()
    else
      {:error, :invalid_destination}
    end
  end

  def enqueue_delivery(_url, _body, _content_type), do: {:error, :invalid_delivery}

  @impl Oban.Worker
  def perform(%Job{
        args: %{"body" => body, "content_type" => content_type, "url" => url}
      })
      when is_binary(body) and content_type in @content_types do
    if valid_destination?(url) do
      deliver(url, body, content_type)
    else
      {:cancel, :invalid_destination}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  @impl Oban.Worker
  def backoff(%Job{attempt: attempt}), do: WorkerHelper.sidekiq_backoff(attempt, 3, 10)

  defp deliver(url, body, content_type) do
    case HTTP.post(url, body, [{"content-type", content_type}], pool: :federation) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} when status in @temporary_statuses or status >= 500 ->
        {:error, {:http, status}}

      {:ok, %{status: status}} ->
        {:cancel, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:request_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:request_failure, kind, reason}}
  end

  defp valid_destination?(url) do
    Pleroma.ATProto.URL.public_https_url?(url)
  end
end

# end of workers/diaspora_delivery_worker.ex
