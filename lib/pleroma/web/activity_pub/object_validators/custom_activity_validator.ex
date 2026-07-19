# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CustomActivityValidator do
  @moduledoc """
  Validates and preserves inert activities from extension vocabularies.

  The validator establishes actor, origin, addressing, and resource bounds. It
  deliberately does not follow links or execute vocabulary-specific side
  effects. A later target adapter may interpret a validated activity when it
  can prove the target's native state transition and capability rules.
  """

  alias Pleroma.Object
  alias Pleroma.Object.Containment
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CustomActivity
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.ObjectValidators.CustomObjectValidator

  require Pleroma.Constants

  @spec validate(map(), keyword()) :: {:ok, map(), keyword()} | {:error, term()}
  def validate(activity, meta \\ [])

  def validate(%{"id" => id, "type" => type, "actor" => actor} = activity, meta)
      when is_binary(id) and is_binary(type) and is_binary(actor) do
    with true <- CustomActivity.custom_activity_type?(type),
         :ok <- CustomObjectValidator.validate_safety(activity),
         :ok <- validate_actor(actor),
         :ok <- validate_origin(activity),
         {:ok, activity} <- normalize_addressing(activity),
         :ok <- validate_activity_shape(activity) do
      {:ok, CustomActivity.put_internal_metadata(activity), meta}
    else
      false -> error(:not_a_custom_activity)
      {:error, _reason} = error -> error
      _reason -> error(:invalid_activity)
    end
  end

  def validate(_activity, _meta), do: error(:invalid_activity)

  defp validate_actor(actor) do
    case User.get_cached_by_ap_id(actor) do
      %User{is_active: false} -> error(:inactive_actor)
      %User{} -> :ok
      _ -> error(:unknown_actor)
    end
  end

  defp validate_origin(activity) do
    case Containment.contain_origin(activity["id"], activity) do
      :ok -> :ok
      _ -> error(:activity_actor_origin_mismatch)
    end
  end

  defp normalize_addressing(activity) do
    to = recipient_list(activity["to"])
    cc = recipient_list(activity["cc"])

    if to == [] and cc == [] do
      error(:missing_recipients)
    else
      {:ok, activity |> Map.put("to", to) |> Map.put("cc", cc)}
    end
  end

  defp validate_activity_shape(%{"type" => type} = activity) do
    case CustomActivity.short_type(type) do
      "Push" -> validate_push(activity)
      "Grant" -> require_references(activity, ["context", "target"])
      "Revoke" -> require_value(activity, "object")
      "Invite" -> require_references(activity, ["object", "target"])
      "Edit" -> require_embedded_id(activity, "object")
      "Assign" -> require_reference(activity, "object")
      "Resolve" -> require_reference(activity, "object")
      "Apply" -> validate_apply(activity)
      "Offer" -> validate_offer(activity)
    end
  end

  defp validate_push(activity) do
    with :ok <- require_reference(activity, "attributedTo"),
         :ok <- require_forge_target(activity, "target"),
         %{"type" => collection_type} = collection <- activity["object"],
         true <- collection_type in ["Collection", "OrderedCollection"],
         true <- is_list(collection["items"]) or is_list(collection["orderedItems"]) do
      :ok
    else
      _ -> error(:invalid_push)
    end
  end

  defp validate_apply(activity) do
    with :ok <- require_reference(activity, "object"),
         :ok <- require_forge_target(activity, "target") do
      :ok
    end
  end

  defp validate_offer(activity) do
    with :ok <- require_forge_target(activity, "target"),
         %{"type" => type} = object <- activity["object"],
         true <- CustomObject.custom_type?(type),
         false <- Map.has_key?(object, "id"),
         :ok <- validate_offer_target(activity),
         :ok <- validate_offer_object(activity, object) do
      :ok
    else
      _ -> error(:invalid_offer)
    end
  end

  defp validate_offer_target(activity) do
    target = reference_id(activity["target"])
    recipients = recipient_list(activity["to"])

    if target in recipients do
      :ok
    else
      validate_offer_child_target(target, recipients)
    end
  end

  defp validate_offer_child_target(target, recipients) do
    case Object.get_cached_by_ap_id(target) do
      %Object{data: data} ->
        if Enum.any?(CustomObject.authorities(data), &(&1 in recipients)) do
          :ok
        else
          error(:offer_target_not_addressed)
        end

      _object ->
        error(:offer_target_not_addressed)
    end
  end

  defp validate_offer_object(activity, %{"type" => type} = object) do
    if CustomObject.short_type(type) == "Ticket" do
      validate_ticket_offer(activity, object)
    else
      :ok
    end
  end

  defp validate_ticket_offer(activity, object) do
    context = reference_id(object["context"])
    target = reference_id(activity["target"])

    with actor when is_binary(actor) <- activity["actor"],
         ^actor <- reference_id(object["attributedTo"]),
         summary when is_binary(summary) and byte_size(summary) > 0 <- object["summary"],
         content when is_binary(content) and byte_size(content) > 0 <- object["content"],
         true <- is_nil(context) or context == target do
      :ok
    else
      _ -> error(:invalid_ticket_offer)
    end
  end

  defp require_references(activity, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case require_reference(activity, field) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp require_reference(activity, field) do
    if is_binary(reference_id(activity[field])), do: :ok, else: error({:missing_reference, field})
  end

  defp require_embedded_id(activity, field) do
    case activity[field] do
      %{"id" => id} when is_binary(id) -> :ok
      _ -> error({:missing_embedded_id, field})
    end
  end

  defp require_forge_target(activity, field) do
    case activity[field] do
      value when is_binary(value) ->
        :ok

      %{"id" => id} when is_binary(id) ->
        :ok

      %{"type" => "Branch", "context" => context, "ref" => ref}
      when is_binary(context) and is_binary(ref) ->
        :ok

      _ ->
        error({:invalid_forge_target, field})
    end
  end

  defp require_value(activity, field) do
    if is_nil(activity[field]), do: error({:missing_value, field}), else: :ok
  end

  defp recipient_list(value) do
    value
    |> List.wrap()
    |> Enum.map(&reference_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_public/1)
    |> Enum.uniq()
  end

  defp reference_id(value) when is_binary(value), do: value
  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(%{"href" => href}) when is_binary(href), do: href
  defp reference_id(_value), do: nil

  defp normalize_public(value) when value in ["Public", "as:Public"],
    do: Pleroma.Constants.as_public()

  defp normalize_public(value), do: value

  defp error(reason), do: {:error, {:custom_activity, reason}}
end

# end of lib/pleroma/web/activity_pub/object_validators/custom_activity_validator.ex
