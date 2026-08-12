# Unfathomably FASP account discovery
# ------------------------------------
#
# File: account_search.ex
#
# Purpose:
#   Resolve bounded account-search results from approved FASP providers.
#
# Responsibilities:
#   - query only providers with an explicitly active account-search capability
#   - merge and deduplicate returned ActivityPub actor identifiers
#   - resolve a small bounded set through the normal remote-user pipeline
#   - fail quietly back to local search when a provider is unavailable
#
# This file intentionally does not send user identifiers, search anonymous
# requests, bypass MRF, or return actors directly to an API response.

defmodule Pleroma.FASP.AccountSearch do
  alias Pleroma.FASP.Client
  alias Pleroma.FASP.Registration
  alias Pleroma.User

  require Logger

  @capability "account_search"
  @version "0.1"
  @maximum_results 8
  @provider_timeout 5_000
  @actor_timeout 8_000

  def user_ids(query, requested_limit) when is_binary(query) and is_integer(requested_limit) do
    limit = requested_limit |> max(1) |> min(@maximum_results)

    Registration.accepted_with_capability(@capability, @version)
    |> Task.async_stream(&Client.account_search(&1, query, limit),
      ordered: false,
      max_concurrency: 2,
      timeout: @provider_timeout,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, actor_ids}} ->
        actor_ids

      {:ok, {:error, reason}} ->
        Logger.debug("FASP account search skipped provider response: #{inspect(reason)}")
        []

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(limit)
    |> resolve_user_ids()
  end

  def user_ids(_, _), do: []

  defp resolve_user_ids(actor_ids) do
    actor_ids
    |> Task.async_stream(&User.get_or_fetch_by_ap_id/1,
      ordered: true,
      max_concurrency: 3,
      timeout: @actor_timeout,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, %User{id: id}}} -> [id]
      _ -> []
    end)
    |> Enum.uniq()
  end
end

# end of account_search.ex
