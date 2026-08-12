# Unfathomably BE
# ----------------
#
# File: nostr/search.ex
#
# Purpose:
#   Perform bounded server-side NIP-50 discovery through approved search relays.
#
# Responsibilities:
#   - require advertised NIP-50 support through NIP-11
#   - issue short-lived WebSocket request subscriptions from the server
#   - verify signatures and filter matches before accepting relay results
#   - materialize explicit profile-search results as normal remote accounts
#
# This file intentionally does NOT expose browser relay connections, perform
# unbounded global searches, or import posts merely because they matched text.

defmodule Pleroma.Nostr.Search do
  alias Pleroma.Config
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection
  alias Pleroma.Nostr.RelayInfo
  alias Pleroma.Nostr.RelayManager

  @cache :nostr_search_cache
  @cachex Config.get([:cachex, :provider], Cachex)
  @maximum_profile_results 20

  def profile_user_ids(query, limit)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    query = String.trim(query)
    limit = min(limit, @maximum_profile_results)

    if valid_profile_query?(query) do
      cache_key = {:profiles, String.downcase(query), limit}

      case @cachex.fetch(@cache, cache_key, fn ->
             {:commit, fetch_profile_user_ids(query, limit)}
           end) do
        {status, user_ids} when status in [:ok, :commit] and is_list(user_ids) -> user_ids
        _ -> fetch_profile_user_ids(query, limit)
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  def profile_user_ids(_query, _limit), do: []

  def query(filters, opts \\ [])

  def query(filters, opts) when is_list(filters) do
    limit = option_integer(opts, :limit, 50, 1, 100)
    timeout = option_integer(opts, :timeout, configured_timeout(), 250, 10_000)

    with true <- Nostr.enabled?(),
         {:ok, filters} <- Protocol.validate_filters(filters) do
      relay_requests = search_relay_requests(filters, limit)
      pending = request_relays(relay_requests, timeout)
      deadline = System.monotonic_time(:millisecond) + timeout

      pending
      |> collect_results([], deadline)
      |> Enum.uniq_by(& &1.event["id"])
      |> Enum.sort_by(
        &{result_score(&1, filters), &1.event["created_at"]},
        :desc
      )
      |> Enum.take(limit)
      |> then(&{:ok, &1})
    else
      false -> {:ok, []}
      {:error, _reason} = error -> error
      _ -> {:error, :search_unavailable}
    end
  rescue
    _ -> {:error, :search_unavailable}
  catch
    _, _ -> {:error, :search_unavailable}
  end

  def query(_filters, _opts), do: {:error, :invalid_filter}

  defp fetch_profile_user_ids(query, limit) do
    filter = %{"kinds" => [0], "search" => query, "limit" => limit}

    case query([filter], limit: limit) do
      {:ok, results} ->
        results
        |> Enum.each(fn %{event: event, relay_url: relay_url} ->
          _ = Bridge.ingest_event(event, relay_url, {:nip50_search, [filter]})
        end)

        results
        |> Enum.flat_map(fn %{event: event} ->
          case Identity.get_profile(event["pubkey"]) do
            %{user_id: user_id} when not is_nil(user_id) -> [user_id]
            _ -> []
          end
        end)
        |> Enum.uniq()
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp search_relay_requests(filters, limit) do
    Nostr.search_relays()
    |> Enum.take(configured_relay_limit())
    |> Task.async_stream(&relay_request(&1, filters, limit),
      max_concurrency: configured_relay_limit(),
      ordered: false,
      timeout: Config.get([Nostr, :relay_info_timeout_ms], 3_000) + 500,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, request}} -> [request]
      _ -> []
    end)
  end

  defp relay_request(relay_url, filters, limit) do
    with {:ok, information} <- RelayInfo.get(relay_url),
         true <- 50 in information["supported_nips"] do
      relay_limit = RelayInfo.filter_limit(information, limit)

      relay_filters =
        Enum.map(filters, fn filter ->
          Map.update(filter, "limit", relay_limit, &min(&1, relay_limit))
        end)

      {:ok, %{relay_url: relay_url, filters: relay_filters}}
    else
      _ -> {:error, :nip50_not_supported}
    end
  end

  defp request_relays(relay_requests, timeout) do
    Enum.reduce(relay_requests, %{}, fn request, pending ->
      subscription_id = subscription_id()
      RelayManager.ensure_connection(request.relay_url)

      case RelayConnection.request(
             request.relay_url,
             subscription_id,
             request.filters,
             self(),
             timeout
           ) do
        :ok -> Map.put(pending, subscription_id, request)
        _ -> pending
      end
    end)
  end

  defp collect_results(pending, results, _deadline) when map_size(pending) == 0,
    do: results

  defp collect_results(pending, results, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:nostr_relay_event, relay_url, subscription_id, raw_event} ->
        case Map.get(pending, subscription_id) do
          %{relay_url: ^relay_url, filters: filters} ->
            results = maybe_add_result(results, raw_event, relay_url, filters)
            collect_results(pending, results, deadline)

          _ ->
            collect_results(pending, results, deadline)
        end

      {:nostr_relay_eose, relay_url, subscription_id, _reason} ->
        pending =
          case Map.get(pending, subscription_id) do
            %{relay_url: ^relay_url} -> Map.delete(pending, subscription_id)
            _ -> pending
          end

        collect_results(pending, results, deadline)
    after
      remaining -> results
    end
  end

  defp maybe_add_result(results, raw_event, relay_url, filters) do
    with {:ok, event} <- Protocol.validate_event(raw_event),
         true <- Enum.any?(filters, &Protocol.matches?(event, &1)) do
      [%{event: event, relay_url: relay_url} | results]
    else
      _ -> results
    end
  end

  defp result_score(%{event: event}, filters) do
    filters
    |> Enum.map(&Protocol.search_score(event, &1["search"]))
    |> Enum.max(fn -> 0 end)
  end

  defp valid_profile_query?(query) do
    minimum = Config.get([Nostr, :search_min_query_chars], 3)
    minimum = if is_integer(minimum) and minimum in 2..20, do: minimum, else: 3

    String.length(query) >= minimum and byte_size(query) <= 256 and
      not String.starts_with?(query, ["http://", "https://"])
  end

  defp configured_relay_limit do
    Config.get([Nostr, :search_max_relays], 3)
    |> case do
      value when is_integer(value) and value in 1..8 -> value
      _ -> 3
    end
  end

  defp configured_timeout do
    Config.get([Nostr, :search_timeout_ms], 1_500)
  end

  defp option_integer(options, key, default, minimum, maximum) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) -> value |> max(minimum) |> min(maximum)
      _ -> default
    end
  end

  defp subscription_id do
    "unf-search-#{System.unique_integer([:positive, :monotonic])}"
  end
end

# end of nostr/search.ex
