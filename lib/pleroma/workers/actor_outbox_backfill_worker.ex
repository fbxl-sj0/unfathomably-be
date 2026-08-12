# Unfathomably: bounded post-follow ActivityPub backfill
#
# File: actor_outbox_backfill_worker.ex
#
# Purpose:
#   Import a small amount of recent public history after a remote actor accepts
#   a local follow, without crawling an unbounded outbox in the inbox request.
#
# Responsibilities:
#   - recheck the active local follow before doing remote work
#   - fetch only the outbox root and, when needed, its first same-origin page
#   - extract a bounded set of canonical same-origin item identifiers
#   - schedule normal contained remote-fetch jobs at a configurable interval
#
# This file intentionally does not trust inline outbox activities, traverse an
# entire paginated history, or bypass the ordinary object-fetch validation path.

defmodule Pleroma.Workers.ActorOutboxBackfillWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "remote_fetcher",
    max_attempts: 3,
    unique: [
      period: 86_400,
      states: :incomplete,
      keys: [:follower, :actor, :outbox]
    ]

  alias Pleroma.Config
  alias Pleroma.Object.Fetcher
  alias Pleroma.User
  alias Pleroma.Web.LocalOrigin
  alias Pleroma.Workers.RemoteFetcherWorker

  @default_max_items 20
  @maximum_max_items 100
  @default_item_interval_seconds 2
  @maximum_item_interval_seconds 30
  @default_timeout_seconds 45

  require Logger

  @spec maybe_enqueue(User.t(), User.t()) :: :ok
  def maybe_enqueue(
        %User{local: true, ap_id: follower},
        %User{local: false, ap_id: actor, outbox_address: outbox}
      )
      when is_binary(follower) and is_binary(actor) and is_binary(outbox) do
    if enabled?() and safe_same_origin_url?(outbox, actor) do
      %{"follower" => follower, "actor" => actor, "outbox" => outbox}
      |> new()
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not enqueue bounded actor outbox backfill: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  def maybe_enqueue(%User{}, %User{}), do: :ok

  @impl Oban.Worker
  def perform(%Job{
        args: %{"follower" => follower_id, "actor" => actor_id, "outbox" => outbox}
      }) do
    with true <- Pleroma.Federation.enabled?() and enabled?(),
         %User{local: true} = follower <- User.get_cached_by_ap_id(follower_id),
         %User{local: false, outbox_address: ^outbox} = actor <-
           User.get_cached_by_ap_id(actor_id),
         true <- User.following?(follower, actor),
         true <- safe_same_origin_url?(outbox, actor.ap_id),
         {:ok, root} <- Fetcher.fetch_and_contain_remote_collection_from_id(outbox),
         {:ok, page} <- first_page(root, outbox),
         :ok <- enqueue_items(collection_item_ids(page, actor.ap_id, max_items())) do
      :ok
    else
      false -> {:cancel, :disabled_or_not_following}
      nil -> {:cancel, :actor_not_found}
      {:cancel, _reason} = cancel -> cancel
      {:error, reason} -> {:error, reason}
      _mismatch -> {:cancel, :stale_actor_outbox}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  @doc false
  def collection_item_ids(data, actor_id, limit)
      when is_map(data) and is_binary(actor_id) and is_integer(limit) and limit > 0 do
    (data["orderedItems"] || data["items"] || [])
    |> List.wrap()
    |> Enum.map(&reference_id/1)
    |> Enum.filter(&safe_same_origin_url?(&1, actor_id))
    |> Enum.uniq()
    |> Enum.take(min(limit, @maximum_max_items))
  end

  def collection_item_ids(_data, _actor_id, _limit), do: []

  defp first_page(data, outbox) when is_map(data) do
    if collection_item_ids(data, outbox, 1) == [] do
      case data["first"] do
        %{} = page ->
          {:ok, page}

        page_id when is_binary(page_id) ->
          if page_id != outbox and safe_same_origin_url?(page_id, outbox) do
            Fetcher.fetch_and_contain_remote_collection_from_id(page_id)
          else
            {:error, :invalid_outbox_page}
          end

        _missing ->
          {:ok, data}
      end
    else
      {:ok, data}
    end
  end

  defp enqueue_items(ids) do
    ids
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {id, index}, :ok ->
      args = %{"op" => "fetch_remote", "id" => id, "source" => "follow_outbox"}
      schedule_in = index * item_interval_seconds()

      case args |> RemoteFetcherWorker.new(schedule_in: schedule_in) |> Oban.insert() do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:enqueue_failed, reason}}}
      end
    end)
  end

  defp reference_id(id) when is_binary(id), do: id
  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(%{"href" => href}) when is_binary(href), do: href
  defp reference_id(_reference), do: nil

  defp safe_same_origin_url?(url, reference)
       when is_binary(url) and is_binary(reference) and byte_size(url) <= 2_048 do
    with false <- LocalOrigin.local_url?(url),
         %URI{scheme: left_scheme, host: left_host, port: left_port, userinfo: nil} <-
           URI.parse(url),
         %URI{scheme: right_scheme, host: right_host, port: right_port, userinfo: nil} <-
           URI.parse(reference),
         true <- left_scheme in ["http", "https"],
         true <- right_scheme in ["http", "https"],
         true <- is_binary(left_host) and is_binary(right_host) do
      {left_scheme, String.downcase(left_host), effective_port(left_scheme, left_port)} ==
        {right_scheme, String.downcase(right_host), effective_port(right_scheme, right_port)}
    else
      _invalid -> false
    end
  rescue
    _ -> false
  end

  defp safe_same_origin_url?(_url, _reference), do: false

  defp effective_port("http", nil), do: 80
  defp effective_port("https", nil), do: 443
  defp effective_port(_scheme, port), do: port

  defp enabled?, do: Config.get([__MODULE__, :enabled], true) == true

  defp max_items do
    Config.get([__MODULE__, :max_items], @default_max_items)
    |> bounded_integer(@default_max_items, 1, @maximum_max_items)
  end

  defp item_interval_seconds do
    Config.get([__MODULE__, :item_interval_seconds], @default_item_interval_seconds)
    |> bounded_integer(
      @default_item_interval_seconds,
      1,
      @maximum_item_interval_seconds
    )
  end

  defp bounded_integer(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp bounded_integer(_value, default, _minimum, _maximum), do: default

  @impl Oban.Worker
  def backoff(%Job{attempt: attempt}), do: min(300, 60 * max(attempt, 1))

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(@default_timeout_seconds)
end

# end of actor_outbox_backfill_worker.ex
