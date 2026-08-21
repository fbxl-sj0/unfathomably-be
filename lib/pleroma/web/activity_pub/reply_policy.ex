# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ReplyPolicy do
  @moduledoc """
  Resolves the effective reply policy for an ActivityPub discussion subtree.

  A Lock applies below its target as well as directly to it. This module walks
  cached ancestors with explicit depth and cycle bounds so a reply to a child
  cannot bypass a lock on the root. Local group managers retain moderation
  authority through the existing membership model.

  This module does not fetch missing remote objects or mutate lock state.
  """

  alias Pleroma.Activity
  alias Pleroma.GroupMembership
  alias Pleroma.Object
  alias Pleroma.User

  @max_ancestor_depth 64
  @group_audience_fields ~w(audience to cc)

  @spec allowed?(
          Activity.t() | Object.t() | String.t() | map() | nil,
          User.t() | String.t() | nil
        ) ::
          :ok | {:error, :locked}
  def allowed?(parent, actor) do
    case locked_ancestor(parent, MapSet.new(), 0) do
      {:ok, nil} ->
        :ok

      {:ok, %Object{} = locked_object} ->
        if manager_override?(actor, locked_object), do: :ok, else: {:error, :locked}

      {:error, _reason} ->
        {:error, :locked}
    end
  end

  @spec open?(Object.t() | Activity.t() | nil) :: boolean()
  def open?(object_or_activity) do
    match?({:ok, nil}, locked_ancestor(object_or_activity, MapSet.new(), 0))
  end

  defp locked_ancestor(_reference, _visited, depth) when depth > @max_ancestor_depth,
    do: {:error, :maximum_depth}

  defp locked_ancestor(reference, visited, depth) do
    case normalize_object(reference) do
      nil ->
        {:ok, nil}

      %Object{data: data} = object ->
        object_id = reference_id(data["id"])

        cond do
          is_binary(object_id) and MapSet.member?(visited, object_id) ->
            {:error, :cycle}

          data["commentsEnabled"] == false ->
            {:ok, object}

          true ->
            visited = if is_binary(object_id), do: MapSet.put(visited, object_id), else: visited

            case reference_id(data["inReplyTo"]) do
              nil -> {:ok, nil}
              parent_id -> locked_ancestor(parent_id, visited, depth + 1)
            end
        end
    end
  end

  defp normalize_object(%Object{} = object), do: object
  defp normalize_object(%Activity{} = activity), do: Object.normalize(activity, fetch: false)

  defp normalize_object(reference) do
    case reference_id(reference) do
      id when is_binary(id) -> Object.get_cached_by_ap_id(id)
      _ -> nil
    end
  end

  defp manager_override?(actor_reference, %Object{} = locked_object) do
    with %User{} = actor <- normalize_actor(actor_reference) do
      locked_object
      |> group_candidate_ids()
      |> Enum.any?(fn group_id ->
        case User.get_cached_by_ap_id(group_id) do
          %User{actor_type: "Group", local: true} = group ->
            actor.ap_id == group.ap_id or GroupMembership.manager?(actor, group)

          %User{actor_type: "Group"} = group ->
            actor.ap_id == group.ap_id

          _ ->
            false
        end
      end)
    else
      _ -> false
    end
  end

  defp normalize_actor(%User{} = actor), do: actor

  defp normalize_actor(actor_id) when is_binary(actor_id),
    do: User.get_cached_by_ap_id(actor_id)

  defp normalize_actor(_actor), do: nil

  defp group_candidate_ids(%Object{data: data}) do
    @group_audience_fields
    |> Enum.flat_map(&reference_ids(Map.get(data, &1)))
    |> Enum.uniq()
  end

  defp reference_ids(values) when is_list(values), do: Enum.flat_map(values, &reference_ids/1)
  defp reference_ids(value), do: List.wrap(reference_id(value))

  defp reference_id(value) when is_binary(value) and value != "", do: value
  defp reference_id(%{"id" => value}) when is_binary(value) and value != "", do: value
  defp reference_id([value]), do: reference_id(value)
  defp reference_id(_value), do: nil
end

# end of lib/pleroma/web/activity_pub/reply_policy.ex
