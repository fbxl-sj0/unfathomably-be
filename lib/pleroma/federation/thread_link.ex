# Unfathomably BE
# ----------------
#
# File: federation/thread_link.ex
#
# Purpose:
#   Attach a bridge-projected reply to a parent that became available later.
#
# Responsibilities:
#   - update ActivityPub reply and context fields atomically
#   - invalidate the object cache after linkage changes
#   - keep parent reply counters correct when an orphan is repaired
#
# This file intentionally does NOT resolve protocol-native identifiers, fetch
# remote threads, or publish repaired projections back to federation peers.

defmodule Pleroma.Federation.ThreadLink do
  alias Ecto.Multi
  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Repo

  @spec repair(Activity.t(), Activity.t()) :: {:ok, Activity.t()} | {:error, term()}
  def repair(%Activity{} = reply_activity, %Activity{} = parent_activity) do
    with %Object{} = reply_object <- Object.normalize(reply_activity, fetch: false),
         %Object{} = parent_object <- Object.normalize(parent_activity, fetch: false),
         parent_object_id when is_binary(parent_object_id) <- parent_object.data["id"] do
      context =
        parent_object.data["context"] || parent_activity.data["context"] || parent_object_id

      previous_parent_id = reply_object.data["inReplyTo"]

      object_data =
        reply_object.data
        |> Map.put("inReplyTo", parent_object_id)
        |> Map.put("context", context)

      activity_data = Map.put(reply_activity.data, "context", context)

      if object_data == reply_object.data and activity_data == reply_activity.data do
        {:ok, reply_activity}
      else
        persist_repair(
          reply_activity,
          reply_object,
          activity_data,
          object_data,
          previous_parent_id,
          parent_object_id
        )
      end
    else
      nil -> {:error, :projection_not_found}
      _ -> {:error, :parent_object_id_not_found}
    end
  end

  def repair(_, _), do: {:error, :invalid_thread_link}

  defp persist_repair(
         reply_activity,
         reply_object,
         activity_data,
         object_data,
         previous_parent_id,
         parent_object_id
       ) do
    Multi.new()
    |> Multi.update(:object, Ecto.Changeset.change(reply_object, data: object_data))
    |> Multi.update(:activity, Ecto.Changeset.change(reply_activity, data: activity_data))
    |> Repo.transaction()
    |> case do
      {:ok, %{activity: repaired_activity, object: repaired_object}} ->
        refresh_object_cache(repaired_object)
        update_reply_counts(previous_parent_id, parent_object_id)
        {:ok, repaired_activity}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp refresh_object_cache(%Object{} = object) do
    _ = Object.invalid_object_cache(object)
    _ = Object.set_cache(object)
    :ok
  end

  defp update_reply_counts(parent_object_id, parent_object_id), do: :ok

  defp update_reply_counts(previous_parent_id, parent_object_id) do
    if is_binary(previous_parent_id) do
      Object.decrease_replies_count(previous_parent_id)
    end

    Object.increase_replies_count(parent_object_id)
  end
end

# end of federation/thread_link.ex
