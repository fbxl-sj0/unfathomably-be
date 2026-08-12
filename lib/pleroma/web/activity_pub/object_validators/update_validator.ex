# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.UpdateValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Object
  alias Pleroma.Object.Containment
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
      end
    end

    field(:actor, ObjectValidators.ObjectID)
    # In this case, we save the full object in this activity instead of just a
    # reference, so we can always see what was actually changed by this.
    field(:object, :map)
  end

  def cast_data(data) do
    %__MODULE__{}
    |> cast(data, __schema__(:fields))
  end

  defp validate_data(cng, meta) do
    cng
    |> validate_required([:id, :type, :actor, :to, :cc, :object])
    |> validate_inclusion(:type, ["Update"])
    |> CommonValidations.validate_actor_presence()
    |> validate_updating_rights(meta)
    |> validate_immutable_reply_target()
  end

  def cast_and_validate(data, meta \\ []) do
    data
    |> cast_data
    |> validate_data(meta)
  end

  def validate_updating_rights(cng, meta) do
    if meta[:local] do
      validate_updating_rights_local(cng)
    else
      validate_updating_rights_remote(cng)
    end
  end

  # For local Updates, verify the actor can edit the object.
  def validate_updating_rights_local(cng) do
    actor = get_field(cng, :actor)
    updated_object = get_field(cng, :object)

    if {:ok, actor} == ObjectValidators.ObjectID.cast(updated_object) do
      cng
    else
      with %User{} = user <- User.get_cached_by_ap_id(actor),
           {_, %Object{} = orig_object} <- {:object, Object.normalize(updated_object)},
           :ok <- Object.authorize_access(orig_object, user) do
        cng
      else
        _ ->
          add_error(cng, :object, "Can't be updated by this actor")
      end
    end
  end

  # For remote Updates, verify the Actor is the same.
  def validate_updating_rights_remote(cng) do
    with actor = get_field(cng, :actor),
         object = get_field(cng, :object),
         {:ok, object_id} <- ObjectValidators.ObjectID.cast(object),
         entity <-
           Object.normalize(object_id, fetch: false) || User.get_cached_by_ap_id(object_id) do
      case entity do
        %Object{data: %{"type" => "Tombstone"}} ->
          add_error(cng, :object, "Deleted object can't be updated")

        %Object{} ->
          authorized? =
            if CustomObject.custom_object?(entity.data) do
              CustomObject.authorized?(entity.data, actor) and
                CustomObject.authorized?(object, actor)
            else
              object_actor_matches?(entity.data, actor) and
                object_actor_matches?(object, actor)
            end

          if authorized? do
            cng
          else
            add_error(cng, :object, "Can't be updated by this actor")
          end

        %User{} ->
          if actor == entity.ap_id do
            cng
          else
            add_error(cng, :object, "Can't be updated by this actor")
          end

        nil ->
          validate_unknown_object_update(cng, actor, object)

        _ ->
          add_error(cng, :object, "Update is neither for Object or Actor")
      end
    else
      _e ->
        add_error(cng, :object, "Can't be updated by this actor")
    end
  end

  defp validate_unknown_object_update(cng, actor, %{} = object) do
    with true <-
           (CustomObject.custom_object?(object) and CustomObject.authorized?(object, actor)) or
             object_actor_matches?(object, actor),
         :ok <- validate_object_actor_origin(object, actor),
         true <- recent_unknown_update?(object) do
      cng
    else
      _ -> add_error(cng, :object, "Unknown or stale object can't be updated")
    end
  end

  defp validate_unknown_object_update(cng, _actor, _object) do
    add_error(cng, :object, "Unknown object can't be updated")
  end

  defp object_actor_matches?(object, actor) do
    [object["actor"] | List.wrap(object["attributedTo"])]
    |> Enum.any?(fn object_actor ->
      match?({:ok, ^actor}, ObjectValidators.ObjectID.cast(object_actor))
    end)
  end

  # An unknown object has no stored ownership record to consult. Requiring its
  # canonical identifier to remain on the signing actor's host prevents a
  # valid remote actor from claiming an object URL owned by another server.
  defp validate_object_actor_origin(%{"id" => object_id}, actor)
       when is_binary(object_id) and is_binary(actor) do
    Containment.contain_origin(object_id, %{"actor" => actor})
  end

  defp validate_object_actor_origin(_object, _actor), do: :error

  defp recent_unknown_update?(object) do
    timestamp = object["updated"] || object["published"]

    with timestamp when is_binary(timestamp) <- timestamp,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(timestamp),
         age <- DateTime.diff(DateTime.utc_now(), datetime, :second) do
      age >= -3600 and age <= 86_400
    else
      _ -> false
    end
  end

  # Moving an existing object to another parent changes conversation topology,
  # visibility assumptions, and notification context. It is not an edit, even
  # when the same actor still owns the object. Missing inReplyTo remains valid
  # for partial actor updates and for peers that omit unchanged properties.
  defp validate_immutable_reply_target(cng) do
    with object when is_map(object) <- get_field(cng, :object),
         true <- Map.has_key?(object, "inReplyTo"),
         {:ok, object_id} <- ObjectValidators.ObjectID.cast(object),
         %Object{} = original <- Object.normalize(object_id, fetch: false),
         false <- same_reply_target?(object["inReplyTo"], original.data["inReplyTo"]) do
      add_error(cng, :object, "inReplyTo can't be changed")
    else
      _ -> cng
    end
  end

  defp same_reply_target?(nil, nil), do: true

  defp same_reply_target?(incoming, original) do
    case {
      ObjectValidators.ObjectID.cast(incoming),
      ObjectValidators.ObjectID.cast(original)
    } do
      {{:ok, id}, {:ok, id}} -> true
      _ -> false
    end
  end
end
