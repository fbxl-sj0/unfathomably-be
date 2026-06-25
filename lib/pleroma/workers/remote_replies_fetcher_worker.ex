# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RemoteRepliesFetcherWorker do
  alias Pleroma.Config
  alias Pleroma.EctoType.ActivityPub.ObjectValidators.ObjectID
  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.RemoteFetcherWorker

  use Oban.Worker,
    queue: :remote_fetcher,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:op, :object_id, :refresh_index]
    ]

  @op "refresh_replies"
  @triggered_refresh_index "triggered"
  @default_config [
    enabled: true,
    schedule: [15 * 60, 60 * 60, 6 * 60 * 60],
    triggered_refresh_delay: 5 * 60,
    triggered_refresh_ancestor_depth: 3,
    max_pages: 2,
    max_items: 40
  ]

  def enqueue_for_object(
        %Object{data: %{"id" => object_id, "replies_collection" => collection_id}} = object,
        depth
      )
      when is_binary(collection_id) do
    if enabled?() and not Object.local?(object) and Visibility.is_public?(object) and
         Federator.allowed_thread_distance?(depth) and same_origin?(object_id, collection_id) do
      refresh_schedule()
      |> Enum.with_index()
      |> Enum.each(fn {delay, refresh_index} ->
        enqueue_refresh(object_id, collection_id, depth, refresh_index, delay)
      end)
    end

    :ok
  end

  def enqueue_for_object(_, _), do: :ok

  def enqueue_for_reply_ancestors(%Object{} = object, depth) do
    if enabled?() and not Object.local?(object) and Visibility.is_public?(object) do
      object
      |> reply_ancestors(triggered_refresh_ancestor_depth(), depth)
      |> Enum.each(fn
        {%Object{data: %{"id" => object_id, "replies_collection" => collection_id}} = object,
         depth} ->
          if is_binary(collection_id) and not Object.local?(object) and
               Visibility.is_public?(object) and
               Federator.allowed_thread_distance?(depth) and
               same_origin?(object_id, collection_id) do
            enqueue_refresh(
              object_id,
              collection_id,
              depth,
              @triggered_refresh_index,
              triggered_refresh_delay()
            )
          end

        _ ->
          :ok
      end)
    end

    :ok
  end

  def enqueue_for_reply_ancestors(_, _), do: :ok

  @impl true
  def perform(%Oban.Job{
        args: %{
          "op" => @op,
          "object_id" => object_id,
          "collection_id" => collection_id,
          "depth" => depth
        }
      }) do
    with {:parent, %Object{} = object} <- {:parent, Object.get_cached_by_ap_id(object_id)},
         {:local, false} <- {:local, Object.local?(object)},
         {:public, true} <- {:public, Visibility.is_public?(object)},
         {:collection, ^collection_id} <- {:collection, object.data["replies_collection"]},
         {:collection_origin, true} <-
           {:collection_origin, same_origin?(object_id, collection_id)},
         {:depth, true} <- {:depth, Federator.allowed_thread_distance?(depth)},
         {:ok, reply_ids} <- fetch_reply_ids(collection_id) do
      reply_ids
      |> Enum.reject(&Object.get_cached_by_ap_id/1)
      |> Enum.each(&enqueue_reply_fetch(&1, depth))

      :ok
    else
      {:parent, nil} -> {:cancel, :parent_not_found}
      {:local, true} -> {:cancel, :local}
      {:public, false} -> {:cancel, :not_public}
      {:collection, _} -> {:cancel, :collection_mismatch}
      {:collection_origin, false} -> {:cancel, :collection_origin}
      {:depth, false} -> {:cancel, :allowed_depth}
      {:error, reason} -> handle_fetch_error(reason)
      error -> {:cancel, error}
    end
  end

  defp fetch_reply_ids(collection_id) do
    opts = %{
      collection_id: collection_id,
      max_pages: max_pages(),
      max_items: max_items()
    }

    fetch_pages([collection_id], opts, [], MapSet.new(), 0)
  end

  defp fetch_pages(_page_ids, %{max_items: max_items}, reply_ids, _seen, _pages_seen)
       when length(reply_ids) >= max_items do
    {:ok, Enum.take(reply_ids, max_items)}
  end

  defp fetch_pages(_page_ids, %{max_pages: max_pages}, reply_ids, _seen, pages_seen)
       when pages_seen >= max_pages do
    {:ok, reply_ids}
  end

  defp fetch_pages([], _opts, reply_ids, _seen, _pages_seen), do: {:ok, reply_ids}

  defp fetch_pages([page_id | rest], opts, reply_ids, seen, pages_seen) do
    cond do
      MapSet.member?(seen, page_id) ->
        fetch_pages(rest, opts, reply_ids, seen, pages_seen)

      not same_origin?(opts.collection_id, page_id) ->
        fetch_pages(rest, opts, reply_ids, seen, pages_seen)

      true ->
        with {:ok, data} <- Fetcher.fetch_and_contain_remote_object_from_id(page_id) do
          remaining = opts.max_items - length(reply_ids)
          {page_reply_ids, next_page_ids} = parse_collection_page(data, remaining)

          reply_ids =
            (reply_ids ++ page_reply_ids)
            |> Enum.uniq()
            |> Enum.take(opts.max_items)

          fetch_pages(
            rest ++ Enum.filter(next_page_ids, &same_origin?(opts.collection_id, &1)),
            opts,
            reply_ids,
            MapSet.put(seen, page_id),
            pages_seen + 1
          )
        end
    end
  end

  defp parse_collection_page(_data, remaining) when remaining <= 0, do: {[], []}

  defp parse_collection_page(data, remaining) do
    first = data["first"]

    reply_ids = item_ids(data, remaining)
    remaining = remaining - length(reply_ids)

    first_reply_ids = if remaining > 0 and is_map(first), do: item_ids(first, remaining), else: []

    reply_ids = Enum.uniq(reply_ids ++ first_reply_ids)

    next_page_ids =
      []
      |> maybe_append_page_id(first)
      |> maybe_append_embedded_first_page_id(first)
      |> maybe_append_page_id(data["next"])
      |> maybe_append_page_id(if is_map(first), do: first["next"], else: nil)
      |> Enum.uniq()

    {reply_ids, next_page_ids}
  end

  defp item_ids(%{} = page, limit) do
    items = Map.get(page, "orderedItems", Map.get(page, "items", []))

    if is_list(items) do
      items
      |> Enum.take(limit)
      |> Enum.flat_map(&cast_item_id/1)
    else
      []
    end
  end

  defp item_ids(_, _), do: []

  defp cast_item_id(%{"id" => id}), do: cast_item_id(id)

  defp cast_item_id(id) when is_binary(id) do
    case ObjectID.cast(id) do
      {:ok, id} -> [id]
      :error -> []
    end
  end

  defp cast_item_id(_), do: []

  defp maybe_append_page_id(ids, id) when is_binary(id), do: ids ++ [id]
  defp maybe_append_page_id(ids, _), do: ids

  defp maybe_append_embedded_first_page_id(ids, %{"id" => id} = first) when is_binary(id) do
    if collection_items?(first), do: ids, else: ids ++ [id]
  end

  defp maybe_append_embedded_first_page_id(ids, _), do: ids

  defp collection_items?(%{} = page) do
    is_list(page["orderedItems"]) or is_list(page["items"])
  end

  defp enqueue_reply_fetch(reply_id, depth) do
    %{"op" => "fetch_remote", "id" => reply_id, "depth" => depth, "thread" => true}
    |> RemoteFetcherWorker.new()
    |> Oban.insert()
  end

  defp enqueue_refresh(object_id, collection_id, depth, refresh_index, delay) do
    opts =
      [scheduled_at: DateTime.add(DateTime.utc_now(), delay, :second)]
      |> Keyword.merge(replace_opts(refresh_index))

    %{
      "op" => @op,
      "object_id" => object_id,
      "collection_id" => collection_id,
      "depth" => depth,
      "refresh_index" => refresh_index
    }
    |> new(opts)
    |> Oban.insert()
  end

  defp replace_opts(@triggered_refresh_index), do: [replace: [scheduled: [:args, :scheduled_at]]]
  defp replace_opts(_), do: []

  defp reply_ancestors(%Object{} = object, limit, depth) when limit > 0 do
    object
    |> do_reply_ancestors(limit, max(depth, 1), MapSet.new([object.data["id"]]), [])
    |> Enum.reverse()
  end

  defp reply_ancestors(_, _, _), do: []

  defp do_reply_ancestors(_object, 0, _depth, _seen, acc), do: acc

  defp do_reply_ancestors(%Object{data: %{"inReplyTo" => parent_id}}, limit, depth, seen, acc)
       when is_binary(parent_id) do
    cond do
      MapSet.member?(seen, parent_id) ->
        acc

      parent = Object.get_by_ap_id(parent_id) ->
        next_depth = max(depth - 1, 1)

        do_reply_ancestors(
          parent,
          limit - 1,
          next_depth,
          MapSet.put(seen, parent_id),
          [{parent, depth} | acc]
        )

      true ->
        acc
    end
  end

  defp do_reply_ancestors(_, _limit, _depth, _seen, acc), do: acc

  defp enabled?, do: Keyword.get(refresh_config(), :enabled)

  defp refresh_schedule do
    refresh_config()
    |> Keyword.get(:schedule)
    |> List.wrap()
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
  end

  defp max_pages, do: positive_integer_config(:max_pages)
  defp max_items, do: positive_integer_config(:max_items)
  defp triggered_refresh_delay, do: non_negative_integer_config(:triggered_refresh_delay)

  defp triggered_refresh_ancestor_depth,
    do: non_negative_integer_config(:triggered_refresh_ancestor_depth)

  defp positive_integer_config(key) do
    value = Keyword.get(refresh_config(), key)

    if is_integer(value) and value > 0 do
      value
    else
      Keyword.fetch!(@default_config, key)
    end
  end

  defp non_negative_integer_config(key) do
    value = Keyword.get(refresh_config(), key)

    if is_integer(value) and value >= 0 do
      value
    else
      Keyword.fetch!(@default_config, key)
    end
  end

  defp refresh_config do
    configured = Config.get([:activitypub, :remote_replies_collection_refresh], [])

    configured =
      cond do
        is_map(configured) -> Map.to_list(configured)
        Keyword.keyword?(configured) -> configured
        true -> []
      end

    Keyword.merge(@default_config, configured)
  end

  defp handle_fetch_error(reason) when reason in [:forbidden, :not_found],
    do: {:cancel, reason}

  defp handle_fetch_error("Object has been deleted"), do: {:cancel, :not_found}
  defp handle_fetch_error({:http, code}) when code in [401, 403], do: {:cancel, :forbidden}
  defp handle_fetch_error({:http, code}) when code in [404, 410], do: {:cancel, :not_found}
  defp handle_fetch_error({:content_type, _} = reason), do: {:cancel, reason}
  defp handle_fetch_error(reason), do: {:error, reason}

  defp same_origin?(left, right) when is_binary(left) and is_binary(right) do
    left = URI.parse(left)
    right = URI.parse(right)

    is_binary(left.scheme) and is_binary(left.host) and is_binary(right.scheme) and
      is_binary(right.host) and left.scheme == right.scheme and
      String.downcase(left.host) == String.downcase(right.host) and
      uri_port(left) == uri_port(right)
  end

  defp same_origin?(_, _), do: false

  defp uri_port(%URI{port: nil, scheme: scheme}), do: URI.default_port(scheme)
  defp uri_port(%URI{port: port}), do: port
end
