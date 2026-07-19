# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AcceptRejectValidator do
  use Ecto.Schema

  alias Pleroma.Activity
  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.CustomObject

  import Ecto.Changeset
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  @primary_key false

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        activity_fields()
      end
    end

    field(:result, ObjectValidators.ObjectID)
  end

  def cast_data(data) do
    %__MODULE__{}
    |> cast(data, __schema__(:fields))
  end

  defp validate_data(cng) do
    cng
    |> validate_required([:id, :type, :actor, :to, :object])
    |> validate_inclusion(:type, ["Accept", "Reject"])
    |> CommonValidations.validate_actor_presence()
    |> CommonValidations.validate_object_presence(
      allowed_types: ["Follow", "Join", "Offer", "QuoteRequest"]
    )
    |> validate_quote_result()
    |> validate_accept_reject_rights()
  end

  def cast_and_validate(data) do
    data
    |> cast_data
    |> validate_data
  end

  def validate_accept_reject_rights(cng) do
    with object_id when is_binary(object_id) <- get_field(cng, :object),
         %Activity{} = activity <- Activity.get_by_ap_id(object_id),
         true <- validate_actor(activity, get_field(cng, :actor)) do
      cng
    else
      _e ->
        cng
        |> add_error(:actor, "can't accept or reject the given activity")
    end
  end

  defp validate_actor(%Activity{data: %{"type" => "Follow", "object" => followed_actor}}, actor) do
    followed_actor == actor
  end

  defp validate_actor(%Activity{data: %{"type" => "Join", "object" => joined_event}}, actor) do
    with %Object{data: %{"actor" => event_author}} <- Object.get_cached_by_ap_id(joined_event) do
      event_author == actor
    else
      _ -> false
    end
  end

  defp validate_actor(%Activity{data: %{"type" => "QuoteRequest", "object" => target}}, actor) do
    with %Object{data: %{"actor" => quoted_actor}} <- Object.get_by_ap_id(target) do
      quoted_actor == actor
    else
      _ -> false
    end
  end

  defp validate_actor(%Activity{data: %{"type" => "Offer", "target" => target}}, actor) do
    with target_id when is_binary(target_id) <- object_id(target) do
      target_id == actor or
        with %Object{} = object <- Object.get_cached_by_ap_id(target_id) do
          CustomObject.authorized?(object.data, actor)
        else
          _ -> false
        end
    else
      _ -> false
    end
  end

  defp validate_actor(_, _), do: false

  defp validate_quote_result(changeset) do
    with "Accept" <- get_field(changeset, :type),
         object_id when is_binary(object_id) <- get_field(changeset, :object),
         %Activity{data: %{"type" => type}} when type in ["Offer", "QuoteRequest"] <-
           Activity.get_by_ap_id(object_id) do
      validate_required(changeset, [:result])
    else
      _ -> changeset
    end
  end

  defp object_id(value) when is_binary(value), do: value
  defp object_id(%{"id" => id}) when is_binary(id), do: id
  defp object_id(_value), do: nil
end
