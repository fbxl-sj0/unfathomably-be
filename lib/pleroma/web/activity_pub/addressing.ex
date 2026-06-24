# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Addressing do
  @moduledoc """
  Helpers for separating delivery addresses from human-visible mentions.

  ActivityPub uses the same `to` and `cc` fields for several jobs: delivery,
  audience description, and sometimes mention discovery.  Group software tends
  to put communities in those fields as an audience, not as a person the author
  typed into the post.  These helpers keep generated mention tags and Mastodon
  API mention lists from turning audience addresses into visible mentions.
  """

  alias Pleroma.Object
  alias Pleroma.User

  @internal_group_key "addressed_groups"

  def put_addressed_groups(object, group_ap_ids) do
    group_ap_ids = normalize_ap_ids(group_ap_ids)

    case group_ap_ids do
      [] ->
        object

      [_ | _] ->
        object
        |> put_audience(group_ap_ids)
        |> put_internal_group_context(group_ap_ids)
    end
  end

  def filter_implicit_mention_ap_ids(ap_ids, object) when is_list(ap_ids) do
    Enum.reject(ap_ids, &suppress_implicit_mention_ap_id?(&1, object))
  end

  def filter_implicit_mention_ap_ids(_, _object), do: []

  def group_addressing_context?(object) when is_map(object) do
    object
    |> group_context_ap_ids()
    |> Enum.any?(&group_actor_ap_id?/1)
  end

  def group_addressing_context?(_), do: false

  def suppress_implicit_mention_user?(%User{actor_type: "Group"}, _object), do: true

  def suppress_implicit_mention_user?(%User{ap_id: ap_id}, object) when is_binary(ap_id) do
    group_reply_context?(object) and ap_id == replied_to_actor(object)
  end

  def suppress_implicit_mention_user?(_, _), do: false

  defp suppress_implicit_mention_ap_id?(ap_id, object) when is_binary(ap_id) do
    case User.get_cached_by_ap_id(ap_id) do
      %User{} = user -> suppress_implicit_mention_user?(user, object)
      _ -> false
    end
  end

  defp suppress_implicit_mention_ap_id?(_, _), do: false

  defp put_audience(object, [group_ap_id]) do
    Map.put(object, "audience", group_ap_id)
  end

  defp put_audience(object, group_ap_ids) do
    Map.put(object, "audience", group_ap_ids)
  end

  defp put_internal_group_context(object, group_ap_ids) do
    internal =
      object
      |> Map.get("pleroma_internal", %{})
      |> Map.put(@internal_group_key, group_ap_ids)

    Map.put(object, "pleroma_internal", internal)
  end

  defp group_reply_context?(%{"inReplyTo" => in_reply_to} = object)
       when is_binary(in_reply_to) do
    group_addressing_context?(object)
  end

  defp group_reply_context?(_), do: false

  defp group_context_ap_ids(object) do
    object
    |> internal_group_ap_ids()
    |> Kernel.++(audience_ap_ids(object))
    |> Kernel.++(recipient_group_ap_ids(object))
    |> Kernel.++(actor_group_ap_ids(object))
    |> Enum.uniq()
  end

  defp internal_group_ap_ids(%{"pleroma_internal" => %{@internal_group_key => ap_ids}}) do
    normalize_ap_ids(ap_ids)
  end

  defp internal_group_ap_ids(_), do: []

  defp audience_ap_ids(%{"audience" => audience}) do
    normalize_ap_ids(audience)
  end

  defp audience_ap_ids(_), do: []

  defp recipient_group_ap_ids(%{} = object) do
    (normalize_ap_ids(object["to"]) ++ normalize_ap_ids(object["cc"]))
    |> Enum.filter(&group_actor_ap_id?/1)
  end

  defp recipient_group_ap_ids(_), do: []

  defp actor_group_ap_ids(%{"actor" => actor}) do
    actor
    |> normalize_ap_ids()
    |> Enum.filter(&group_actor_ap_id?/1)
  end

  defp actor_group_ap_ids(_), do: []

  defp group_actor_ap_id?(ap_id) when is_binary(ap_id) do
    case User.get_cached_by_ap_id(ap_id) do
      %User{actor_type: "Group"} -> true
      _ -> false
    end
  end

  defp group_actor_ap_id?(_), do: false

  defp replied_to_actor(%{"inReplyTo" => in_reply_to}) when is_binary(in_reply_to) do
    with %Object{data: %{"actor" => actor}} <- Object.normalize(in_reply_to, fetch: false) do
      actor
    else
      _ -> nil
    end
  end

  defp replied_to_actor(_), do: nil

  defp normalize_ap_ids(values) when is_list(values) do
    values
    |> Enum.flat_map(&normalize_ap_ids/1)
    |> Enum.uniq()
  end

  defp normalize_ap_ids(value) when is_binary(value) do
    [value]
  end

  defp normalize_ap_ids(%{"id" => id}) when is_binary(id), do: [id]
  defp normalize_ap_ids(%{"href" => href}) when is_binary(href), do: [href]
  defp normalize_ap_ids(_), do: []
end
