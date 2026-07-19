# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.CustomActivity do
  @moduledoc """
  Classifies supported activities from extension vocabularies.

  These activities describe remote domain events and processes. They must be
  stored as activities, not mistaken for status or resource objects. Ingestion
  is intentionally inert: this module does not apply capabilities, edit remote
  resources, fetch collection members, or claim that a local operation changed
  native state on the originating application.
  """

  alias Pleroma.Web.ActivityPub.CustomObject

  @activity_types ~w[
    Apply Assign Edit Grant Invite Offer Push Resolve Revoke
  ]

  @capability_types ~w[Grant Invite Revoke]

  # Mutual Aid uses Offer as a domain object, not as the ActivityStreams Offer
  # activity.  Keep these exact vocabulary terms on the custom-object path
  # while namespaced activity vocabularies continue to use short-name matching.
  @object_type_collisions ~w[
    maid:Offer
    https://mutual-aid.app/ns/core#Offer
  ]

  @spec custom_activity?(map()) :: boolean()
  def custom_activity?(%{"type" => type}), do: custom_activity_type?(type)
  def custom_activity?(_activity), do: false

  @spec custom_activity_type?(term()) :: boolean()
  def custom_activity_type?(type) when type in @object_type_collisions, do: false

  def custom_activity_type?(type) when is_binary(type) do
    short_type(type) in @activity_types
  end

  def custom_activity_type?(_type), do: false

  @spec class(map()) :: String.t()
  def class(%{"type" => type}) do
    if short_type(type) in @capability_types, do: "capability", else: "process"
  end

  def class(_activity), do: "process"

  @spec put_internal_metadata(map()) :: map()
  def put_internal_metadata(%{"id" => id, "type" => type, "actor" => actor} = activity) do
    metadata = %{
      "authority" => %{"write" => [actor]},
      "canonicalId" => id,
      "class" => class(activity),
      "context" => reference_id(activity["context"]),
      "type" => type
    }

    Map.put(activity, CustomObject.internal_field(), metadata)
  end

  def put_internal_metadata(activity), do: activity

  @doc "Returns bounded native metadata suitable for API and source-preview clients."
  @spec presentation(map()) :: map() | nil
  def presentation(%{} = activity) do
    if custom_activity?(activity) do
      %{
        canonical_id: activity["id"],
        class: class(activity),
        context: reference_id(activity["context"]),
        controls: ["open"],
        fields: presentation_fields(activity),
        type: activity["type"]
      }
    end
  end

  def presentation(_activity), do: nil

  @spec short_type(term()) :: String.t() | nil
  def short_type(type) when is_binary(type) do
    type
    |> String.split(["#", "/", ":"], trim: true)
    |> List.last()
  end

  def short_type(_type), do: nil

  defp reference_id(value) when is_binary(value), do: value
  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(_value), do: nil

  defp presentation_fields(activity) do
    %{}
    |> put_reference(:target, activity["target"])
    |> put_reference(:result, activity["result"])
    |> put_scalar(:hash_before, activity["hashBefore"])
    |> put_scalar(:hash_after, activity["hashAfter"])
  end

  defp put_reference(fields, key, value) do
    case reference_id(value) do
      nil -> fields
      reference -> Map.put(fields, key, reference)
    end
  end

  defp put_scalar(fields, key, value)
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: Map.put(fields, key, value)

  defp put_scalar(fields, _key, _value), do: fields
end

# end of lib/pleroma/web/activity_pub/custom_activity.ex
