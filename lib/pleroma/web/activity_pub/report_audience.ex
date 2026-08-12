# Unfathomably Backend
#
# File: report_audience.ex
#
# Purpose:
#   Derive the smallest authorized remote audience for an ActivityPub Flag.
#
# Responsibilities:
#   - identify communities referenced by reported statuses
#   - select remote community actors or known remote community moderators
#   - include the reported actor's remote instance when required
#   - deduplicate recipients by destination instance
#   - remove ordinary follower and public fanout from sensitive reports
#
# This file intentionally does not decide whether a report is valid, notify
# local moderators, or deliver HTTP requests.

defmodule Pleroma.Web.ActivityPub.ReportAudience do
  @moduledoc """
  Privacy-scoped recipient construction for federated reports.

  A Flag contains moderation evidence and must never inherit the audience of
  the reported post. Remote communities receive reports through their actor;
  local communities may additionally route them to remote accounts explicitly
  recorded as active owners or moderators. Recipients are collapsed by host so
  one report is not sent repeatedly to several inboxes on the same instance.
  """

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.GroupMembership
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  @max_statuses 100
  @max_actor_references 200
  @manager_roles ["owner", "moderator"]

  @doc """
  Replaces transport audiences on a Flag with authorized, host-deduplicated
  recipients. Empty recipient lists are valid for reports requiring only local
  moderation.
  """
  def scope(data, params) when is_map(data) and is_map(params) do
    data
    |> Map.put("to", recipients(params))
    |> Map.put("cc", [])
    |> Map.delete("audience")
    |> Map.delete("bto")
    |> Map.delete("bcc")
  end

  def scope(data, _params), do: data

  @doc "Returns the bounded remote actor audience for one report."
  def recipients(params) when is_map(params) do
    community_recipients(params)
    |> Kernel.++(reported_actor_recipients(params))
    |> Enum.filter(&safe_remote_actor_id?/1)
    |> Enum.uniq_by(&destination_host/1)
  end

  def recipients(_params), do: []

  defp community_recipients(params) do
    params
    |> Map.get(:statuses, Map.get(params, "statuses", []))
    |> List.wrap()
    |> Enum.take(@max_statuses)
    |> Enum.flat_map(&community_references/1)
    |> Enum.uniq()
    |> Enum.take(@max_actor_references)
    |> Enum.flat_map(fn ap_id ->
      case User.get_cached_by_ap_id(ap_id) do
        %User{actor_type: "Group", local: true} = group -> remote_group_managers(group)
        %User{actor_type: "Group", local: false} = group -> [group.ap_id]
        _not_a_group -> []
      end
    end)
  end

  defp reported_actor_recipients(params) do
    case Map.get(params, :account, Map.get(params, "account")) do
      %User{local: false, ap_id: ap_id} when is_binary(ap_id) -> [ap_id]
      _local_or_missing_account -> []
    end
  end

  defp remote_group_managers(%User{} = group) do
    GroupMembership
    |> join(:inner, [membership], account in User, on: account.id == membership.account_id)
    |> where(
      [membership, account],
      membership.group_id == ^group.id and
        membership.state == "active" and
        membership.role in ^@manager_roles and
        account.local == false
    )
    |> select([_membership, account], account.ap_id)
    |> Repo.all()
  end

  defp community_references(%Activity{} = activity) do
    case Object.normalize(activity, fetch: false) do
      %Object{data: data} -> community_references(data)
      _missing_object -> community_references(activity.data)
    end
  end

  defp community_references(%Object{data: data}), do: community_references(data)

  defp community_references(data) when is_map(data) do
    [
      data["group"],
      data["_unfathomably_group"],
      data["audience"],
      data["to"],
      data["cc"],
      data["attributedTo"]
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&actor_reference_id/1)
    |> Enum.filter(&is_binary/1)
  end

  defp community_references(_status), do: []

  defp actor_reference_id(id) when is_binary(id), do: id
  defp actor_reference_id(%{"id" => id}) when is_binary(id), do: id
  defp actor_reference_id(%{"href" => href}) when is_binary(href), do: href
  defp actor_reference_id(_reference), do: nil

  defp safe_remote_actor_id?(ap_id) when is_binary(ap_id) and byte_size(ap_id) <= 2_048 do
    case URI.parse(ap_id) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _invalid ->
        false
    end
  end

  defp safe_remote_actor_id?(_ap_id), do: false

  defp destination_host(ap_id) do
    ap_id
    |> URI.parse()
    |> Map.get(:host)
    |> String.downcase()
  end
end

# end of lib/pleroma/web/activity_pub/report_audience.ex
