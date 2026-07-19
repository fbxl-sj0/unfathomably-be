# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CustomObjectValidator do
  @moduledoc """
  Validates and preserves ActivityPub objects from unknown vocabularies.

  The validator deliberately keeps the decoded map instead of casting it into
  an Ecto embedded schema. Ecto casting would discard the very extension fields
  this path exists to retain. Validation therefore establishes a narrow trust
  boundary first: canonical HTTP identifiers, bounded structure, contained
  fetch provenance, and exact actor authority.

  This module intentionally does not dereference JSON-LD links. Collections and
  attachments remain inert data until a bounded, purpose-specific consumer
  explicitly requests them.
  """

  alias Pleroma.EctoType.ActivityPub.ObjectValidators.ObjectID
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CustomObject

  require Pleroma.Constants

  @default_max_bytes 1_000_000
  @default_max_depth 32
  @default_max_items 500
  @default_max_fields 500
  @maximum_identifier_bytes 4_096
  @maximum_type_bytes 512

  @spec validate(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(object, meta \\ [])

  def validate(%{} = object, meta) do
    object = normalize_object_addressing(object)

    with :ok <- validate_type(object),
         :ok <- validate_safety(object),
         :ok <- validate_provenance(object, meta) do
      {:ok, CustomObject.put_internal_metadata(object, local: meta[:local] == true)}
    end
  end

  def validate(_object, _meta), do: error(:not_an_object)

  @doc """
  Applies the identifier and bounded-JSON checks shared by unknown vocabularies.

  This function does not establish actor authority or vocabulary semantics.
  Callers must apply those checks for their own object or activity type.
  """
  @spec validate_safety(map()) :: :ok | {:error, term()}
  def validate_safety(%{} = value) do
    with :ok <- validate_identifier(value),
         :ok <- validate_encoded_size(value),
         :ok <- validate_structure(value) do
      :ok
    end
  end

  def validate_safety(_value), do: error(:not_an_object)

  @spec validate_create(map(), keyword()) :: {:ok, map(), keyword()} | {:error, term()}
  def validate_create(
        %{"type" => "Create", "actor" => actor, "object" => %{} = object} = activity,
        meta
      ) do
    object = inherit_missing_create_addressing(object, activity)
    object_meta = Keyword.put(meta, :activity_actor, actor)

    with :ok <- validate_activity_identifier(activity),
         :ok <- validate_actor(actor),
         :ok <- validate_actor_presence(actor),
         {:ok, object} <- validate(object, object_meta),
         :ok <- validate_create_containment(actor, object["id"]),
         {:ok, activity} <- normalize_create_addressing(activity, object),
         {:ok, activity} <- normalize_create_context(activity, object) do
      meta = Keyword.put(meta, :object_data, object)
      {:ok, activity, meta}
    end
  end

  def validate_create(_activity, _meta), do: error(:invalid_create)

  defp inherit_missing_create_addressing(object, activity) do
    if not Map.has_key?(object, "to") and not Map.has_key?(object, "cc") do
      object
      |> Map.put("to", recipient_list(activity["to"]))
      |> Map.put("cc", recipient_list(activity["cc"]))
    else
      object
    end
  end

  defp normalize_object_addressing(object) do
    Enum.reduce(~w[to cc bto bcc], object, fn field, normalized ->
      if Map.has_key?(normalized, field) do
        Map.put(normalized, field, recipient_list(normalized[field]))
      else
        normalized
      end
    end)
  end

  defp validate_type(%{"type" => type}) when is_binary(type) do
    cond do
      byte_size(type) == 0 -> error(:missing_type)
      byte_size(type) > @maximum_type_bytes -> error(:type_too_long)
      CustomObject.custom_type?(type) -> :ok
      true -> error(:not_a_custom_object)
    end
  end

  defp validate_type(_object), do: error(:missing_type)

  defp validate_identifier(%{"id" => id}) when is_binary(id) do
    cond do
      byte_size(id) > @maximum_identifier_bytes -> error(:identifier_too_long)
      match?({:ok, ^id}, ObjectID.cast(id)) -> :ok
      true -> error(:invalid_identifier)
    end
  end

  defp validate_identifier(_object), do: error(:missing_identifier)

  defp validate_activity_identifier(%{"id" => id}), do: validate_identifier(%{"id" => id})
  defp validate_activity_identifier(_activity), do: error(:missing_activity_identifier)

  defp validate_actor(actor) when is_binary(actor) do
    case ObjectID.cast(actor) do
      {:ok, ^actor} -> :ok
      _ -> error(:invalid_actor)
    end
  end

  defp validate_actor(_actor), do: error(:invalid_actor)

  defp validate_actor_presence(actor) do
    case User.get_cached_by_ap_id(actor) do
      %User{is_active: false} -> error(:inactive_actor)
      %User{} -> :ok
      _ -> error(:unknown_actor)
    end
  end

  defp validate_encoded_size(object) do
    max_bytes = configured_limit(:custom_object_max_bytes, @default_max_bytes)

    case Jason.encode(object) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes -> :ok
      {:ok, _encoded} -> error(:object_too_large)
      {:error, _reason} -> error(:invalid_json_value)
    end
  end

  defp validate_structure(object) do
    max_depth = configured_limit(:custom_object_max_depth, @default_max_depth)
    max_items = configured_limit(:custom_object_max_items, @default_max_items)
    max_fields = configured_limit(:custom_object_max_fields, @default_max_fields)

    walk_structure([{object, 0}], max_depth, max_items, max_fields)
  end

  defp walk_structure([], _max_depth, _max_items, _max_fields), do: :ok

  defp walk_structure([{_value, depth} | _rest], max_depth, _max_items, _max_fields)
       when depth > max_depth,
       do: error(:object_too_deep)

  defp walk_structure([{value, depth} | rest], max_depth, max_items, max_fields)
       when is_map(value) do
    if map_size(value) <= max_fields do
      children = Enum.map(value, fn {_key, child} -> {child, depth + 1} end)
      walk_structure(children ++ rest, max_depth, max_items, max_fields)
    else
      error(:too_many_object_fields)
    end
  end

  defp walk_structure([{value, depth} | rest], max_depth, max_items, max_fields)
       when is_list(value) do
    if list_within_limit?(value, max_items) do
      children = Enum.map(value, &{&1, depth + 1})
      walk_structure(children ++ rest, max_depth, max_items, max_fields)
    else
      error(:too_many_collection_items)
    end
  end

  defp walk_structure([_value | rest], max_depth, max_items, max_fields) do
    walk_structure(rest, max_depth, max_items, max_fields)
  end

  defp list_within_limit?(values, limit) do
    values
    |> Enum.reduce_while(0, fn _value, count ->
      if count < limit, do: {:cont, count + 1}, else: {:halt, :too_many}
    end)
    |> is_integer()
  end

  defp validate_provenance(object, meta) do
    actor = meta[:activity_actor]

    cond do
      is_binary(actor) and CustomObject.authorized?(object, actor) ->
        :ok

      is_binary(actor) ->
        error(:actor_not_authorized)

      meta[:local] == true ->
        :ok

      meta[:fetched_from] == object["id"] ->
        :ok

      true ->
        error(:missing_provenance)
    end
  end

  defp validate_create_containment(actor, object_id) do
    actor_uri = URI.parse(actor)
    object_uri = URI.parse(object_id)

    if is_binary(actor_uri.host) and actor_uri.host == object_uri.host do
      :ok
    else
      error(:object_actor_origin_mismatch)
    end
  rescue
    URI.Error -> error(:object_actor_origin_mismatch)
  end

  defp normalize_create_addressing(activity, object) do
    object_to = recipient_list(object["to"])
    object_cc = recipient_list(object["cc"])
    activity_to = recipient_list(activity["to"])
    activity_cc = recipient_list(activity["cc"])
    object_recipients = MapSet.new(object_to ++ object_cc)
    activity_recipients = MapSet.new(activity_to ++ activity_cc)

    activity_recipients =
      if MapSet.size(activity_recipients) == 0,
        do: object_recipients,
        else: activity_recipients

    added_recipients = MapSet.difference(activity_recipients, object_recipients)
    public? = MapSet.member?(object_recipients, Pleroma.Constants.as_public())

    valid? =
      if public? do
        MapSet.subset?(object_recipients, activity_recipients) and
          Enum.all?(added_recipients, &trusted_delivery_recipient?(&1, object))
      else
        MapSet.equal?(object_recipients, activity_recipients)
      end

    if valid? do
      {:ok,
       activity
       |> Map.put("to", object_to)
       |> Map.put("cc", object_cc)}
    else
      error(:addressing_mismatch)
    end
  end

  defp normalize_create_context(activity, object) do
    activity_context = reference_id(activity["context"])
    object_context = reference_id(object["context"])

    cond do
      is_binary(activity_context) and is_binary(object_context) and
          activity_context != object_context ->
        error(:context_mismatch)

      is_binary(object_context) ->
        {:ok, Map.put(activity, "context", object_context)}

      true ->
        {:ok, activity}
    end
  end

  defp trusted_delivery_recipient?(recipient, object) do
    local_actor?(recipient) or producer_collection?(recipient, object)
  end

  defp local_actor?(recipient) do
    match?(%User{local: true}, User.get_cached_by_ap_id(recipient))
  end

  defp producer_collection?(recipient, object) when is_binary(recipient) do
    producer_hosts =
      object
      |> CustomObject.authorities()
      |> Enum.map(&uri_host/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    recipient_host = uri_host(recipient)

    is_binary(recipient_host) and MapSet.member?(producer_hosts, recipient_host) and
      String.ends_with?(recipient, ["/followers", "/members"])
  end

  defp producer_collection?(_recipient, _object), do: false

  defp recipient_list(value) do
    value
    |> List.wrap()
    |> Enum.map(&reference_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp reference_id(value) when is_binary(value), do: normalize_public(value)
  defp reference_id(%{"id" => id}) when is_binary(id), do: normalize_public(id)
  defp reference_id(%{"href" => href}) when is_binary(href), do: normalize_public(href)
  defp reference_id(_value), do: nil

  defp normalize_public(value) when value in ["Public", "as:Public"],
    do: Pleroma.Constants.as_public()

  defp normalize_public(value), do: value

  defp uri_host(value) when is_binary(value) do
    value
    |> URI.parse()
    |> Map.get(:host)
  rescue
    URI.Error -> nil
  end

  defp uri_host(_value), do: nil

  defp configured_limit(key, default) do
    case Pleroma.Config.get([:activitypub, key], default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp error(reason), do: {:error, {:custom_object, reason}}
end

# end of lib/pleroma/web/activity_pub/object_validators/custom_object_validator.ex
