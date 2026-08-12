# Unfathomably appendable ActivityPub collections
#
# File: appendable_collection.ex
#
# Purpose:
#   Implement secure owner-confirmed wall membership from FEP-400e.
#
# This file intentionally does not trust an object's target claim by itself.

defmodule Pleroma.Web.ActivityPub.AppendableCollection do
  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  require Pleroma.Constants

  @marker "_unfathomably_appendable_collection"
  @collection_types ["Collection", "OrderedCollection"]

  def enabled?, do: Config.get([__MODULE__, :enabled], true)

  def collection(%User{} = owner) do
    %{
      "id" => collection_id(owner),
      "type" => "OrderedCollection",
      "attributedTo" => owner.ap_id
    }
  end

  def collection_id(%User{ap_id: ap_id}), do: ap_id <> "/collections/wall"

  def authorized?(target, %User{} = actor, object) do
    with true <- enabled?(),
         target_id when is_binary(target_id) <- reference_id(target),
         true <- collection_owned_by_actor?(target_id, actor),
         object_id when is_binary(object_id) <- reference_id(object),
         %Object{} = entry <- Object.get_by_ap_id(object_id),
         true <- valid_target_claim?(entry.data["target"], target_id, actor.ap_id) do
      true
    else
      _ -> false
    end
  end

  def apply_change(type, target, %User{} = actor, object) when type in ["Add", "Remove"] do
    with true <- authorized?(target, actor, object),
         object_id when is_binary(object_id) <- reference_id(object),
         %Object{} = entry <- Object.get_by_ap_id(object_id) do
      apply_authorized_change(type, entry, reference_id(target), actor.ap_id)
    else
      _ -> {:error, :invalid_appendable_collection_change}
    end
  end

  def maybe_enqueue_confirmation(
        %{data: %{"type" => "Create", "actor" => creator}},
        %Object{data: %{"id" => object_id, "target" => target}}
      )
      when is_binary(creator) and is_binary(object_id) and is_map(target) do
    with true <- enabled?(),
         %{"id" => target_id, "type" => type} <- target,
         true <- type in @collection_types,
         owner_id when is_binary(owner_id) <- reference_id(target["attributedTo"]),
         %User{local: true} = owner <- User.get_cached_by_ap_id(owner_id),
         true <- target_id == collection_id(owner),
         true <- public_object?(object_id) do
      %{"object" => object_id, "owner" => owner.ap_id}
      |> Pleroma.Workers.AppendableCollectionWorker.new(schedule_in: 2)
      |> Oban.insert()

      :ok
    else
      _ -> :ok
    end
  end

  def maybe_enqueue_confirmation(_activity, _object), do: :ok

  def confirmation_owner(object_id, owner_id) do
    with true <- enabled?(),
         %User{local: true} = owner <- User.get_cached_by_ap_id(owner_id),
         %Object{data: %{"target" => target}} = object <- Object.get_by_ap_id(object_id),
         true <- valid_target_claim?(target, collection_id(owner), owner.ap_id),
         true <- public_object?(object_id) do
      {:ok, owner, object}
    else
      _ -> {:error, :invalid_appendable_collection_target}
    end
  end

  def items(%User{} = owner) do
    collection = collection_id(owner)

    Object
    |> where(
      [object],
      fragment("? \\? '_unfathomably_appendable_collection'", object.data)
    )
    |> where(
      [object],
      fragment(
        "?->'_unfathomably_appendable_collection'->>'collection' = ?",
        object.data,
        ^collection
      )
    )
    |> order_by([object], desc: object.id)
    |> limit(500)
    |> select([object], fragment("?->>'id'", object.data))
    |> Repo.all()
    |> Enum.filter(&is_binary/1)
  end

  defp apply_authorized_change("Add", object, collection, owner) do
    Object.update_data(object, %{@marker => %{"collection" => collection, "owner" => owner}})
  end

  defp apply_authorized_change("Remove", %Object{} = object, collection, owner) do
    case object.data[@marker] do
      %{"collection" => ^collection, "owner" => ^owner} ->
        object
        |> Object.change(%{data: Map.delete(object.data, @marker)})
        |> Object.update_and_set_cache()

      _ ->
        {:ok, object}
    end
  end

  defp collection_owned_by_actor?(target_id, %User{local: true} = actor),
    do: target_id == collection_id(actor)

  defp collection_owned_by_actor?(target_id, %User{ap_id: actor_id}) do
    case Object.get_by_ap_id(target_id) do
      %Object{data: %{"type" => type} = data} when type in @collection_types ->
        reference_id(data["attributedTo"]) == actor_id

      _ ->
        false
    end
  end

  defp valid_target_claim?(%{"id" => id, "type" => type} = target, id, owner)
       when type in @collection_types do
    reference_id(target["attributedTo"]) == owner
  end

  defp valid_target_claim?(_target, _id, _owner), do: false

  defp public_object?(object_id) do
    case Object.get_by_ap_id(object_id) do
      %Object{data: data} ->
        Pleroma.Constants.as_public() in List.wrap(data["to"]) or
          Pleroma.Constants.as_public() in List.wrap(data["cc"])

      _ ->
        false
    end
  end

  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(id) when is_binary(id), do: id
  defp reference_id([first | _rest]), do: reference_id(first)
  defp reference_id(_value), do: nil
end

# end of appendable_collection.ex
