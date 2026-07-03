# Pleroma: A lightweight social networking server
# Copyright Ã‚Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Activity.Ir.Topics do
  import Ecto.Query, only: [select: 3, where: 3]

  alias Pleroma.FollowingRelationship
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.FederatedTarget

  def get_activity_topics(activity) do
    activity
    |> Object.normalize(fetch: false)
    |> generate_topics(activity)
    |> List.flatten()
  end

  defp generate_topics(%{data: %{"type" => "ChatMessage"}}, %{data: %{"type" => "Delete"}}) do
    ["user", "user:pleroma_chat"]
  end

  defp generate_topics(%{data: %{"type" => "ChatMessage"}}, %{data: %{"type" => "Create"}}) do
    []
  end

  defp generate_topics(%{data: %{"type" => "Answer"}}, _) do
    []
  end

  defp generate_topics(object, activity) do
    ["user", "list"] ++
      federated_target_tags(object, activity) ++ visibility_tags(object, activity)
  end

  defp federated_target_tags(object, activity) do
    if Visibility.get_visibility(activity) in ["public", "local"] do
      target_tags = source_tags(activity) ++ group_tags(object, activity)

      target_tags ++ aggregate_federated_target_tags(target_tags, object)
    else
      []
    end
  end

  defp source_tags(%{actor: actor}) when is_binary(actor) do
    case User.get_cached_by_ap_id(actor) do
      %User{id: id} = user ->
        if FederatedTarget.source?(user), do: ["source:" <> to_string(id)], else: []

      _ ->
        []
    end
  end

  defp source_tags(_), do: []

  defp aggregate_federated_target_tags(target_tags, object) do
    if discussion_root?(object) do
      do_aggregate_federated_target_tags(target_tags)
    else
      []
    end
  end

  defp do_aggregate_federated_target_tags(target_tags) do
    target_tags
    |> Enum.flat_map(&aggregate_federated_target_tag/1)
    |> Enum.uniq()
  end

  defp discussion_root?(%{data: %{} = data}) do
    case Map.get(data, "inReplyTo") do
      nil -> true
      "" -> true
      [] -> true
      _ -> false
    end
  end

  defp discussion_root?(_), do: false

  defp aggregate_federated_target_tag("group:" <> id) do
    aggregate_followed_target_tags(id, "user:groups")
  end

  defp aggregate_federated_target_tag("source:" <> id) do
    aggregate_followed_target_tags(id, "user:sources")
  end

  defp aggregate_federated_target_tag(_topic), do: []

  defp aggregate_followed_target_tags(id, stream_prefix) do
    case User.get_cached_by_id(id) do
      %User{} = target ->
        target
        |> local_follower_ids()
        |> Enum.map(fn user_id -> "#{stream_prefix}:#{user_id}" end)

      _ ->
        []
    end
  end

  defp local_follower_ids(%User{} = target) do
    target
    |> FollowingRelationship.followers_query()
    |> where([_r, u], u.local == true and u.is_active == true)
    |> select([_r, u], u.id)
    |> Repo.all()
  end

  defp group_tags(object, activity) do
    object
    |> federated_target_recipients(activity)
    |> Enum.uniq()
    |> Enum.flat_map(fn ap_id ->
      case User.get_cached_by_ap_id(ap_id) do
        %User{id: id} = user ->
          if FederatedTarget.group?(user), do: ["group:" <> to_string(id)], else: []

        _ ->
          []
      end
    end)
  end

  defp federated_target_recipients(object, activity) do
    activity_data = activity_data(activity)
    object_data = object_data(object)

    []
    |> add_recipients(activity_recipients(activity))
    |> add_recipients(Map.get(activity_data, "to"))
    |> add_recipients(Map.get(activity_data, "cc"))
    |> add_recipients(Map.get(object_data, "to"))
    |> add_recipients(Map.get(object_data, "cc"))
    |> Enum.filter(&is_binary/1)
  end

  defp activity_recipients(%{recipients: recipients}), do: recipients
  defp activity_recipients(_), do: []

  defp activity_data(%{data: data}) when is_map(data), do: data
  defp activity_data(_), do: %{}

  defp object_data(%{data: data}) when is_map(data), do: data
  defp object_data(_), do: %{}

  defp add_recipients(recipients, values) when is_list(values), do: recipients ++ values
  defp add_recipients(recipients, value) when is_binary(value), do: [value | recipients]
  defp add_recipients(recipients, _), do: recipients

  defp visibility_tags(object, %{data: %{"type" => type}} = activity) when type != "Announce" do
    case Visibility.get_visibility(activity) do
      "public" ->
        if activity.local do
          ["public", "public:local"]
        else
          ["public"]
        end
        |> item_creation_tags(object, activity)

      "local" ->
        ["public:local"]
        |> item_creation_tags(object, activity)

      "direct" ->
        ["direct"]

      _ ->
        []
    end
  end

  defp visibility_tags(_object, _activity) do
    []
  end

  defp item_creation_tags(tags, object, %{data: %{"type" => "Create"}} = activity) do
    tags ++
      remote_topics(activity) ++ hashtags_to_topics(object) ++ attachment_topics(object, activity)
  end

  defp item_creation_tags(tags, _, _) do
    tags
  end

  defp hashtags_to_topics(object) do
    object
    |> Object.hashtags()
    |> Enum.map(fn hashtag -> "hashtag:" <> hashtag end)
  end

  defp remote_topics(%{local: true}), do: []

  defp remote_topics(%{actor: actor}) when is_binary(actor) do
    case uri_host(actor) do
      host when is_binary(host) -> ["public:remote:" <> host]
      _ -> []
    end
  end

  defp remote_topics(_), do: []

  defp attachment_topics(%{data: %{"attachment" => []}}, _act), do: []

  defp attachment_topics(_object, %{local: true} = activity) do
    case Visibility.get_visibility(activity) do
      "public" ->
        ["public:media", "public:local:media"]

      "local" ->
        ["public:local:media"]

      _ ->
        []
    end
  end

  defp attachment_topics(_object, %{actor: actor}) when is_binary(actor) do
    case uri_host(actor) do
      host when is_binary(host) -> ["public:media", "public:remote:media:" <> host]
      _ -> ["public:media"]
    end
  end

  defp attachment_topics(_object, _act), do: ["public:media"]

  defp uri_host(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:host)
  rescue
    URI.Error -> nil
  end
end
