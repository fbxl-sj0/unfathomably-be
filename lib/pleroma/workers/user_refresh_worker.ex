# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.UserRefreshWorker do
  @moduledoc """
  Refreshes stale remote actors without blocking request or render paths.
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
      keys: [:op, :ap_id]
    ]

  alias Pleroma.User
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.Federation.Churn
  alias Pleroma.Workers.Cron.RssSourceIngestWorker

  @terminal_http_statuses [400, 401, 403, 404, 405, 406, 410, 501]
  @terminal_refresh_errors [
    :actor_tombstone,
    :forbidden,
    :native_nostr_disabled,
    :native_nostr_lookup_failed,
    :native_nostr_not_found,
    :not_found,
    :connect_timeout,
    :recv_response_timeout,
    :timeout,
    "Object has been deleted"
  ]
  @actor_refresh_timeout_seconds 30

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "refresh", "ap_id" => ap_id}})
      when is_binary(ap_id) and byte_size(ap_id) > 0 do
    case User.get_cached_by_ap_id(ap_id) do
      %User{} = user ->
        if FederatedTarget.rss_source?(user) do
          refresh_rss_source(user)
        else
          maybe_refresh_activitypub_actor(ap_id)
        end

      nil ->
        maybe_refresh_activitypub_actor(ap_id)
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  defp refresh_rss_source(%User{} = source) do
    if FederatedTarget.followed_rss_source?(source) do
      case RssSourceIngestWorker.schedule_source(source) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, {:rss_source_ingest_schedule, reason}}
      end
    else
      :ok
    end
  end

  defp maybe_refresh_activitypub_actor(ap_id) do
    if Pleroma.Federation.enabled?(),
      do: refresh_actor(ap_id),
      else: {:cancel, :federation_disabled}
  end

  defp refresh_actor(ap_id) do
    case User.fetch_by_ap_id(ap_id) do
      {:ok, %User{}} ->
        :ok

      {:error, reason} when reason in @terminal_refresh_errors ->
        {:cancel, reason}

      {:error, {:http, status} = reason} when status in @terminal_http_statuses ->
        {:cancel, reason}

      {:error, {:content_type, _} = reason} ->
        {:cancel, reason}

      {:error, reason} ->
        if Churn.terminal_transport_error?(reason) do
          {:cancel, reason}
        else
          {:error, reason}
        end

      _ ->
        :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Job{attempt: attempt}), do: min(300, 60 * max(attempt, 1))

  # Actor refreshes can include redirects and bounded compatibility lookups in
  # addition to the actor document itself. Keep the overall job finite while
  # allowing those individually bounded requests to complete.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(@actor_refresh_timeout_seconds)
end
