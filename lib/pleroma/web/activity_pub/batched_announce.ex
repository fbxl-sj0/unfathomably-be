# Project: Unfathomably BE
# File: batched_announce.ex
# Purpose: Safely expand multi-object ActivityPub Announce activities.
# Responsibilities: Bound batch size, verify group audience, and derive stable item IDs.
# This file intentionally does not verify signatures or process inner activities.

defmodule Pleroma.Web.ActivityPub.BatchedAnnounce do
  @moduledoc """
  Expands the multi-object Announce representation emitted by PieFed.

  HTTP signature verification applies to the original outer activity. Every
  expanded item therefore retains that activity's actor and addressing, while
  the normal federation pipeline remains responsible for validating and
  authorizing the embedded activity itself.
  """

  @max_items 100

  @spec expand(map()) :: {:ok, [map()]} | {:error, :invalid_batched_announce}
  def expand(
        %{
          "type" => "Announce",
          "id" => activity_id,
          "actor" => actor,
          "object" => objects
        } = activity
      )
      when is_binary(activity_id) and is_binary(actor) and is_list(objects) do
    with true <- http_url?(activity_id),
         true <- http_url?(actor),
         {items, []} when items != [] <- Enum.split(objects, @max_items),
         true <- Enum.all?(items, &valid_item?(&1, actor)),
         true <- unique_item_ids?(items) do
      {:ok,
       Enum.map(items, fn item ->
         activity
         |> Map.put("id", item_activity_id(activity_id, item["id"]))
         |> Map.put("object", item)
       end)}
    else
      _ -> {:error, :invalid_batched_announce}
    end
  end

  def expand(_activity), do: {:error, :invalid_batched_announce}

  defp valid_item?(%{"id" => id, "type" => type} = item, actor)
       when is_binary(id) and is_binary(type) do
    http_url?(id) and actor in List.wrap(item["audience"])
  end

  defp valid_item?(_item, _actor), do: false

  defp unique_item_ids?(items) do
    ids = Enum.map(items, & &1["id"])
    MapSet.size(MapSet.new(ids)) == length(ids)
  end

  defp item_activity_id(activity_id, item_id) do
    fragment =
      item_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> then(&("batch-" <> &1))

    activity_id
    |> URI.parse()
    |> Map.put(:fragment, fragment)
    |> URI.to_string()
  end

  defp http_url?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end
end

# end of batched_announce.ex
