# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Pipeline do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Utils
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.MRF
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.SideEffects
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.Federator

  defp side_effects, do: Config.get([:pipeline, :side_effects], SideEffects)
  defp federator, do: Config.get([:pipeline, :federator], Federator)
  defp object_validator, do: Config.get([:pipeline, :object_validator], ObjectValidator)
  defp mrf, do: Config.get([:pipeline, :mrf], MRF)
  defp activity_pub, do: Config.get([:pipeline, :activity_pub], ActivityPub)
  defp config, do: Config.get([:pipeline, :config], Config)

  @type results :: {:ok, Activity.t() | Object.t(), keyword()}
  @type errors :: {:error | :reject, any()}

  # Repo.transaction wraps successful transaction results in {:ok, _}. It only
  # returns {:error, _} directly when the SQL transaction itself fails.
  @spec common_pipeline(map(), keyword()) :: results() | errors()
  def common_pipeline(object, meta) do
    case Repo.transaction(fn -> do_common_pipeline(object, meta) end, Utils.query_timeout()) do
      {:ok, {:ok, activity, meta}} ->
        clean_meta =
          meta
          |> Keyword.delete(:allow_untimestamped_update)
          |> Keyword.delete(:reused_create_activity_update)
          |> side_effects().handle_after_transaction()
          |> Keyword.delete(:object_cache_refreshes)

        {:ok, activity, clean_meta}

      {:ok, {:error, _} = error} ->
        error

      {:ok, {:reject, _} = error} ->
        error

      {:error, e} ->
        {:error, e}
    end
  end

  def do_common_pipeline(%{__struct__: _}, _meta), do: {:error, :is_struct}

  def do_common_pipeline(message, meta) do
    with {_, {:ok, message, meta}} <- {:validate, object_validator().validate(message, meta)},
         {_, {:ok, message, meta}} <- {:mrf, mrf().pipeline_filter(message, meta)},
         {_, :ok} <- {:object_lock, maybe_lock_mutated_object(message, meta)},
         {_, :continue} <-
           {:reused_create_activity_update,
            maybe_handle_reused_create_activity_update(message, meta)},
         {_, :continue} <- {:idempotent_create, maybe_skip_idempotent_create(message, meta)},
         {_, :continue} <- {:idempotent_delete, maybe_skip_idempotent_delete(meta)},
         {_, {:ok, message, meta}} <- {:persist, activity_pub().persist(message, meta)},
         {_, {:ok, message, meta}} <-
           {:compatibility_upgrade, maybe_upgrade_persisted_object(message, meta)},
         {_, {:continue, meta}} <-
           {:persisted_duplicate, maybe_skip_persisted_duplicate(message, meta)},
         {_, {:ok, message, meta}} <- {:side_effects, side_effects().handle(message, meta)},
         {_, {:ok, _}} <- {:federation, maybe_federate(message, meta)} do
      {:ok, message, meta}
    else
      {:mrf, {:reject, message, _}} -> {:reject, message}
      {:idempotent_create, {:ok, activity, meta}} -> {:ok, activity, meta}
      {:idempotent_delete, {:ok, activity, meta}} -> {:ok, activity, meta}
      {:reused_create_activity_update, {:ok, activity, meta}} -> {:ok, activity, meta}
      {:reused_create_activity_update, {:error, _reason} = error} -> error
      {:persisted_duplicate, {:ok, activity, meta}} -> {:ok, activity, meta}
      e -> {:error, e}
    end
  end

  #
  # Flohmarkt 0.21 uses the same /activity identifier for a listing's Create
  # and every later Update.  Retaining the Create is important because it is
  # the canonical timeline activity, but the authenticated Update still has to
  # revise the listing object.  This compatibility path is deliberately bound
  # to Flohmarkt's exact identity, authority, audience, and timestamp shape.
  #
  defp maybe_handle_reused_create_activity_update(
         %{"actor" => actor, "id" => activity_id, "type" => "Update"} = message,
         meta
       )
       when is_binary(actor) and is_binary(activity_id) do
    if meta[:local] == false do
      with %{"id" => object_id} = incoming_object <- meta[:object_data],
           %Activity{} = activity <- Activity.get_by_ap_id_with_object(activity_id),
           %Object{} = stored_object <- Object.get_by_ap_id(object_id),
           true <-
             reused_flohmarkt_update?(activity, stored_object, incoming_object, message, actor),
           :ok <- lock_reused_update(object_id),
           %Activity{} = activity <- Activity.get_by_ap_id_with_object(activity_id),
           %Object{} = stored_object <- Object.get_by_ap_id(object_id),
           true <-
             reused_flohmarkt_update?(activity, stored_object, incoming_object, message, actor) do
        apply_reused_flohmarkt_update(activity, stored_object, incoming_object, message, meta)
      else
        {:error, _reason} = error -> error
        _not_flohmarkt_reuse -> :continue
      end
    else
      :continue
    end
  end

  defp maybe_handle_reused_create_activity_update(_message, _meta), do: :continue

  defp reused_flohmarkt_update?(activity, stored_object, incoming_object, message, actor) do
    object_id = incoming_object["id"]

    activity.local == false and
      activity.data["type"] == "Create" and
      activity.data["actor"] == actor and
      activity_object_id(activity.data["object"]) == object_id and
      message["id"] == object_id <> "/activity" and
      incoming_object["published"] == stored_object.data["published"] and
      Map.take(incoming_object, ["to", "cc"]) == Map.take(stored_object.data, ["to", "cc"]) and
      CustomObject.flohmarkt_listing?(stored_object.data) and
      CustomObject.flohmarkt_listing?(incoming_object) and
      CustomObject.authorized?(stored_object.data, actor) and
      CustomObject.authorized?(incoming_object, actor)
  end

  defp apply_reused_flohmarkt_update(
         activity,
         stored_object,
         incoming_object,
         message,
         meta
       ) do
    if CustomObject.same_flohmarkt_listing?(stored_object.data, incoming_object) do
      {:ok, activity, meta}
    else
      with {:ok, incoming_object} <-
             put_next_reused_update_timestamp(incoming_object, stored_object.data),
           update_message = Map.put(message, "object", incoming_object),
           transient_activity = %{activity | actor: message["actor"], data: update_message},
           update_meta =
             meta
             |> Keyword.put(:object_data, incoming_object)
             |> Keyword.put(:reused_create_activity_update, true),
           {:ok, _transient_activity, update_meta} <-
             side_effects().handle(transient_activity, update_meta) do
        {:ok, activity, update_meta}
      end
    end
  end

  defp lock_reused_update(object_id) do
    case Repo.query(
           "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
           [object_id],
           timeout: Utils.query_timeout()
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_next_reused_update_timestamp(incoming_object, stored_object) do
    timestamp = stored_object["updated"] || stored_object["published"]

    with timestamp when is_binary(timestamp) <- timestamp,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(timestamp) do
      next_timestamp = datetime |> DateTime.add(1, :microsecond) |> DateTime.to_iso8601()
      {:ok, Map.put(incoming_object, "updated", next_timestamp)}
    else
      _invalid_timestamp -> {:error, :invalid_reused_update_timestamp}
    end
  end

  defp activity_object_id(object_id) when is_binary(object_id), do: object_id
  defp activity_object_id(%{"id" => object_id}) when is_binary(object_id), do: object_id
  defp activity_object_id(_object), do: nil

  defp maybe_skip_idempotent_create(%{"type" => "Create"} = message, meta) do
    with %{"id" => object_id} = incoming_object <- meta[:object_data],
         %Activity{} = activity <- Activity.get_create_by_object_ap_id(object_id),
         {:ok, upgraded?} <-
           maybe_upgrade_compatibility_object(object_id, incoming_object, message["actor"]) do
      {:ok, activity, maybe_refresh_upgraded_object(meta, object_id, upgraded?)}
    else
      {:error, _} = error -> error
      _ -> :continue
    end
  end

  defp maybe_skip_idempotent_create(_message, _meta), do: :continue

  #
  # ActivityPub stores interaction aggregates and editable content in the same
  # object JSON column. Peers can send an Update while a local Like, reaction,
  # or Undo is changing those aggregates. Serialize every transaction that can
  # mutate an object so each side effect reloads the committed winner instead
  # of writing an older snapshot over it. The same lock also preserves the
  # compatibility/native Create race handling described below.
  #
  @object_mutation_types ~w[
    Add Announce Create Delete EmojiReact Join Leave Like Lock Remove Update
  ]

  defp maybe_lock_mutated_object(%{"type" => "Undo"} = message, meta) do
    message
    |> mutated_object_id(meta)
    |> lock_object_id()
  end

  defp maybe_lock_mutated_object(%{"type" => type} = message, meta)
       when type in @object_mutation_types do
    message
    |> mutated_object_id(meta)
    |> lock_object_id()
  end

  defp maybe_lock_mutated_object(_message, _meta), do: :ok

  defp mutated_object_id(%{"type" => type, "object" => object}, meta)
       when type in ["Create", "Update"] do
    object_id(meta[:object_data]) || object_id(object)
  end

  defp mutated_object_id(%{"type" => "Undo", "object" => activity_id}, _meta)
       when is_binary(activity_id) do
    case Activity.get_by_ap_id(activity_id) do
      %Activity{data: %{"object" => object}} -> object_id(object)
      _ -> nil
    end
  end

  defp mutated_object_id(%{"type" => "Undo", "object" => activity}, _meta)
       when is_map(activity) do
    object_id(activity["object"])
  end

  defp mutated_object_id(%{"object" => object}, _meta), do: object_id(object)
  defp mutated_object_id(_message, _meta), do: nil

  defp object_id(%{"id" => object_id}) when is_binary(object_id), do: object_id
  defp object_id(object_id) when is_binary(object_id), do: object_id
  defp object_id(_object), do: nil

  defp lock_object_id(object_id) when is_binary(object_id) do
    case Repo.query(
           "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
           [object_id],
           timeout: Utils.query_timeout()
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_object_id(_object_id), do: :ok

  defp maybe_upgrade_compatibility_object(object_id, incoming_object, actor) do
    with %Object{} = stored_object <- Object.get_by_ap_id(object_id),
         {:ok, _object, upgraded?} <-
           Object.Updater.do_custom_compatibility_upgrade(stored_object, incoming_object, actor) do
      {:ok, upgraded?}
    else
      nil -> {:ok, false}
      {:error, _} = error -> error
      _ -> {:ok, false}
    end
  end

  defp maybe_refresh_upgraded_object(meta, object_id, true) do
    object_ids = Keyword.get(meta, :object_cache_refreshes, [])
    Keyword.put(meta, :object_cache_refreshes, Enum.uniq([object_id | object_ids]))
  end

  defp maybe_refresh_upgraded_object(meta, _object_id, false), do: meta

  #
  # Compatibility and native forms can reach separate inbox workers at the
  # same time. Both workers may pass the pre-persistence idempotence check
  # before one transaction wins the activity and object uniqueness races.
  # The Create side effect persists its embedded object through this pipeline
  # again, so the upgrade must cover both the outer Activity and the Object
  # returned by that nested persistence operation.
  #
  defp maybe_upgrade_persisted_object(
         %Activity{data: %{"type" => "Create"} = data} = activity,
         meta
       ) do
    with %{"id" => object_id} = incoming_object <- meta[:object_data],
         {:ok, upgraded?} <-
           maybe_upgrade_compatibility_object(object_id, incoming_object, data["actor"]) do
      {:ok, activity, maybe_refresh_upgraded_object(meta, object_id, upgraded?)}
    else
      {:error, _} = error -> error
      _ -> {:ok, activity, meta}
    end
  end

  defp maybe_upgrade_persisted_object(%Object{} = object, meta) do
    with %{"id" => object_id} = incoming_object <- meta[:object_data],
         true <- object.data["id"] == object_id,
         actor when is_binary(actor) <- meta[:activity_actor],
         {:ok, upgraded_object, upgraded?} <-
           Object.Updater.do_custom_compatibility_upgrade(object, incoming_object, actor) do
      {:ok, upgraded_object, maybe_refresh_upgraded_object(meta, object_id, upgraded?)}
    else
      {:error, _} = error -> error
      _ -> {:ok, object, meta}
    end
  end

  defp maybe_upgrade_persisted_object(message, meta), do: {:ok, message, meta}

  defp maybe_skip_persisted_duplicate(%Activity{} = activity, meta) do
    clean_meta = Keyword.delete(meta, :activity_inserted)

    case meta[:activity_inserted] do
      false ->
        {:ok, activity, clean_meta}

      true ->
        {:continue, Keyword.put(clean_meta, :allow_untimestamped_update, true)}

      _ ->
        {:continue, clean_meta}
    end
  end

  defp maybe_skip_persisted_duplicate(_message, meta) do
    {:continue, Keyword.delete(meta, :activity_inserted)}
  end

  defp maybe_skip_idempotent_delete(meta) do
    case Keyword.get(meta, :delete_target) do
      %{state: :tombstone_duplicate, existing_delete: %Activity{} = activity} ->
        {:ok, activity, meta}

      _ ->
        :continue
    end
  end

  defp maybe_federate(%Object{}, _), do: {:ok, :not_federated}

  defp maybe_federate(%Activity{} = activity, meta) do
    with {:ok, local} <- Keyword.fetch(meta, :local) do
      do_not_federate = meta[:do_not_federate] || !config().get([:instance, :federating])

      if !do_not_federate and local and not Visibility.is_local_public?(activity) do
        activity =
          if object = Keyword.get(meta, :object_data) do
            %{activity | data: Map.put(activity.data, "object", object)}
          else
            activity
          end

        federator().publish(activity)
        {:ok, :federated}
      else
        {:ok, :not_federated}
      end
    else
      _e -> {:error, :badarg}
    end
  end
end
