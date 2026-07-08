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
  @html_link_href_regex ~r/\bhref\s*=\s*["']([^"']+)["']/i
  @webfinger_handle_regex ~r/(?:^|[^\p{L}\p{N}_@])@([A-Za-z0-9_][A-Za-z0-9_.-]{0,80})@([A-Za-z0-9][A-Za-z0-9.-]{0,250})/u

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

  def put_attributed_groups(object) when is_map(object) do
    object
    |> attributed_to_group_ap_ids()
    |> then(&put_addressed_groups(object, &1))
  end

  def put_attributed_groups(object), do: object

  def put_mentioned_groups(object) when is_map(object) do
    group_ap_ids = mention_group_ap_ids(object) ++ content_group_ap_ids(object)

    put_addressed_groups(object, group_ap_ids)
  end

  def put_mentioned_groups(object), do: object

  def put_replied_to_groups(%{"inReplyTo" => in_reply_to} = object) do
    with reply_target when is_binary(reply_target) <- reply_target_id(in_reply_to),
         %Object{data: replied_to_object} <- Object.normalize(reply_target, fetch: false),
         [_ | _] = group_ap_ids <- addressed_group_ap_ids(replied_to_object) do
      put_addressed_groups(object, group_ap_ids)
    else
      _ -> object
    end
  end

  def put_replied_to_groups(object), do: object

  def filter_implicit_mention_ap_ids(ap_ids, object) when is_list(ap_ids) do
    Enum.reject(ap_ids, &suppress_implicit_mention_ap_id?(&1, object))
  end

  def filter_implicit_mention_ap_ids(_, _object), do: []

  def addressed_group_ap_ids(object) when is_map(object) do
    object
    |> group_context_ap_ids()
    |> Enum.filter(&group_actor_ap_id?/1)
    |> Enum.uniq()
  end

  def addressed_group_ap_ids(_), do: []

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
    |> Kernel.++(mention_group_ap_ids(object))
    |> Kernel.++(content_group_ap_ids(object))
    |> Kernel.++(actor_group_ap_ids(object))
    |> Kernel.++(attributed_to_group_ap_ids(object))
    |> Kernel.++(nested_object_group_ap_ids(object))
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

  defp mention_group_ap_ids(%{"tag" => tags}) when is_list(tags) do
    tags
    |> Enum.flat_map(&mention_group_ap_ids/1)
    |> Enum.uniq()
  end

  defp mention_group_ap_ids(%{"type" => "Mention"} = tag) do
    tag
    |> normalize_ap_ids()
    |> Enum.filter(&group_actor_ap_id?/1)
  end

  defp mention_group_ap_ids(_), do: []

  defp content_group_ap_ids(%{"content" => content}) when is_binary(content) do
    (content_link_group_ap_ids(content) ++ content_handle_group_ap_ids(content))
    |> Enum.uniq()
  end

  defp content_group_ap_ids(_), do: []

  defp content_link_group_ap_ids(content) do
    @html_link_href_regex
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&group_actor_ap_id?/1)
  end

  defp content_handle_group_ap_ids(content) do
    @webfinger_handle_regex
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.flat_map(fn [nickname, domain] -> group_ap_ids_by_handle(nickname, domain) end)
    |> Enum.uniq()
  end

  defp group_ap_ids_by_handle(nickname, domain) do
    ["#{nickname}@#{domain}", nickname]
    |> Enum.flat_map(&group_ap_ids_by_nickname/1)
    |> Enum.uniq()
  end

  defp group_ap_ids_by_nickname(nickname) do
    case User.get_by_nickname(nickname) do
      %User{actor_type: "Group", ap_id: ap_id} when is_binary(ap_id) -> [ap_id]
      _ -> []
    end
  end

  defp actor_group_ap_ids(%{"actor" => actor}) do
    actor
    |> normalize_ap_ids()
    |> Enum.filter(&group_actor_ap_id?/1)
  end

  defp actor_group_ap_ids(_), do: []

  defp attributed_to_group_ap_ids(%{"attributedTo" => attributed_to}) do
    attributed_to
    |> attributed_to_group_ap_ids()
  end

  defp attributed_to_group_ap_ids(values) when is_list(values) do
    values
    |> Enum.flat_map(&attributed_to_group_ap_ids/1)
    |> Enum.uniq()
  end

  defp attributed_to_group_ap_ids(%{"type" => "Group", "id" => id}) when is_binary(id) do
    [id]
  end

  defp attributed_to_group_ap_ids(value) when is_binary(value) do
    value
    |> normalize_ap_ids()
    |> Enum.filter(&group_actor_ap_id?/1)
  end

  defp attributed_to_group_ap_ids(%{} = value) do
    value
    |> normalize_ap_ids()
    |> Enum.filter(&group_actor_ap_id?/1)
  end

  defp attributed_to_group_ap_ids(_), do: []

  defp nested_object_group_ap_ids(%{"object" => object}) when is_map(object) do
    group_context_ap_ids(object)
  end

  defp nested_object_group_ap_ids(%{"object" => objects}) when is_list(objects) do
    Enum.flat_map(objects, &nested_object_group_ap_ids(%{"object" => &1}))
  end

  defp nested_object_group_ap_ids(_), do: []

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

  defp reply_target_id(value) when is_binary(value), do: value
  defp reply_target_id(%{"id" => id}) when is_binary(id), do: id
  defp reply_target_id(%{"href" => href}) when is_binary(href), do: href
  defp reply_target_id([value | _]), do: reply_target_id(value)
  defp reply_target_id(_), do: nil
end
