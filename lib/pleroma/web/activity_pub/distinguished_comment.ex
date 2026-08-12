# Unfathomably Backend
#
# File: distinguished_comment.ex
#
# Purpose:
#   Preserve and authorize Threadiverse moderator-comment distinction.
#
# Responsibilities:
#   - identify the Group addressed by a reply
#   - reject unproven distinguished metadata without rejecting the comment
#   - apply authorized local distinction changes through ActivityPub Update
#
# This file intentionally does not render badges or grant group roles.

defmodule Pleroma.Web.ActivityPub.DistinguishedComment do
  @moduledoc """
  Authority checks and updates for the Threadiverse `distinguished` property.

  The property is presentation-sensitive moderation metadata. A remote author
  cannot make an ordinary reply appear to be an official moderator statement
  merely by setting a Boolean. The actor must be the addressed Group or a
  manager recorded for that Group.
  """

  alias Pleroma.Activity
  alias Pleroma.GroupMembership
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.ActivityPub.Visibility

  @max_group_references 32

  @doc "Normalizes untrusted distinguished metadata against known authority."
  def normalize(%{"distinguished" => true} = data) do
    if authorized_data?(data) do
      data
    else
      Map.put(data, "distinguished", false)
    end
  end

  def normalize(%{"distinguished" => false} = data), do: data
  def normalize(%{"distinguished" => _invalid} = data), do: Map.put(data, "distinguished", false)
  def normalize(data), do: data

  @doc "Checks whether the object actor can speak as a moderator in its Group."
  def authorized_data?(%{"inReplyTo" => in_reply_to, "actor" => actor_id} = data)
      when is_binary(in_reply_to) and is_binary(actor_id) do
    with %User{} = actor <- User.get_cached_by_ap_id(actor_id),
         %User{} = group <- group(data) do
      actor.ap_id == group.ap_id or GroupMembership.manager?(actor, group)
    else
      _ -> false
    end
  end

  def authorized_data?(_data), do: false

  @doc "Applies a local moderator distinction change and federates an Update."
  def set(%User{} = actor, %Activity{data: %{"type" => "Create"}} = activity, value)
      when is_boolean(value) do
    with true <- Visibility.visible_for_user?(activity, actor),
         %Object{} = object <- Object.normalize(activity, fetch: false),
         true <- is_binary(object.data["inReplyTo"]),
         %User{} = author <- Activity.user_actor(activity),
         true <- author.id == actor.id,
         %User{} = group <- group(object.data),
         true <- actor.ap_id == group.ap_id or GroupMembership.manager?(actor, group),
         changed_object <- Map.put(object.data, "distinguished", value),
         update_object <-
           Pleroma.Object.Updater.make_update_object_data(
             object.data,
             changed_object,
             Utils.make_date()
           ),
         {:ok, update_data, _meta} <- Builder.update(actor, update_object),
         {:ok, _update, _meta} <- Pipeline.common_pipeline(update_data, local: true),
         %Activity{} = refreshed <- Activity.get_by_id_with_object(activity.id) do
      {:ok, refreshed}
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_distinguished_comment}
    end
  end

  def set(%User{}, %Activity{}, _value), do: {:error, :invalid_distinguished_comment}

  @doc "Returns the addressed Group actor, when one is already known locally."
  def group(data) when is_map(data) do
    [data["group"], data["_unfathomably_group"], data["audience"], data["to"], data["cc"]]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&actor_reference_id/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(@max_group_references)
    |> Enum.find_value(fn ap_id ->
      case User.get_cached_by_ap_id(ap_id) do
        %User{actor_type: "Group"} = group -> group
        _not_a_group -> nil
      end
    end)
  end

  def group(_data), do: nil

  defp actor_reference_id(id) when is_binary(id), do: id
  defp actor_reference_id(%{"id" => id}) when is_binary(id), do: id
  defp actor_reference_id(%{"href" => href}) when is_binary(href), do: href
  defp actor_reference_id(_reference), do: nil
end

# end of lib/pleroma/web/activity_pub/distinguished_comment.ex
