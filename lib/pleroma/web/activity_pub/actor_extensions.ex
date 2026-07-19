# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ActorExtensions do
  @moduledoc """
  Preserves bounded JSON-LD properties that are not part of the User schema.

  Some applications expose domain objects as followable actors. Manyfold, for
  example, represents a model as a Service actor and identifies its native
  meaning with `f3di:concreteType`. Keeping only the ActivityStreams actor type
  would lose the distinction between a user, creator, collection, and 3D model.

  The stored map never replaces normalized identity, addressing, key, or
  profile fields. Those fields remain owned by the User schema. Extension
  collections are merged back into actor output only after the normalized
  actor has been rendered, with normalized values taking precedence.

  This module intentionally does not dereference contexts, previews,
  attachments, collections, or other linked resources.
  """

  alias Pleroma.Web.ActivityPub.ObjectValidators.CustomObjectValidator

  @mapped_actor_fields ~w[
    id type preferredUsername name summary inbox outbox followers following
    featured publicKey endpoints icon image manuallyApprovesFollowers
    capabilities alsoKnownAs copiedTo webfinger published updated url
    discoverable indexable invisible postingRestrictedToMods _misskey_summary
    vcard:bday vcard:Address bto bcc
  ]

  @maximum_merged_items 64

  @spec extract(map()) :: map()
  def extract(%{} = actor) do
    with :ok <- CustomObjectValidator.validate_safety(actor) do
      actor
      |> Map.drop(@mapped_actor_fields)
      |> retain_unmapped_items("attachment", "PropertyValue")
      |> retain_unmapped_items("tag", "Emoji")
      |> reject_empty_values()
    else
      _error -> %{}
    end
  end

  def extract(_actor), do: %{}

  @spec valid?(term()) :: boolean()
  def valid?(%{} = extensions) do
    synthetic_actor = %{
      "id" => "https://unfathomably.invalid/actor-extensions",
      "extensions" => extensions
    }

    CustomObjectValidator.validate_safety(synthetic_actor) == :ok
  end

  def valid?(_extensions), do: false

  @doc "Merges preserved extensions into normalized actor JSON without replacing trusted fields."
  @spec merge_into_actor(map(), map()) :: map()
  def merge_into_actor(%{} = actor, %{} = extensions) do
    if valid?(extensions) do
      extensions
      |> Map.merge(actor)
      |> merge_collection_field("attachment", actor, extensions)
      |> merge_collection_field("tag", actor, extensions)
      |> merge_context(actor, extensions)
    else
      actor
    end
  end

  def merge_into_actor(actor, _extensions), do: actor

  @doc "Returns bounded actor metadata suitable for Mastodon API clients."
  @spec presentation(map(), String.t()) :: map() | nil
  def presentation(%{} = extensions, canonical_id) when is_binary(canonical_id) do
    case concrete_type(extensions) do
      type when is_binary(type) ->
        %{
          canonical_id: canonical_id,
          class: presentation_class(type),
          context: first_reference(extensions["context"]),
          controls: ["open"],
          fields: presentation_fields(extensions),
          type: type
        }

      _other ->
        nil
    end
  end

  def presentation(_extensions, _canonical_id), do: nil

  @spec concrete_type(map()) :: String.t() | nil
  def concrete_type(%{} = extensions) do
    case extensions["f3di:concreteType"] || extensions["concreteType"] do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  def concrete_type(_extensions), do: nil

  defp retain_unmapped_items(actor, field, mapped_type) do
    items =
      actor
      |> Map.get(field, [])
      |> List.wrap()
      |> Enum.filter(fn
        %{"type" => type} when type != mapped_type -> true
        _item -> false
      end)
      |> Enum.take(@maximum_merged_items)

    if items == [], do: Map.delete(actor, field), else: Map.put(actor, field, items)
  end

  defp reject_empty_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] or value == %{} end)
    |> Map.new()
  end

  defp merge_collection_field(result, field, actor, extensions) do
    values =
      List.wrap(actor[field])
      |> Kernel.++(List.wrap(extensions[field]))
      |> Enum.uniq()
      |> Enum.take(@maximum_merged_items)

    if values == [], do: Map.delete(result, field), else: Map.put(result, field, values)
  end

  defp merge_context(result, actor, extensions) do
    contexts =
      List.wrap(extensions["@context"])
      |> Kernel.++(List.wrap(actor["@context"]))
      |> Enum.uniq()
      |> Enum.take(@maximum_merged_items)

    case contexts do
      [] -> Map.delete(result, "@context")
      [context] -> Map.put(result, "@context", context)
      contexts -> Map.put(result, "@context", contexts)
    end
  end

  defp presentation_class("Collection"), do: "collection"
  defp presentation_class(_type), do: "resource"

  defp presentation_fields(extensions) do
    %{}
    |> put_scalar(:sensitive, extensions["sensitive"])
    |> put_scalar(:indexable, extensions["indexable"])
    |> put_scalar(:discoverable, extensions["discoverable"])
    |> put_references(:attributed_to, extensions["attributedTo"])
    |> put_references(:collections, extensions["context"])
    |> put_references(:attribution_domains, extensions["attributionDomains"])
    |> put_license(extensions["spdx:license"])
    |> put_preview(extensions["preview"])
  end

  defp put_scalar(fields, key, value)
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: Map.put(fields, key, value)

  defp put_scalar(fields, _key, _value), do: fields

  defp put_references(fields, key, value) do
    references = reference_ids(value)
    if references == [], do: fields, else: Map.put(fields, key, references)
  end

  defp put_license(fields, %{} = license) do
    value = license["spdx:licenseId"] || license["id"] || license["@id"]
    put_scalar(fields, :license, value)
  end

  defp put_license(fields, value), do: put_scalar(fields, :license, value)

  defp put_preview(fields, value) do
    case first_reference(value) do
      nil -> fields
      preview -> Map.put(fields, :preview, preview)
    end
  end

  defp first_reference(value) do
    value
    |> reference_ids()
    |> List.first()
  end

  defp reference_ids(values) when is_list(values) do
    values
    |> Enum.flat_map(&reference_ids/1)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp reference_ids(value) when is_binary(value), do: [value]
  defp reference_ids(%{"id" => id}) when is_binary(id), do: [id]
  defp reference_ids(%{"@id" => id}) when is_binary(id), do: [id]
  defp reference_ids(%{"href" => href}) when is_binary(href), do: [href]
  defp reference_ids(%{"url" => url}) when is_binary(url), do: [url]
  defp reference_ids(_value), do: []
end

# end of lib/pleroma/web/activity_pub/actor_extensions.ex
