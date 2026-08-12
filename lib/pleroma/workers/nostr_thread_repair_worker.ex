# Unfathomably BE
# ----------------
#
# File: workers/nostr_thread_repair_worker.ex
#
# Purpose:
#   Attach native Nostr reply projections to their ActivityPub thread after
#   the referenced parent event becomes locally available.
#
# Responsibilities:
#   - recognize NIP-10, NIP-22, and NIP-C7 reply references
#   - request bounded Nostr thread hydration when a parent is missing
#   - repair local ActivityPub object and activity context atomically
#
# This file intentionally does NOT crawl arbitrary relay conversations,
# publish repaired objects, or alter the immutable Nostr event.

defmodule Pleroma.Workers.NostrThreadRepairWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "background",
    max_attempts: 6,
    unique: [
      period: 300,
      states: :incomplete,
      keys: [:event_id]
    ]

  alias Pleroma.Activity
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Store
  alias Pleroma.Nostr.Thread
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Workers.NostrThreadFetchWorker

  @content_kinds [1, 9, 11, 1111, 30_023]
  @parent_kinds [
    1,
    9,
    11,
    20,
    21,
    22,
    1_068,
    1_111,
    1_311,
    30_023,
    30_311,
    31_922,
    31_923
  ]
  @max_waiting_children 100
  @parent_wait_seconds 5

  def enqueue_for_activity(%Activity{id: activity_id}) do
    case Store.get_by_ap_activity_id(activity_id) do
      %Event{} = event ->
        if repair_needed?(event) do
          enqueue_for_event(event)
        else
          :complete
        end

      _ ->
        :ignored
    end
  end

  def enqueue_for_activity(_activity), do: :ignored

  def enqueue_for_event(%Event{id: event_id, kind: kind} = event)
      when is_binary(event_id) and kind in @content_kinds do
    if Thread.reply_id(event) do
      case %{event_id: event_id} |> new() |> Oban.insert() do
        {:ok, %Job{conflict?: true, state: state}} -> hydration_state(state)
        {:ok, %Job{}} -> :scheduled
        _error -> :ignored
      end
    else
      :ignored
    end
  end

  def enqueue_for_event(_event), do: :ignored

  def enqueue_waiting_children(%Event{id: parent_event_id, kind: kind})
      when is_binary(parent_event_id) and kind in @parent_kinds do
    e_children =
      Store.query([
        %{
          "#e" => [parent_event_id],
          "kinds" => @content_kinds,
          "limit" => @max_waiting_children
        }
      ])

    q_children =
      if kind == 9 do
        Store.query([
          %{
            "#q" => [parent_event_id],
            "kinds" => [9],
            "limit" => @max_waiting_children
          }
        ])
      else
        []
      end

    (e_children ++ q_children)
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&(Thread.reply_id(&1) == parent_event_id))
    |> Enum.each(&enqueue_for_event/1)

    :ok
  end

  def enqueue_waiting_children(_event), do: :ok

  @impl Oban.Worker
  def perform(%Job{args: %{"event_id" => event_id}, attempt: attempt}) do
    case Store.get(event_id) do
      %Event{} = event -> repair_or_hydrate(event, attempt)
      _ -> {:cancel, :event_not_found}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  defp repair_or_hydrate(%Event{} = event, attempt) do
    case Thread.reply_id(event) do
      nil ->
        {:cancel, :not_a_reply}

      parent_event_id ->
        case Store.get(parent_event_id) do
          %Event{ap_activity_id: parent_activity_id} when is_binary(parent_activity_id) ->
            repair_projection(event, parent_activity_id)

          %Event{} = parent ->
            reproject_parent(event, parent, attempt)

          nil ->
            wait_for_parent(event, attempt)
        end
    end
  end

  defp reproject_parent(event, parent, attempt) do
    case Bridge.ingest_event(parent.data, parent.relay_url, :relay) do
      {:ok, _event} ->
        case Store.get(parent.id) do
          %Event{ap_activity_id: parent_activity_id} when is_binary(parent_activity_id) ->
            repair_projection(event, parent_activity_id)

          _parent ->
            wait_for_parent(event, attempt)
        end

      _result ->
        wait_for_parent(event, attempt)
    end
  end

  defp wait_for_parent(event, attempt) do
    request_parent(event)

    if attempt < 6 do
      {:snooze, @parent_wait_seconds}
    else
      {:cancel, :parent_unavailable}
    end
  end

  defp request_parent(%Event{ap_activity_id: activity_id}) when is_binary(activity_id) do
    case Activity.get_by_id(activity_id) do
      %Activity{} = activity -> NostrThreadFetchWorker.enqueue_for_activity(activity)
      _ -> :ignored
    end
  end

  defp request_parent(_event), do: :ignored

  defp repair_needed?(%Event{} = event) do
    with parent_event_id when is_binary(parent_event_id) <- Thread.reply_id(event),
         %Event{ap_activity_id: parent_activity_id} when is_binary(parent_activity_id) <-
           Store.get(parent_event_id),
         %Activity{} = activity <- Activity.get_by_id(event.ap_activity_id),
         %Activity{} = parent_activity <- Activity.get_by_id(parent_activity_id),
         %Object{} = object <- Object.normalize(activity, fetch: false),
         %Object{} = parent_object <- Object.normalize(parent_activity, fetch: false),
         parent_object_id when is_binary(parent_object_id) <- parent_object.data["id"] do
      object.data["inReplyTo"] != parent_object_id
    else
      nil -> false
      _unavailable -> true
    end
  end

  defp hydration_state("completed"), do: :complete
  defp hydration_state(state) when state in ["cancelled", "discarded"], do: :unavailable
  defp hydration_state(_state), do: :pending

  defp repair_projection(%Event{ap_activity_id: activity_id} = event, parent_activity_id)
       when is_binary(activity_id) do
    with %Activity{} = activity <- Activity.get_by_id(activity_id),
         %Activity{} = parent_activity <- Activity.get_by_id(parent_activity_id),
         %Object{} = object <- Object.normalize(activity, fetch: false),
         %Object{} = parent_object <- Object.normalize(parent_activity, fetch: false),
         parent_object_id when is_binary(parent_object_id) <- parent_object.data["id"] do
      previous_parent_id = object.data["inReplyTo"]

      parent_context =
        parent_activity.data["context"] || parent_object.data["context"] || parent_object_id

      activity_data = Map.put(activity.data, "context", parent_context)

      object_data =
        object.data
        |> Map.put("inReplyTo", parent_object_id)
        |> Map.put("context", parent_context)

      if activity_data == activity.data and object_data == object.data do
        :ok
      else
        Ecto.Multi.new()
        |> Ecto.Multi.update(:activity, Ecto.Changeset.change(activity, data: activity_data))
        |> Ecto.Multi.update(:object, Object.change(object, %{data: object_data}))
        |> Repo.transaction()
        |> case do
          {:ok, %{activity: repaired_activity, object: repaired_object}} ->
            refresh_projection_caches(repaired_activity, repaired_object)
            update_reply_counts(previous_parent_id, parent_object_id)
            enqueue_waiting_children(event)
            :ok

          {:error, operation, reason, _changes} ->
            {:error, {operation, reason}}
        end
      end
    else
      _ -> {:cancel, :projection_unavailable}
    end
  end

  defp repair_projection(_event, _parent_activity_id), do: {:cancel, :projection_unavailable}

  defp refresh_projection_caches(%Activity{} = activity, %Object{} = object) do
    # Object.normalize/2 serves projections from object_cache. Updating the
    # database alone leaves the old inReplyTo link visible until that cache
    # expires, which makes a successfully repaired thread still look broken.
    _ = Object.invalid_object_cache(object)
    _ = Object.set_cache(object)
    _ = Pleroma.Activity.HTML.invalidate_cache_for(object.id)
    _ = Pleroma.Activity.HTML.invalidate_cache_for(activity.id)
    :ok
  end

  defp update_reply_counts(parent_object_id, parent_object_id), do: :ok

  defp update_reply_counts(previous_parent_id, parent_object_id) do
    if is_binary(previous_parent_id) do
      Object.decrease_replies_count(previous_parent_id)
    end

    Object.increase_replies_count(parent_object_id)
    :ok
  end
end

# end of workers/nostr_thread_repair_worker.ex
