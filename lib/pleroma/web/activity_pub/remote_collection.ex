# Project: Unfathomably ActivityPub
# ---------------------------------
#
# File: remote_collection.ex
#
# Purpose:
#
#     Read remote ActivityStreams collections through one bounded and
#     origin-safe traversal contract.
#
# Responsibilities:
#
#     * accept collection roots and collection pages
#     * preserve mixed URL and inline-object entries
#     * follow same-origin first, current, and next page references
#     * stop cycles and enforce page and item budgets
#
# This file intentionally does NOT contain:
#
#     * object ingestion
#     * actor resolution
#     * collection-specific authorization policy

defmodule Pleroma.Web.ActivityPub.RemoteCollection do
  @moduledoc """
  Bounded reader for remote ActivityStreams collection pages.

  Page references are transport links, so they remain on the root collection's
  canonical origin. Collection members may belong to other origins because
  follower, moderator, and featured collections commonly contain remote actors
  or objects.
  """

  alias Pleroma.Object.Fetcher

  @collection_types ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"]
  @default_page_limit 4
  @default_item_limit 150
  @maximum_page_limit 16
  @maximum_item_limit 2_000
  @maximum_url_length 2_048

  def fetch(address, opts \\ []) do
    with {:ok, address, root} <- fetch_root(address) do
      {items, _truncated?, incomplete?} = collect(root, address, opts)

      if incomplete? do
        {:error, :collection_incomplete}
      else
        {:ok, items}
      end
    end
  end

  def count(address, opts \\ []) do
    with {:ok, address, root} <- fetch_root(address) do
      case total_items(root) do
        {:ok, count} ->
          {:ok, count}

        :missing ->
          {items, truncated?, incomplete?} = collect(root, address, opts)

          cond do
            incomplete? -> {:error, :collection_incomplete}
            truncated? -> {:error, :collection_too_large}
            true -> {:ok, length(items)}
          end
      end
    end
  end

  defp fetch_root(address) do
    with {:ok, address} <- safe_http_url(address),
         {:ok, %{} = root} <- Fetcher.fetch_and_contain_remote_collection_from_id(address),
         true <- collection?(root) do
      {:ok, address, root}
    else
      false -> {:error, :invalid_collection}
      {:ok, _invalid} -> {:error, :invalid_collection}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_collection}
    end
  end

  defp collect(root, address, opts) do
    state = %{
      items: [],
      items_left: bounded_option(opts, :max_items, @default_item_limit, @maximum_item_limit),
      pages_left: bounded_option(opts, :max_pages, @default_page_limit, @maximum_page_limit),
      seen_items: MapSet.new(),
      visited_pages: MapSet.new(),
      truncated?: false,
      incomplete?: false
    }

    state = walk_collection(root, address, state, address)
    {Enum.reverse(state.items), state.truncated?, state.incomplete?}
  end

  defp walk_collection(_collection, _root, %{pages_left: 0} = state, _reference) do
    %{state | truncated?: true}
  end

  defp walk_collection(collection, root, state, reference) when is_map(collection) do
    identity = page_identity(collection, reference)

    cond do
      not collection?(collection) ->
        %{state | incomplete?: true}

      is_binary(identity) and MapSet.member?(state.visited_pages, identity) ->
        state

      true ->
        state = %{
          state
          | pages_left: state.pages_left - 1,
            visited_pages: maybe_mark_page(state.visited_pages, identity)
        }

        state = add_items(state, collection_items(collection))

        collection
        |> page_references()
        |> Enum.reduce(state, &walk_reference(&1, root, &2))
    end
  end

  defp walk_collection(_collection, _root, state, _reference), do: state

  defp walk_reference(_reference, _root, %{pages_left: 0} = state) do
    %{state | truncated?: true}
  end

  defp walk_reference(%{} = page, root, state) do
    case page["id"] do
      nil ->
        walk_collection(page, root, state, nil)

      id when is_binary(id) ->
        if same_origin?(id, root),
          do: walk_collection(page, root, state, id),
          else: %{state | incomplete?: true}

      _invalid ->
        %{state | incomplete?: true}
    end
  end

  defp walk_reference(reference, root, state) when is_binary(reference) do
    cond do
      MapSet.member?(state.visited_pages, reference) ->
        state

      not same_origin?(reference, root) ->
        %{state | incomplete?: true}

      true ->
        case Fetcher.fetch_and_contain_remote_collection_from_id(reference) do
          {:ok, %{} = page} -> walk_collection(page, root, state, reference)
          _unavailable -> %{state | incomplete?: true}
        end
    end
  end

  defp walk_reference(_reference, _root, state), do: %{state | incomplete?: true}

  defp add_items(state, items) when is_list(items) do
    Enum.reduce(items, state, fn item, current ->
      case normalize_item(item) do
        {:ok, normalized, key} -> add_unique_item(current, normalized, key)
        :error -> current
      end
    end)
  end

  defp add_unique_item(%{seen_items: seen} = state, item, key) do
    if MapSet.member?(seen, key) do
      state
    else
      add_new_item(state, item, key)
    end
  end

  defp add_new_item(%{items_left: 0} = state, _item, _key),
    do: %{state | truncated?: true}

  defp add_new_item(state, item, key) do
    %{
      state
      | items: [item | state.items],
        items_left: state.items_left - 1,
        seen_items: MapSet.put(state.seen_items, key)
    }
  end

  defp normalize_item(item) when is_binary(item) do
    case safe_http_url(item) do
      {:ok, id} -> {:ok, id, id}
      {:error, _reason} -> :error
    end
  end

  defp normalize_item(%{"id" => id} = item) when is_binary(id) do
    case safe_http_url(id) do
      {:ok, id} -> {:ok, item, id}
      {:error, _reason} -> :error
    end
  end

  defp normalize_item(%{"href" => href} = item) when is_binary(href) do
    case safe_http_url(href) do
      {:ok, href} -> {:ok, item, href}
      {:error, _reason} -> :error
    end
  end

  defp normalize_item(_item), do: :error

  defp collection_items(%{"orderedItems" => items}) when is_list(items), do: items
  defp collection_items(%{"items" => items}) when is_list(items), do: items
  defp collection_items(_collection), do: []

  defp page_references(collection) do
    [collection["first"], collection["current"], collection["next"]]
    |> Enum.reject(&is_nil/1)
  end

  defp page_identity(_collection, reference) when is_binary(reference), do: reference
  defp page_identity(%{"id" => id}, _reference) when is_binary(id), do: id
  defp page_identity(_collection, _reference), do: nil

  defp maybe_mark_page(visited, identity) when is_binary(identity),
    do: MapSet.put(visited, identity)

  defp maybe_mark_page(visited, _identity), do: visited

  defp collection?(%{"type" => type} = collection) do
    Enum.any?(List.wrap(type), &(&1 in @collection_types)) or collection_shape?(collection)
  end

  defp collection?(collection) when is_map(collection), do: collection_shape?(collection)

  defp collection_shape?(collection) do
    Enum.any?(
      ~w[first current next items orderedItems totalItems total_items],
      &Map.has_key?(collection, &1)
    )
  end

  defp total_items(%{"totalItems" => value}), do: nonnegative_integer(value)
  defp total_items(%{"total_items" => value}), do: nonnegative_integer(value)
  defp total_items(_collection), do: :missing

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 0 -> {:ok, count}
      _invalid -> :missing
    end
  end

  defp nonnegative_integer(_value), do: :missing

  defp bounded_option(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> min(value, maximum)
      _invalid -> default
    end
  end

  defp safe_http_url(url) when is_binary(url) and byte_size(url) <= @maximum_url_length do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, url}

      _invalid ->
        {:error, :invalid_url}
    end
  end

  defp safe_http_url(_url), do: {:error, :invalid_url}

  defp same_origin?(left, right) do
    with {:ok, _left} <- safe_http_url(left),
         {:ok, _right} <- safe_http_url(right),
         %URI{scheme: left_scheme, host: left_host, port: left_port} <- URI.parse(left),
         %URI{scheme: right_scheme, host: right_host, port: right_port} <- URI.parse(right) do
      {left_scheme, String.downcase(left_host), effective_port(left_scheme, left_port)} ==
        {right_scheme, String.downcase(right_host), effective_port(right_scheme, right_port)}
    else
      _invalid -> false
    end
  end

  defp effective_port("http", nil), do: 80
  defp effective_port("https", nil), do: 443
  defp effective_port(_scheme, port), do: port
end

# end of remote_collection.ex
