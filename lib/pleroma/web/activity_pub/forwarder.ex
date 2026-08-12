# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Forwarder do
  @moduledoc """
  Forwards authenticated quote updates and deletes to affected followers.

  A remote post can be quoted by a local actor whose followers never received
  the original post directly. Forwarding the original signed payload lets
  those followers refresh or remove the embedded quote without pretending the
  local actor authored the remote activity.

  The embedded proof is only a forwarding marker. Unfathomably receivers fetch
  and authenticate the canonical origin activity before applying it.
  """

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ForwardedActivityVerifier
  alias Pleroma.Web.ActivityPub.Publisher
  alias Pleroma.Web.ActivityPub.Utils

  @forwarded_types ["Delete", "Update"]

  @spec maybe_forward(map(), Activity.t()) :: :ok | {:error, any()}
  def maybe_forward(%{"type" => type} = data, %Activity{} = activity)
      when type in @forwarded_types do
    if ForwardedActivityVerifier.forwardable?(data) do
      json = Jason.encode!(data)

      data
      |> delivery_plan(activity)
      |> Enum.reduce_while(:ok, fn %{actor: actor, inbox: inbox}, :ok ->
        case Pleroma.Web.Federator.Publisher.enqueue_one(
               Publisher,
               %{
                 actor_id: actor.id,
                 id: data["id"],
                 inbox: inbox,
                 json: json,
                 unreachable_since: nil
               },
               priority: 1
             ) do
          {:ok, %Oban.Job{}} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:forward_enqueue_failed, reason}}}
          result -> {:halt, {:error, {:invalid_forward_enqueue_result, result}}}
        end
      end)
    else
      :ok
    end
  end

  def maybe_forward(_data, _activity), do: :ok

  @doc false
  @spec delivery_plan(map(), Activity.t()) :: [%{actor: User.t(), inbox: String.t()}]
  def delivery_plan(data, %Activity{} = activity) do
    object_id = Utils.get_ap_id(data["object"])
    origin_host = uri_host(data["actor"])

    object_id
    |> local_quoters_by_object_ap_id()
    |> Enum.flat_map(fn quoter ->
      quoter
      |> User.get_external_followers()
      |> Enum.map(fn follower ->
        %{actor: quoter, inbox: Publisher.determine_inbox(activity, follower)}
      end)
    end)
    |> Enum.filter(fn %{inbox: inbox} ->
      is_binary(inbox) and inbox != "" and uri_host(inbox) != origin_host
    end)
    |> Enum.uniq_by(& &1.inbox)
  end

  defp local_quoters_by_object_ap_id(object_ap_id) when is_binary(object_ap_id) do
    # Quote imports normalize quoteUri and _misskey_quote to quoteUrl. Starting
    # from that canonical field lets PostgreSQL use objects_quote_url before it
    # verifies the matching Create through activities_create_objects_index.
    # The former three-field OR began with the activities table and repeatedly
    # scanned tens of millions of rows for ordinary remote Updates and Deletes.
    from(object in Object,
      inner_join: activity in Activity,
      on:
        fragment("associated_object_id(?) = ?->>'id'", activity.data, object.data) and
          fragment("?->>'type'", activity.data) == "Create",
      inner_join: user in User,
      on:
        user.ap_id == activity.actor and
          user.ap_id == fragment("?->>'actor'", object.data),
      where: user.local == true and user.is_active == true,
      where: fragment("?->'quoteUrl' = to_jsonb(CAST(? AS text))", object.data, ^object_ap_id),
      distinct: true,
      select: user
    )
    |> Repo.all()
  end

  defp uri_host(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  rescue
    URI.Error -> nil
  end

  defp uri_host(_uri), do: nil
end

# end of web/activity_pub/forwarder.ex
