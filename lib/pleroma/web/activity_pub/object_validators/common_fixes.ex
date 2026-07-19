# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

# credo:disable-for-this-file Credo.Check.Readability.PredicateFunctionNames

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes do
  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Maps
  alias Pleroma.Object
  alias Pleroma.Object.Containment
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Addressing
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Utils

  require Pleroma.Constants

  def cast_and_filter_recipients(message, field, follower_collection, field_fallback \\ []) do
    field_value =
      case Map.fetch(message, field) do
        {:ok, nil} -> field_fallback
        {:ok, value} -> value
        :error -> field_fallback
      end

    {:ok, data} =
      field_value
      |> normalize_recipient_value()
      |> ObjectValidators.Recipients.cast()

    data =
      Enum.reject(data, fn x ->
        is_binary(follower_collection) and String.ends_with?(x, "/followers") and
          x != follower_collection
      end)

    Map.put(message, field, data)
  end

  defp normalize_recipient_value(values) when is_list(values) do
    Enum.flat_map(values, &normalize_recipient_value/1)
  end

  defp normalize_recipient_value(value) when is_binary(value) do
    [normalize_public_recipient(value)]
  end

  defp normalize_recipient_value(%{"id" => id}) when is_binary(id) do
    [normalize_public_recipient(id)]
  end

  defp normalize_recipient_value(%{"href" => href}) when is_binary(href) do
    [normalize_public_recipient(href)]
  end

  defp normalize_recipient_value(_), do: []

  defp normalize_public_recipient("Public"), do: Pleroma.Constants.as_public()
  defp normalize_public_recipient("as:Public"), do: Pleroma.Constants.as_public()
  defp normalize_public_recipient(value), do: value

  def fix_object_defaults(data) do
    data = Maps.filter_empty_values(data)

    context =
      Utils.maybe_create_context(
        data["context"] || data["conversation"] || context_id(data["contextHistory"]) ||
          context_id(data["target"]) || data["inReplyTo"] || data["id"]
      )

    data
    |> Map.put("context", context)
    |> fix_object_recipients(User.get_cached_by_ap_id(data["attributedTo"]))
  end

  defp fix_object_recipients(data, %User{follower_address: follower_collection}) do
    data
    |> cast_and_filter_recipients("to", follower_collection)
    |> cast_and_filter_recipients("cc", follower_collection)
    |> cast_and_filter_recipients("bto", follower_collection)
    |> cast_and_filter_recipients("bcc", follower_collection)
    |> cast_and_filter_recipients("audience", follower_collection)
    |> Transmogrifier.fix_implicit_addressing(follower_collection)
  end

  defp fix_object_recipients(data, _user) do
    data
    |> cast_and_filter_recipients("to", nil)
    |> cast_and_filter_recipients("cc", nil)
    |> cast_and_filter_recipients("bto", nil)
    |> cast_and_filter_recipients("bcc", nil)
    |> cast_and_filter_recipients("audience", nil)
  end

  defp context_id(id) when is_binary(id), do: id
  defp context_id(%{"id" => id}) when is_binary(id), do: id
  defp context_id(%{"href" => href}) when is_binary(href), do: href
  defp context_id(_), do: nil

  def fix_activity_addressing(activity) do
    activity = normalize_activity_actor(activity)

    case User.get_cached_by_ap_id(activity["actor"]) do
      %User{follower_address: follower_collection} ->
        activity
        |> cast_and_filter_recipients("to", follower_collection)
        |> cast_and_filter_recipients("cc", follower_collection)
        |> cast_and_filter_recipients("bto", follower_collection)
        |> cast_and_filter_recipients("bcc", follower_collection)
        |> cast_and_filter_recipients("audience", follower_collection)
        |> Transmogrifier.fix_implicit_addressing(follower_collection)

      _ ->
        activity
    end
  end

  defp normalize_activity_actor(%{"actor" => actor} = activity) do
    case Containment.get_actor(%{"actor" => actor}) do
      actor when is_binary(actor) -> Map.put(activity, "actor", actor)
      _ -> activity
    end
  end

  defp normalize_activity_actor(activity), do: activity

  def fix_actor(data) do
    actor =
      data
      |> Map.put_new("actor", data["attributedTo"])
      |> Containment.get_actor()

    data
    |> Addressing.put_attributed_groups()
    |> Map.put("actor", actor)
    |> Map.put("attributedTo", actor)
  end

  def fix_activity_context(data, %Object{data: object_data}) do
    case object_data["context"] || object_data["conversation"] || object_data["id"] do
      context when is_binary(context) -> Map.put(data, "context", context)
      _ -> data
    end
  end

  def fix_activity_context(data, _object), do: data

  def fix_object_action_recipients(%{"type" => "Announce", "actor" => actor} = data, object) do
    if group_actor?(actor) do
      data
    else
      do_fix_object_action_recipients(data, object)
    end
  end

  def fix_object_action_recipients(data, object) do
    do_fix_object_action_recipients(data, object)
  end

  def fix_object_action_audience(data, %Object{data: object_data}) do
    group_ap_ids = Addressing.addressed_group_ap_ids(object_data)

    case group_ap_ids do
      [] ->
        data

      [_ | _] ->
        {:ok, audience} =
          data
          |> Map.get("audience", [])
          |> normalize_recipient_value()
          |> Kernel.++(group_ap_ids)
          |> ObjectValidators.Recipients.cast()

        Map.put(data, "audience", audience)
    end
  end

  defp do_fix_object_action_recipients(
         %{"actor" => actor} = data,
         %Object{data: %{"actor" => actor}}
       ) do
    to =
      data
      |> Map.get("to", [])
      |> normalize_recipient_value()
      |> Kernel.--([actor])
      |> Enum.uniq()

    Map.put(data, "to", to)
  end

  defp do_fix_object_action_recipients(data, %Object{data: %{"actor" => actor}}) do
    to =
      data
      |> Map.get("to", [])
      |> normalize_recipient_value()
      |> Kernel.++([actor])
      |> Enum.uniq()

    Map.put(data, "to", to)
  end

  # Tombstones intentionally omit the original actor. Keep the recipients from
  # the wire and let the activity-specific validator decide whether the action
  # against a deleted object is still meaningful.
  defp do_fix_object_action_recipients(data, %Object{}), do: data

  defp group_actor?(actor) when is_binary(actor) do
    case User.get_by_ap_id(actor) do
      %User{actor_type: "Group"} -> true
      _ -> false
    end
  end

  defp group_actor?(_actor), do: false

  def fix_quote_url(%{"quoteUrl" => _quote_url} = data), do: data

  # Fedibird
  # https://github.com/fedibird/mastodon/commit/dbd7ae6cf58a92ec67c512296b4daaea0d01e6ac
  def fix_quote_url(%{"quoteUri" => quote_url} = data) do
    Map.put(data, "quoteUrl", quote_url)
  end

  # Old Fedibird (bug)
  # https://github.com/fedibird/mastodon/issues/9
  def fix_quote_url(%{"quoteURL" => quote_url} = data) do
    Map.put(data, "quoteUrl", quote_url)
  end

  # Misskey fallback
  def fix_quote_url(%{"_misskey_quote" => quote_url} = data) do
    Map.put(data, "quoteUrl", quote_url)
  end

  # Hubzilla compatibility.
  def fix_quote_url(%{"quote" => quote_url} = data) when is_binary(quote_url) do
    Map.put(data, "quoteUrl", quote_url)
  end

  def fix_quote_url(%{"tag" => [_ | _] = tags} = data) do
    tag = Enum.find(tags, &is_object_link_tag/1)

    if not is_nil(tag) do
      data
      |> Map.put("quoteUrl", tag["href"])
    else
      data
    end
  end

  def fix_quote_url(data), do: data

  # Mastodon can send "likes" as an ActivityStreams Collection with totals
  # on edited objects. Locally this field is an internal list/count pair, so
  # wire-level collections must be dropped before validation.
  def fix_likes(%{"likes" => likes} = data) when is_map(likes), do: Map.delete(data, "likes")

  def fix_likes(data), do: data

  # https://codeberg.org/fediverse/fep/src/branch/main/fep/e232/fep-e232.md
  def is_object_link_tag(%{
        "type" => "Link",
        "mediaType" => media_type,
        "href" => href
      })
      when media_type in Pleroma.Constants.activity_json_mime_types() and is_binary(href) do
    true
  end

  def is_object_link_tag(_), do: false
end
