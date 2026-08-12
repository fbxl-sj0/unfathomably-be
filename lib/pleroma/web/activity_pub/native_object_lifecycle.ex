# Unfathomably BE
# ----------------
#
# File: native_object_lifecycle.ex
#
# Purpose:
#   Apply bounded lifecycle transitions to locally authored Worlds objects.
#
# Responsibilities:
#   - authorize transitions against the original local author
#   - limit each native family to meaningful, documented states
#   - publish changes through the normal ActivityPub Update pipeline
#   - include explicitly connected marketplace peers when listings change
#
# This file intentionally does not accept arbitrary object fields, mutate
# remote objects, or model protocol-specific actions that Unfathomably cannot
# perform honestly.

defmodule Pleroma.Web.ActivityPub.NativeObjectLifecycle do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.ActivityPub.Pipeline

  @native_family "https://unfathomably.social/ns#family"
  @native_kind "https://unfathomably.social/ns#kind"
  @native_namespace "https://unfathomably.social/ns#"

  @states %{
    "coordination" => ~w[open in_progress fulfilled closed],
    "games" => ~w[planned active complete abandoned],
    "markets" => ~w[available reserved sold withdrawn],
    "software" => ~w[open in_progress resolved closed],
    "software_project" => ~w[active maintenance archived]
  }

  @doc "Transitions an author-owned native object and emits ActivityPub Update."
  def transition(%User{} = user, status_id, requested_state)
      when is_binary(status_id) and is_binary(requested_state) do
    state = String.trim(requested_state)

    with %Activity{} = activity <- Activity.get_by_id_with_object(status_id),
         %Object{} = object <- Object.normalize(activity, fetch: false),
         :ok <- authorize(user, object),
         {:ok, family} <- native_family(object.data),
         :ok <- validate_state(family, state),
         {:ok, transitioned_activity} <-
           persist_and_publish(user, activity, object, family, state) do
      {:ok, transitioned_activity}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :transition_failed}
    end
  end

  def transition(_user, _status_id, _requested_state), do: {:error, :invalid_state}

  defp authorize(%User{ap_id: actor}, %Object{data: %{"actor" => actor}}), do: :ok
  defp authorize(_user, _object), do: {:error, :not_found}

  defp native_family(%{@native_family => "software", @native_kind => "software_project"}),
    do: {:ok, "software_project"}

  defp native_family(%{@native_family => family}) when is_binary(family) do
    if Map.has_key?(@states, family),
      do: {:ok, family},
      else: {:error, :unsupported_family}
  end

  defp native_family(_data), do: {:error, :unsupported_family}

  defp validate_state(family, state) do
    if state in Map.fetch!(@states, family), do: :ok, else: {:error, :invalid_state}
  end

  defp transitioned_object(data, "software_project", state) do
    data
    |> Map.put("projectStatus", state)
    |> Map.put(@native_namespace <> "project_status", state)
    |> put_updated()
  end

  defp transitioned_object(data, _family, state) do
    data
    |> Map.put("state", state)
    |> Map.put(@native_namespace <> "state", state)
    |> put_updated()
  end

  defp put_updated(data) do
    Map.put(
      data,
      "updated",
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    )
  end

  defp persist_and_publish(user, activity, object, family, state) do
    case Repo.transaction(fn ->
           with %Object{} = locked_object <- lock_object(object.id),
                :ok <- authorize(user, locked_object),
                {:ok, ^family} <- native_family(locked_object.data) do
             if current_state(locked_object.data, family) == state do
               current_activity(activity.id)
             else
               publish_transition(user, activity.id, locked_object, family, state)
             end
           else
             nil -> Repo.rollback(:not_found)
             {:error, reason} -> Repo.rollback(reason)
             other -> Repo.rollback({:transition_failed, other})
           end
         end) do
      {:ok, %Activity{} = transitioned_activity} -> {:ok, transitioned_activity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_object(object_id) do
    Object
    |> where([object], object.id == ^object_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp current_state(data, "software_project") do
    data["projectStatus"] || data[@native_namespace <> "project_status"]
  end

  defp current_state(data, _family) do
    data["state"] || data[@native_namespace <> "state"]
  end

  defp current_activity(activity_id) do
    case Activity.get_by_id_with_object(activity_id) do
      %Activity{} = activity -> activity
      _ -> Repo.rollback(:not_found)
    end
  end

  defp publish_transition(user, activity_id, object, family, state) do
    transitioned_data = transitioned_object(object.data, family, state)

    lifecycle_fields =
      Map.drop(transitioned_data, Map.keys(object.data) -- Map.keys(transitioned_data))

    with {:ok, updated_object} <- Object.update_data(object, lifecycle_fields),
         {:ok, update_data, meta} <- Builder.update(user, updated_object.data),
         {:ok, update_data} <- Marketplace.add_peer_recipients(update_data, updated_object.data),
         {:ok, _update_activity, _meta} <-
           Pipeline.common_pipeline(update_data, [local: true] ++ meta) do
      current_activity(activity_id)
    else
      {:error, reason} -> Repo.rollback(reason)
      other -> Repo.rollback({:transition_failed, other})
    end
  end
end

# end of lib/pleroma/web/activity_pub/native_object_lifecycle.ex
