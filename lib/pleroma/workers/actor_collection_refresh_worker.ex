# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ActorCollectionRefreshWorker do
  @moduledoc """
  Refreshes optional remote actor collections outside actor request paths.

  Featured and moderator collections are useful presentation metadata, but
  remote servers often serve them more slowly than the actor document. Keeping
  each collection in a unique background job lets inbox and profile resolution
  proceed without discarding collection failures or erasing cached metadata.
  """

  use Pleroma.Workers.WorkerHelper,
    queue: "background",
    max_attempts: 3,
    unique: [
      period: 300,
      states: [
        :available,
        :scheduled,
        :executing,
        :retryable,
        :suspended,
        :completed,
        :cancelled,
        :discarded
      ],
      keys: [:ap_id, :kind, :collection]
    ]

  alias Pleroma.Object.Fetcher
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.AggregateFeedMembership
  alias Pleroma.Web.Federation.Churn

  @terminal_http_statuses [400, 401, 403, 404, 405, 406, 410, 501]
  @terminal_collection_errors [
    :collection_too_large,
    :cooldown,
    :forbidden,
    :not_found,
    "Object has been deleted"
  ]
  @collection_refresh_timeout_seconds 35
  @max_aggregate_feed_members 24
  @aggregate_member_timeout 8_000

  @impl Oban.Worker
  def perform(%Job{
        args: %{
          "ap_id" => ap_id,
          "kind" => kind,
          "collection" => collection
        }
      })
      when is_binary(ap_id) and byte_size(ap_id) > 0 and
             kind in ["featured", "moderators", "aggregate_feed"] and
             is_binary(collection) and byte_size(collection) > 0 do
    with {:federation, true} <- {:federation, Pleroma.Federation.enabled?()},
         %User{} = user <- User.get_cached_by_ap_id(ap_id),
         :ok <- ensure_current_collection(user, kind, collection),
         {:ok, value} <- fetch_collection(kind, collection),
         %User{} = current_user <- Repo.get(User, user.id),
         :ok <- ensure_current_collection(current_user, kind, collection),
         :ok <- ensure_actor_unchanged(user, current_user),
         {:ok, _updated_user} <- persist_collection(current_user, kind, value) do
      maybe_enqueue_pins(kind, value)
      :ok
    else
      {:federation, false} ->
        {:cancel, :federation_disabled}

      nil ->
        {:cancel, :actor_not_found}

      {:cancel, _reason} = cancelled ->
        cancelled

      {:snooze, _seconds} = snooze ->
        snooze

      {:error, {:http, status} = reason} when status in @terminal_http_statuses ->
        {:cancel, reason}

      {:error, reason} when reason in @terminal_collection_errors ->
        {:cancel, reason}

      {:error, {:content_type, _content_type} = reason} ->
        {:cancel, reason}

      {:error, reason} ->
        if Churn.terminal_transport_error?(reason) do
          {:cancel, reason}
        else
          {:error, reason}
        end

      error ->
        {:error, error}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  defp ensure_current_collection(
         %User{featured_address: collection},
         "featured",
         collection
       ),
       do: :ok

  defp ensure_current_collection(
         %User{attributed_to_address: collection},
         "moderators",
         collection
       ),
       do: :ok

  defp ensure_current_collection(
         %User{actor_type: "Feed", following_address: collection},
         "aggregate_feed",
         collection
       ),
       do: :ok

  defp ensure_current_collection(%User{}, _kind, _collection),
    do: {:cancel, :stale_collection}

  defp ensure_actor_unchanged(
         %User{updated_at: updated_at},
         %User{updated_at: updated_at}
       ),
       do: :ok

  defp ensure_actor_unchanged(%User{}, %User{}), do: {:snooze, 10}

  defp fetch_collection("featured", collection) do
    ActivityPub.fetch_featured_collection_from_ap_id(collection)
  end

  defp fetch_collection("moderators", collection) do
    ActivityPub.fetch_actor_collection_count(collection)
  end

  defp fetch_collection("aggregate_feed", collection) do
    with {:ok, root} <- Fetcher.fetch_and_contain_remote_collection_from_id(collection),
         {:ok, page} <- aggregate_feed_page(root, collection) do
      page
      |> aggregate_feed_member_ids()
      |> resolve_aggregate_feed_communities()
      |> then(&{:ok, &1})
    end
  end

  defp persist_collection(user, "featured", pinned_objects) when is_map(pinned_objects) do
    user
    |> Ecto.Changeset.change(pinned_objects: pinned_objects)
    |> User.update_and_set_cache()
  end

  defp persist_collection(user, "moderators", moderator_count)
       when is_integer(moderator_count) and moderator_count >= 0 do
    user
    |> Ecto.Changeset.change(moderator_count: moderator_count)
    |> User.update_and_set_cache()
  end

  defp persist_collection(
         %User{actor_type: "Feed"} = user,
         "aggregate_feed",
         communities
       )
       when is_list(communities) do
    AggregateFeedMembership.sync_communities(user, communities)
  end

  defp persist_collection(_user, _kind, _value), do: {:error, :invalid_collection}

  defp maybe_enqueue_pins("featured", pinned_objects) do
    ActivityPub.enqueue_pin_fetches(%{pinned_objects: pinned_objects})
  end

  defp maybe_enqueue_pins(_kind, _value), do: :ok

  defp aggregate_feed_page(data, collection) when is_map(data) do
    if aggregate_feed_member_ids(data) == [] do
      case data["first"] do
        page when is_map(page) ->
          {:ok, page}

        page_id when is_binary(page_id) ->
          if page_id != collection and same_origin?(page_id, collection) do
            Fetcher.fetch_and_contain_remote_collection_from_id(page_id)
          else
            {:error, :invalid_collection_page}
          end

        _missing_page ->
          {:ok, data}
      end
    else
      {:ok, data}
    end
  end

  defp aggregate_feed_member_ids(data) when is_map(data) do
    (data["orderedItems"] || data["items"] || [])
    |> List.wrap()
    |> Enum.map(&collection_reference_id/1)
    |> Enum.filter(&safe_activitypub_id?/1)
    |> Enum.uniq()
    |> Enum.take(@max_aggregate_feed_members)
  end

  defp resolve_aggregate_feed_communities(ids) do
    ids
    |> Task.async_stream(&resolve_aggregate_feed_community/1,
      ordered: false,
      max_concurrency: 4,
      timeout: @aggregate_member_timeout,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, %User{actor_type: "Group"} = community} -> [community]
      _unavailable_or_unsupported -> []
    end)
  end

  defp resolve_aggregate_feed_community(ap_id) do
    case User.get_or_fetch_by_ap_id(ap_id) do
      {:ok, %User{} = user} -> user
      %User{} = user -> user
      _unavailable -> nil
    end
  end

  defp collection_reference_id(id) when is_binary(id), do: id
  defp collection_reference_id(%{"id" => id}) when is_binary(id), do: id
  defp collection_reference_id(%{"href" => href}) when is_binary(href), do: href
  defp collection_reference_id(_reference), do: nil

  defp safe_activitypub_id?(id) when is_binary(id) and byte_size(id) <= 2_048 do
    case URI.parse(id) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _invalid ->
        false
    end
  end

  defp safe_activitypub_id?(_id), do: false

  defp same_origin?(left, right) do
    with %URI{scheme: left_scheme, host: left_host, port: left_port, userinfo: nil} <-
           URI.parse(left),
         %URI{scheme: right_scheme, host: right_host, port: right_port, userinfo: nil} <-
           URI.parse(right),
         true <- left_scheme in ["http", "https"],
         true <- right_scheme in ["http", "https"],
         true <- is_binary(left_host) and is_binary(right_host) do
      {left_scheme, String.downcase(left_host), effective_port(left_scheme, left_port)} ==
        {right_scheme, String.downcase(right_host), effective_port(right_scheme, right_port)}
    else
      _invalid -> false
    end
  end

  defp effective_port("http", nil), do: 80
  defp effective_port("https", nil), do: 443
  defp effective_port(_scheme, port), do: port

  @impl Oban.Worker
  def backoff(%Job{attempt: attempt}), do: min(300, 60 * max(attempt, 1))

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(@collection_refresh_timeout_seconds)
end

# end of lib/pleroma/workers/actor_collection_refresh_worker.ex
