# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.DeleteValidator do
  use Ecto.Schema

  alias Pleroma.Activity
  alias Pleroma.Activity.Queries
  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  import Ecto.Changeset
  import Ecto.Query
  import Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  @primary_key false

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        activity_fields()
      end
    end

    field(:deleted_activity_id, ObjectValidators.ObjectID)
  end

  def cast_data(data) do
    %__MODULE__{}
    |> cast(data, __schema__(:fields))
  end

  def add_deleted_activity_id(cng) do
    object =
      cng
      |> get_field(:object)

    case get_create_by_object_ap_id(object) do
      %Activity{id: id} -> put_change(cng, :deleted_activity_id, id)
      _ -> cng
    end
  end

  @deletable_object_types ~w{
    Answer
    Article
    Audio
    ChatMessage
    Event
    Note
    Page
    Question
    Video
  }

  defp validate_data(cng) do
    cng
    |> validate_required([:id, :type, :actor, :to, :cc, :object])
    |> validate_inclusion(:type, ["Delete"])
    |> validate_delete_actor(:actor)
    |> validate_modification_rights(:messages_delete)
    |> validate_delete_target()
    |> add_deleted_activity_id()
  end

  def do_not_federate?(cng) do
    !same_domain?(cng)
  end

  def cast_and_validate(data) do
    data
    |> cast_data
    |> validate_data
  end

  def classify_target(target, options \\ [])

  def classify_target(%{"object" => object_id}, options), do: classify_target(object_id, options)
  def classify_target(%{"type" => "Tombstone", "id" => object_id}, options),
    do: classify_tombstone_target(object_id, options)

  def classify_target(%{"id" => object_id}, options), do: classify_target(object_id, options)

  def classify_target(object_id, options) when is_binary(object_id) do
    case User.get_cached_by_ap_id(object_id) do
      %User{} = user ->
        %{state: :user, object_id: object_id, user: user}

      _ ->
        classify_object_target(object_id, options)
    end
  end

  def classify_target(object_id, _options), do: %{state: :missing, object_id: object_id}

  defp classify_tombstone_target(object_id, options) when is_binary(object_id) do
    case classify_object_target(object_id, options) do
      %{state: :missing} -> %{state: :remote_tombstone, object_id: object_id}
      target -> target
    end
  end

  defp classify_tombstone_target(object_id, _options) do
    %{state: :missing, object_id: object_id}
  end

  defp classify_object_target(object_id, options) do
    case Object.get_cached_by_ap_id(object_id) do
      %Object{data: %{"type" => "Tombstone"}} = object ->
        case get_latest_delete_by_object_ap_id(object_id, options[:ignore_activity_id]) do
          %Activity{} = existing_delete ->
            %{
              state: :tombstone_duplicate,
              object_id: object_id,
              object: object,
              existing_delete: existing_delete
            }

          _ ->
            %{state: :live_object, object_id: object_id, object: object}
        end

      %Object{data: %{"type" => type}} = object when type in @deletable_object_types ->
        %{state: :live_object, object_id: object_id, object: object}

      %Object{} = object ->
        %{state: :invalid_type, object_id: object_id, object: object}

      nil ->
        case get_create_by_object_ap_id(object_id) do
          %Activity{} = create_activity ->
            %{
              state: :pruned_object_with_create,
              object_id: object_id,
              create_activity: create_activity
            }

          _ ->
            %{state: :missing, object_id: object_id}
        end
    end
  end

  defp get_latest_delete_by_object_ap_id(object_id, ignored_activity_id) do
    query =
      Activity
      |> Queries.by_object_id(object_id)
      |> Queries.by_type("Delete")

    query =
      if ignored_activity_id do
        where(query, [activity], activity.id != ^ignored_activity_id)
      else
        query
      end

    query
    |> order_by([activity], desc: activity.id)
    |> limit(1)
    |> Repo.one()
  end

  defp get_create_by_object_ap_id(object_id) when is_binary(object_id) do
    Activity
    |> Queries.by_object_id(object_id)
    |> Queries.by_type("Create")
    |> order_by([activity], desc: activity.id)
    |> limit(1)
    |> Repo.one()
  end

  defp get_create_by_object_ap_id(_), do: nil

  defp validate_delete_target(cng) do
    params = cng.params || %{}

    delete_target =
      Map.get(params, "object", get_field(cng, :object))

    case classify_target(delete_target) do
      %{state: :missing} -> add_error(cng, :object, "can't find object")
      %{state: :invalid_type} -> add_error(cng, :object, "object not in allowed types")
      _ -> cng
    end
  end

  defp validate_delete_actor(cng, field_name) do
    validate_change(cng, field_name, fn field_name, actor ->
      case User.get_cached_by_ap_id(actor) do
        %User{} -> []
        _ -> [{field_name, "can't find user"}]
      end
    end)
  end
end
