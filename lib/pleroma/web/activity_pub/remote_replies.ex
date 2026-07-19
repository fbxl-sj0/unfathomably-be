# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.RemoteReplies do
  @moduledoc """
  Hydrates remote reply and context collections into local status context.

  Some ActivityPub servers publish replies as a collection URL instead of an
  inline list of object IDs.  Forum-like servers may also use the object's
  context as a topic collection.  The object validators intentionally drop
  collection objects because the stored status schema only accepts concrete
  object IDs.  This module fetches bounded pages of those collections at the
  points where doing so is useful: when a remote object is first fetched, and
  when a client opens a status context.
  """

  require Logger

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.Federator

  @max_reply_ids 40
  @max_collection_pages 2
  @max_parent_hops 8

  def fetch_for_activity(activity, opts \\ [])

  def fetch_for_activity(%Activity{} = activity, opts) do
    case Object.normalize(activity, fetch: false) do
      %Object{} = object -> fetch_for_object(object, opts)
      _ -> :ok
    end
  end

  def fetch_for_activity(_, _), do: :ok

  def fetch_for_object(object, opts \\ [])

  def fetch_for_object(%Object{} = object, opts) do
    depth = Keyword.get(opts, :depth, 0)
    fetch_depth = depth + 1

    if Federator.allowed_thread_distance?(fetch_depth) and not Object.local?(object) do
      reply_ids =
        object
        |> reply_ids_for_object(opts)
        |> Enum.take(@max_reply_ids)

      context_ids =
        object
        |> context_ids_for_object(opts)
        |> Enum.take(@max_reply_ids)

      maybe_store_reply_ids(object, reply_ids)

      [reply_ids, context_ids]
      |> List.flatten()
      |> uniq_reply_ids()
      |> Enum.each(&fetch_reply(&1, fetch_depth))
    end

    :ok
  end

  def fetch_for_object(_, _), do: :ok

  def fetch_thread_from_reply(reply_id, opts \\ [])

  def fetch_thread_from_reply(reply_id, opts) when is_binary(reply_id) do
    depth = Keyword.get(opts, :depth, 0)

    if Activity.get_create_by_object_ap_id(reply_id) do
      Fetcher.fetch_object_from_id(reply_id, opts)
    else
      case safe_fetch_remote_object(reply_id) do
        {:ok, %{} = data} ->
          fetch_reply_ancestors(data, depth, MapSet.new([reply_id]), @max_parent_hops)

          opts = Keyword.put(opts, :prefetched_data, data)
          Fetcher.fetch_object_from_id(reply_id, opts)

        {:ok, _invalid_data} ->
          {:error, :invalid_remote_object}

        error ->
          error
      end
    end
  end

  def fetch_thread_from_reply(reply_id, opts), do: Fetcher.fetch_object_from_id(reply_id, opts)

  def maybe_inline_reply_ids(data, opts \\ [])

  def maybe_inline_reply_ids(%{"object" => %{} = object} = data, opts) do
    Map.put(data, "object", maybe_inline_reply_ids(object, opts))
  end

  def maybe_inline_reply_ids(%{} = data, opts) do
    reply_ids =
      data
      |> reply_ids_from_data(opts)
      |> Enum.take(@max_reply_ids)

    if reply_ids == [] do
      data
    else
      Map.put(data, "replies", reply_ids)
    end
  end

  def maybe_inline_reply_ids(data, _), do: data

  defp reply_ids_for_object(%Object{data: %{"id" => parent_id} = data}, opts)
       when is_binary(parent_id) do
    stored_ids = reply_ids_from_data(data, opts)
    remote_ids = remote_reply_ids(parent_id, opts)

    [stored_ids, remote_ids]
    |> List.flatten()
    |> uniq_reply_ids()
  end

  defp reply_ids_for_object(_, _), do: []

  defp context_ids_for_object(%Object{data: %{"id" => object_id, "context" => context_id}}, opts)
       when is_binary(object_id) and is_binary(context_id) do
    with true <- http_url?(context_id),
         true <- same_origin?(context_id, object_id),
         true <- context_id != object_id,
         {:ok, %{"type" => type} = data} <- safe_fetch_remote_object(context_id),
         true <- collection_type?(type) do
      data
      |> collection_item_ids(context_id, opts)
      |> Enum.reject(&(&1 == object_id))
    else
      error ->
        if error not in [false, nil] do
          Logger.debug("Could not fetch remote context #{context_id}: #{inspect(error)}")
        end

        []
    end
  end

  defp context_ids_for_object(_, _), do: []

  defp remote_reply_ids(parent_id, opts) do
    with true <- http_url?(parent_id),
         {:ok, %{} = data} <- safe_fetch_remote_object(parent_id) do
      reply_ids_from_data(data, opts)
    else
      _ -> []
    end
  end

  defp reply_ids_from_data(%{} = data, opts) do
    data
    |> reply_collection()
    |> collection_item_ids(data["id"], opts)
    |> uniq_reply_ids()
  end

  defp reply_ids_from_data(_, _), do: []

  defp reply_collection(%{"replies" => replies}), do: replies
  defp reply_collection(%{"comments" => comments}), do: comments
  defp reply_collection(_), do: nil

  defp collection_item_ids(nil, _parent_id, _opts), do: []

  defp collection_item_ids(items, _parent_id, _opts) when is_list(items) do
    Enum.flat_map(items, &reply_item_ids/1)
  end

  defp collection_item_ids(collection_url, parent_id, opts)
       when is_binary(collection_url) do
    fetch_collection_page(collection_url, parent_id, opts)
  end

  defp collection_item_ids(%{} = collection, parent_id, opts) do
    items =
      collection["items"] ||
        collection["orderedItems"] ||
        []

    item_ids = collection_item_ids(items, parent_id, opts)

    item_ids =
      case item_ids do
        [] ->
          first_page =
            collection["first"] ||
              collection["current"]

          collection_item_ids(first_page, parent_id, opts)

        item_ids ->
          item_ids
      end

    next_ids =
      collection
      |> Map.get("next")
      |> collection_item_ids(parent_id, opts)

    item_ids ++ next_ids
  end

  defp collection_item_ids(_, _parent_id, _opts), do: []

  defp fetch_collection_page(collection_url, parent_id, opts) do
    pages_left = Keyword.get(opts, :remote_replies_pages_left, @max_collection_pages)

    if pages_left > 0 and same_origin?(collection_url, parent_id) do
      with {:ok, %{} = page} <- safe_fetch_remote_object(collection_url),
           type <- page["type"],
           true <- is_nil(type) or collection_type?(type) do
        opts = Keyword.put(opts, :remote_replies_pages_left, pages_left - 1)

        collection_item_ids(page, parent_id, opts)
      else
        error ->
          Logger.debug("Could not fetch remote replies #{collection_url}: #{inspect(error)}")
          []
      end
    else
      []
    end
  end

  defp collection_type?(type) do
    type in ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"]
  end

  defp reply_item_ids(%{"type" => "Create", "object" => object}), do: reply_item_ids(object)
  defp reply_item_ids(%{"object" => object}) when is_binary(object), do: [object]
  defp reply_item_ids(%{"object" => %{} = object}), do: reply_item_ids(object)
  defp reply_item_ids(%{"id" => id}) when is_binary(id), do: [id]
  defp reply_item_ids(id) when is_binary(id), do: [id]
  defp reply_item_ids(_), do: []

  defp maybe_store_reply_ids(_object, []), do: :ok

  defp maybe_store_reply_ids(%Object{data: data} = object, reply_ids) do
    stored_ids = reply_ids_from_data(data, [])
    merged_ids = uniq_reply_ids(stored_ids ++ reply_ids)

    if merged_ids == stored_ids do
      :ok
    else
      case Object.update_data(object, %{"replies" => merged_ids}) do
        {:ok, _object} ->
          :ok

        error ->
          Logger.debug("Could not store remote replies for #{data["id"]}: #{inspect(error)}")
      end
    end
  end

  defp fetch_reply(reply_id, depth) do
    if Activity.get_create_by_object_ap_id(reply_id) do
      :ok
    else
      case fetch_thread_from_reply(reply_id, depth: depth) do
        {:ok, _object} -> :ok
        error -> Logger.debug("Could not hydrate remote reply #{reply_id}: #{inspect(error)}")
      end
    end
  end

  defp fetch_reply_ancestors(_data, _depth, _seen, 0), do: :ok

  defp fetch_reply_ancestors(data, depth, seen, hops_left) do
    with true <- Federator.allowed_thread_distance?(depth),
         parent_id when is_binary(parent_id) <- in_reply_to_id(data),
         true <- http_url?(parent_id),
         false <- MapSet.member?(seen, parent_id),
         nil <- Object.get_cached_by_ap_id(parent_id),
         {:ok, %{} = parent_data} <- safe_fetch_remote_object(parent_id) do
      seen = MapSet.put(seen, parent_id)

      fetch_reply_ancestors(parent_data, depth, seen, hops_left - 1)

      case Fetcher.fetch_object_from_id(parent_id,
             depth: depth,
             prefetched_data: parent_data
           ) do
        {:ok, _object} ->
          :ok

        error ->
          Logger.debug("Could not hydrate remote reply ancestor #{parent_id}: #{inspect(error)}")
      end
    else
      _ -> :ok
    end
  end

  defp safe_fetch_remote_object(url) do
    Fetcher.fetch_and_contain_remote_object_from_id(url)
  rescue
    error ->
      Logger.debug("Could not fetch remote reply object #{url}: #{inspect(error)}")
      {:error, error}
  catch
    kind, error ->
      Logger.debug("Could not fetch remote reply object #{url}: #{inspect({kind, error})}")
      {:error, error}
  end

  defp in_reply_to_id(%{"type" => "Create", "object" => %{} = object}), do: in_reply_to_id(object)
  defp in_reply_to_id(%{"object" => %{} = object}), do: in_reply_to_id(object)
  defp in_reply_to_id(%{"inReplyTo" => %{"id" => id}}) when is_binary(id), do: id
  defp in_reply_to_id(%{"inReplyTo" => id}) when is_binary(id), do: id
  defp in_reply_to_id(_), do: nil

  defp uniq_reply_ids(reply_ids) do
    reply_ids
    |> Enum.filter(&http_url?/1)
    |> Enum.uniq()
  end

  defp http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  rescue
    URI.Error -> false
  end

  defp http_url?(_), do: false

  defp same_origin?(url, parent_url) when is_binary(url) and is_binary(parent_url) do
    left = URI.parse(url)
    right = URI.parse(parent_url)

    is_binary(left.scheme) and is_binary(left.host) and is_binary(right.scheme) and
      is_binary(right.host) and left.scheme == right.scheme and
      String.downcase(left.host) == String.downcase(right.host) and
      uri_port(left) == uri_port(right)
  rescue
    URI.Error -> false
  end

  defp same_origin?(_, _), do: false

  defp uri_port(%URI{port: nil, scheme: scheme}), do: URI.default_port(scheme)
  defp uri_port(%URI{port: port}), do: port
end
