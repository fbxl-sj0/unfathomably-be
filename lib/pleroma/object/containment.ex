# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Object.Containment do
  @moduledoc """
  This module contains some useful functions for containing objects to specific
  origins and determining those origins.  They previously lived in the
  ActivityPub `Transmogrifier` module.

  Object containment is an important step in validating remote objects to prevent
  spoofing, therefore removal of object containment functions is NOT recommended.
  """
  @actor_types ["Application", "Group", "Organization", "Person", "Service"]
  @preferred_array_actor_types ["Application", "Person", "Service"]

  def get_actor(%{"actor" => actor}) when is_binary(actor) do
    actor
  end

  def get_actor(%{"actor" => actor}) when is_list(actor) do
    actor_id(actor)
  end

  def get_actor(%{"actor" => %{"id" => id}}) when is_bitstring(id) do
    id
  end

  def get_actor(%{"actor" => nil, "attributedTo" => actor}) when not is_nil(actor) do
    get_actor(%{"actor" => actor})
  end

  def get_actor(%{"attributedTo" => actor}) do
    actor_id(actor)
  end

  def get_actor(%{"id" => id, "type" => type}) when is_binary(id) and type in @actor_types do
    id
  end

  def get_actor(_), do: nil

  def get_object(%{"object" => id}) when is_binary(id) do
    id
  end

  def get_object(%{"object" => %{"id" => id}}) when is_binary(id) do
    id
  end

  def get_object(_) do
    nil
  end

  defp compare_uris(%URI{host: host} = _id_uri, %URI{host: host} = _other_uri)
       when is_binary(host),
       do: :ok

  defp compare_uris(_id_uri, _other_uri), do: :error

  @doc """
  Checks that an imported AP object's actor matches the host it came from.
  """
  def contain_origin(id, %{"actor" => nil, "attributedTo" => actor} = params)
      when not is_nil(actor),
      do: contain_origin(id, Map.put(params, "actor", actor))

  def contain_origin(_id, %{"actor" => nil}), do: :error

  def contain_origin(id, %{"actor" => _actor} = params) do
    with actor when is_binary(actor) <- get_actor(params),
         {:ok, id_uri} <- parse_uri(id),
         {:ok, actor_uri} <- parse_uri(actor) do
      compare_uris(actor_uri, id_uri)
    else
      _ -> :error
    end
  end

  def contain_origin(id, %{"attributedTo" => actor} = params),
    do: contain_origin(id, Map.put(params, "actor", actor))

  def contain_origin(_id, _data), do: :error

  def contain_origin_from_id(id, %{"id" => other_id} = _params) when is_binary(other_id) do
    id_uri = URI.parse(id)
    other_uri = URI.parse(other_id)

    compare_uris(id_uri, other_uri)
  end

  # Mastodon pin activities don't have an id, so we check the object field, which will be pinned.
  def contain_origin_from_id(id, %{"object" => object}) when is_binary(object) do
    id_uri = URI.parse(id)
    object_uri = URI.parse(object)

    compare_uris(id_uri, object_uri)
  end

  def contain_origin_from_id(_id, _data), do: :error

  def contain_child(%{"object" => %{"id" => id, "attributedTo" => _} = object}),
    do: contain_origin(id, object)

  def contain_child(_), do: :ok

  defp actor_id(actor) when is_binary(actor), do: actor

  defp actor_id(%{"id" => id}) when is_binary(id), do: id

  defp actor_id([actor | _]) when is_binary(actor), do: actor

  defp actor_id(actors) when is_list(actors) do
    actor =
      Enum.find(actors, fn
        %{"type" => type, "id" => id} when is_binary(id) ->
          type in @preferred_array_actor_types

        _ ->
          false
      end) ||
        Enum.find(actors, fn
          %{"type" => type, "id" => id} when is_binary(id) ->
            type in @actor_types

          _ ->
            false
        end)

    actor_id(actor)
  end

  defp actor_id(_), do: nil

  defp parse_uri(uri) when is_binary(uri) do
    {:ok, URI.parse(uri)}
  rescue
    URI.Error -> :error
  end

  defp parse_uri(_), do: :error
end
