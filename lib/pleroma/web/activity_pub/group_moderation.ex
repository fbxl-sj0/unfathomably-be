# Unfathomably group federation
# ----------------------------
#
# File: group_moderation.ex
#
# Purpose:
#
#   Publish community-scoped moderation activities for local groups in the
#   ActivityPub shapes expected by Threadiverse receivers.
#
# Responsibilities:
#
#   * create Add and Remove activities for group moderator collection changes
#   * create group-scoped Block and Undo Block activities for bans
#   * announce local moderation actions from the group actor
#
# This file intentionally does NOT contain:
#
#   * local database permission checks for admin UI actions
#   * site-wide moderation behavior
#   * remote group moderation state imports
#

defmodule Pleroma.Web.ActivityPub.GroupModeration do
  alias Pleroma.Activity
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.UserView
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Workers.PublisherWorker

  require Pleroma.Constants

  @moderation_announce_delay_seconds 12

  def publish_moderator_add(moderator, group, account) do
    publish_collection_change("Add", moderator, group, account)
  end

  def publish_moderator_remove(moderator, group, account) do
    publish_collection_change("Remove", moderator, group, account)
  end

  def publish_group_ban(moderator, group, account, opts \\ []) do
    with :ok <- ensure_local_group(group),
         :ok <- publish_group_profile_update(group),
         {:ok, activity} <-
           ActivityPub.insert(
             %{
               "id" => Utils.generate_activity_id(),
               "type" => "Block",
               "actor" => moderator.ap_id,
               "object" => account.ap_id,
               "target" => group.ap_id,
               "audience" => group.ap_id,
               "summary" => Keyword.get(opts, :reason),
               "removeData" => Keyword.get(opts, :remove_data, false),
               "to" => [Pleroma.Constants.as_public()],
               "cc" => [group.ap_id],
               "bcc" => [account.ap_id]
             },
             true
           ),
         :ok <- announce_from_group(group, activity, delay: @moderation_announce_delay_seconds) do
      {:ok, activity}
    end
  end

  def publish_group_unban(moderator, group, account, opts \\ []) do
    with :ok <- ensure_local_group(group),
         :ok <- publish_group_profile_update(group),
         block <- group_block_object(moderator, group, account, opts),
         {:ok, activity} <-
           ActivityPub.insert(
             %{
               "id" => Utils.generate_activity_id(),
               "type" => "Undo",
               "actor" => moderator.ap_id,
               "object" => block,
               "audience" => group.ap_id,
               "to" => [Pleroma.Constants.as_public()],
               "cc" => [group.ap_id],
               "bcc" => [account.ap_id]
             },
             true
           ),
         :ok <- announce_from_group(group, activity, delay: @moderation_announce_delay_seconds) do
      {:ok, activity}
    end
  end

  defp publish_collection_change(type, moderator, group, account) do
    with :ok <- ensure_local_group(group),
         :ok <- publish_group_profile_update(group),
         {:ok, activity} <-
           ActivityPub.insert(
             %{
               "id" => Utils.generate_activity_id(),
               "type" => type,
               "actor" => moderator.ap_id,
               "object" => account.ap_id,
               "target" => moderators_collection(group),
               "audience" => group.ap_id,
               "to" => [Pleroma.Constants.as_public()],
               "cc" => [group.ap_id],
               "bcc" => [account.ap_id]
             },
             true
           ),
         :ok <- announce_from_group(group, activity, delay: @moderation_announce_delay_seconds) do
      {:ok, activity}
    end
  end

  defp group_block_object(moderator, group, account, opts) do
    %{
      "id" => Utils.generate_activity_id(),
      "type" => "Block",
      "actor" => moderator.ap_id,
      "object" => account.ap_id,
      "target" => group.ap_id,
      "audience" => group.ap_id,
      "summary" => Keyword.get(opts, :reason)
    }
  end

  def announce_from_group(%User{} = group, %Activity{} = activity, opts \\ []) do
    with {:ok, announce} <-
           ActivityPub.insert(
             %{
               "id" => Utils.generate_activity_id(),
               "type" => "Announce",
               "actor" => group.ap_id,
               "object" => activity.data,
               "audience" => group.ap_id,
               "to" => [Pleroma.Constants.as_public()],
               "cc" => [group.follower_address]
             },
             true
           ),
         :ok <- publish_announce(announce, Keyword.get(opts, :delay, 0)) do
      :ok
    end
  end

  defp publish_announce(%Activity{} = announce, delay) when is_integer(delay) and delay > 0 do
    case PublisherWorker.enqueue("publish", %{"activity_id" => announce.id}, schedule_in: delay) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_announce(%Activity{} = announce, _delay), do: Utils.maybe_federate(announce)

  defp publish_group_profile_update(%User{} = group) do
    with {:ok, update} <-
           ActivityPub.insert(
             %{
               "id" => Utils.generate_activity_id(),
               "type" => "Update",
               "actor" => group.ap_id,
               "object" => UserView.render("user.json", %{user: group}),
               "audience" => group.ap_id,
               "to" => [Pleroma.Constants.as_public()],
               "cc" => [group.follower_address]
             },
             true
           ),
         :ok <- Utils.maybe_federate(update) do
      :ok
    end
  end

  defp moderators_collection(%User{attributed_to_address: address}) when is_binary(address) do
    address
  end

  defp moderators_collection(%User{ap_id: ap_id}), do: "#{ap_id}/collections/moderators"

  defp ensure_local_group(%User{actor_type: "Group", local: true}), do: :ok
  defp ensure_local_group(_group), do: {:error, :remote_group}
end

# end of group_moderation.ex
