# Pleroma: A lightweight social networking server
# Copyright Ã‚Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Activity.Ir.Topics do
  import Ecto.Query

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
      sources = source_users(activity)
      groups = group_users(object, activity)

      source_tags(sources) ++
        group_tags(groups) ++ aggregate_target_tags(object, activity, sources, groups)
    else
      []
    end
  end

  defp source_users(%{actor: actor}) when is_binary(actor) do
    case User.get_cached_by_ap_id(actor) do
      %User{} = user ->
        if FederatedTarget.source?(user), do: [user], else: []

      _ ->
        []
    end
  end

  defp source_users(_), do: []

  defp source_tags(sources) do
    Enum.map(sources, fn %User{id: id} -> "source:" <> to_string(id) end)
  end

  defp group_users(object, activity) do
    object
    |> federated_target_recipients(activity)
    |> Enum.uniq()
    |> Enum.flat_map(fn ap_id ->
      case User.get_cached_by_ap_id(ap_id) do
        %User{} = user ->
          if FederatedTarget.group?(user), do: [user], else: []

        _ ->
          []
      end
    end)
  end

  defp group_tags(groups) do
    Enum.map(groups, fn %User{id: id} -> "group:" <> to_string(id) end)
  end

  defp aggregate_target_tags(object, %{data: %{"type" => "Create"}}, sources, groups) do
    if root_object?(object) do
      source_follower_tags(sources, "user:sources") ++
        source_follower_tags(groups, "user:groups")
    else
      []
    end
  end

  defp aggregate_target_tags(_object, _activity, _sources, _groups), do: []

  defp root_object?(%{data: %{"inReplyTo" => in_reply_to}}) do
    in_reply_to in [nil, ""]
  end

  defp root_object?(_object), do: true

  defp source_follower_tags(targets, prefix) do
    targets
    |> Enum.flat_map(&local_follower_ids/1)
    |> Enum.uniq()
    |> Enum.map(fn id -> prefix <> ":" <> to_string(id) end)
  end

  defp local_follower_ids(%User{} = target) do
    target
    |> FollowingRelationship.followers_query()
    |> where([_r, u], u.local == true)
    |> select([_r, u], u.id)
    |> Repo.all()
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

  defp remote_topics(%{actor: actor}) do
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

  defp uri_host(uri) do
    if is_binary(uri) do
      uri
      |> URI.parse()
      |> Map.get(:host)
    end
  rescue
    URI.Error -> nil
  end
end
