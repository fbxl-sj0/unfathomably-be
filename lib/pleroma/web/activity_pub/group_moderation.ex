# Unfathomably group federation
# ----------------------------
#
# This module publishes ActivityPub moderation activities for local groups.
# It intentionally does not decide whether an actor is allowed to moderate a
# group. HTTP controllers and membership code make that decision before
# calling into this module.

defmodule Pleroma.Web.ActivityPub.GroupModeration do
  @moduledoc """
  Publish group moderation decisions in the Threadiverse-compatible shape.

  Lemmy, MBin, PieFed, and similar group-oriented servers learn about
  moderators and bans from normal ActivityPub activities addressed to the
  community. The bare activity records the moderation action, while an
  Announce from the group actor broadcasts that action to community followers.

  This module only handles outbound local-group federation. Inbound handling
  for remote moderator collection changes lives in `Pleroma.Web.ActivityPub.SideEffects`.
  """

  alias Pleroma.FollowingRelationship
  alias Pleroma.Activity
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.Federator

  require Pleroma.Constants

  @public Pleroma.Constants.as_public()

  @type publish_result :: {:ok, Activity.t()} | {:error, term()} | :ok

  @doc """
  Publish that `account` is now a moderator of `group`.
  """
  @spec publish_moderator_add(User.t(), User.t(), User.t()) :: publish_result()
  def publish_moderator_add(actor, group, account) do
    bcc = direct_recipients(group, account)

    with :ok <- ensure_local_group(group),
         {:ok, activity} <-
           insert_and_publish(%{
             "type" => "Add",
             "id" => Utils.generate_activity_id(),
             "actor" => actor.ap_id,
             "to" => [@public],
             "cc" => [group.ap_id],
             "bcc" => bcc,
             "object" => account.ap_id,
             "target" => moderators_collection(group),
             "audience" => group.ap_id
           }),
         {:ok, _announce} <- announce_group_activity(group, activity) do
      {:ok, activity}
    end
  end

  @doc """
  Publish that `account` is no longer a moderator of `group`.
  """
  @spec publish_moderator_remove(User.t(), User.t(), User.t()) :: publish_result()
  def publish_moderator_remove(actor, group, account) do
    bcc = direct_recipients(group, account)

    with :ok <- ensure_local_group(group),
         {:ok, activity} <-
           insert_and_publish(%{
             "type" => "Remove",
             "id" => Utils.generate_activity_id(),
             "actor" => actor.ap_id,
             "to" => [@public],
             "cc" => [group.ap_id],
             "bcc" => bcc,
             "object" => account.ap_id,
             "target" => moderators_collection(group),
             "audience" => group.ap_id
           }),
         {:ok, _announce} <- announce_group_activity(group, activity) do
      {:ok, activity}
    end
  end

  @doc """
  Publish that `account` is banned from `group`.
  """
  @spec publish_group_ban(User.t(), User.t(), User.t(), keyword()) :: publish_result()
  def publish_group_ban(actor, group, account, opts \\ []) do
    with :ok <- ensure_local_group(group),
         data <- block_data(actor, group, account, opts),
         {:ok, activity} <- insert_and_publish(data),
         {:ok, _announce} <- announce_group_activity(group, activity) do
      {:ok, activity}
    end
  end

  @doc """
  Publish that a previous group ban for `account` has been undone.
  """
  @spec publish_group_unban(User.t(), User.t(), User.t(), keyword()) :: publish_result()
  def publish_group_unban(actor, group, account, opts \\ []) do
    with :ok <- ensure_local_group(group),
         block <- block_data(actor, group, account, opts),
         {:ok, activity} <-
           insert_and_publish(%{
             "type" => "Undo",
             "id" => Utils.generate_activity_id(),
             "actor" => actor.ap_id,
             "to" => [@public],
             "cc" => [group.ap_id],
             "bcc" => direct_recipients(group, account),
             "object" => block,
             "audience" => group.ap_id
           }),
         {:ok, _announce} <- announce_group_activity(group, activity) do
      {:ok, activity}
    end
  end

  defp block_data(actor, group, account, opts) do
    data = %{
      "type" => "Block",
      "id" => Utils.generate_activity_id(),
      "actor" => actor.ap_id,
      "to" => [@public],
      "cc" => [group.ap_id],
      "bcc" => direct_recipients(group, account),
      "object" => account.ap_id,
      "target" => group.ap_id,
      "audience" => group.ap_id,
      "removeData" => Keyword.get(opts, :remove_data, false)
    }

    data
    |> maybe_put("summary", Keyword.get(opts, :reason))
    |> maybe_put("endTime", Keyword.get(opts, :end_time))
  end

  defp announce_group_activity(group, activity) do
    insert_and_publish(%{
      "type" => "Announce",
      "id" => Utils.generate_activity_id(),
      "actor" => group.ap_id,
      "to" => [@public],
      "cc" => [group_followers(group)],
      "bcc" => group_follower_ap_ids(group),
      "object" => activity.data["id"],
      "audience" => group.ap_id
    })
  end

  defp insert_and_publish(data) do
    with {:ok, activity} <- ActivityPub.insert(data, true) do
      Federator.publish(activity)
      {:ok, activity}
    end
  end

  defp ensure_local_group(%User{local: true, actor_type: "Group"}), do: :ok
  defp ensure_local_group(%User{actor_type: "Group"}), do: {:error, :remote_group}
  defp ensure_local_group(%User{}), do: {:error, :not_a_group}
  defp ensure_local_group(_), do: {:error, :invalid_group}

  defp moderators_collection(group) do
    group.attributed_to_address || "#{group.ap_id}/collections/moderators"
  end

  defp group_followers(group) do
    group.follower_address || "#{group.ap_id}/followers"
  end

  defp direct_recipients(group, account) do
    [account.ap_id | group_follower_ap_ids(group)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp group_follower_ap_ids(group) do
    FollowingRelationship.followers_ap_ids(group)
  end

  defp maybe_put(data, _key, nil), do: data
  defp maybe_put(data, _key, ""), do: data
  defp maybe_put(data, key, value), do: Map.put(data, key, value)
end

# end of group_moderation.ex
