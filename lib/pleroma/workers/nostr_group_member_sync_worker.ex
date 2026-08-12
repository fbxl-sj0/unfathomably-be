# Unfathomably BE
# ----------------
#
# File: workers/nostr_group_member_sync_worker.ex
#
# Purpose:
#   Turn a followed NIP-29 group's bounded member directory into normal account
#   cards and group memberships.
#
# Responsibilities:
#   - process only groups followed by genuine local ActivityPub accounts
#   - create canonical Nostr mirror identities for directory public keys
#   - synchronize Nostr-owned membership roles without altering local bans
#   - enqueue deduplicated metadata-only profile backfills
#   - remove stale memberships belonging to Nostr mirror profiles
#
# This file intentionally does NOT crawl arbitrary discovered groups, fetch
# post history, publish follows, or alter memberships owned by local users.

defmodule Pleroma.Workers.NostrGroupMemberSyncWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "nostr",
    max_attempts: 3,
    unique: [period: 300, states: Oban.Job.states(), keys: [:group_id]]

  import Ecto.Query

  require Logger

  alias Pleroma.FollowingRelationship
  alias Pleroma.GroupMembership
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Workers.NostrProfileBackfillWorker

  @max_members 500

  def enqueue(%User{id: group_id}) do
    %{"group_id" => to_string(group_id)}
    |> new()
    |> Oban.insert()

    :ok
  end

  def enqueue(_group), do: :ok

  @impl Oban.Worker
  def perform(%Job{args: %{"group_id" => group_id}}) do
    with %User{} = group <- User.get_cached_by_id(group_id),
         %Entity{kind: "mirror_group"} = entity <- Identity.get_by_user(group),
         true <- followed_by_local_account?(group.id),
         {:ok, pubkeys} <- member_pubkeys(entity) do
      synchronize(group, entity, pubkeys)
    else
      false -> {:cancel, :group_not_followed}
      {:error, reason} -> {:cancel, reason}
      _ -> {:cancel, :group_not_found}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  defp synchronize(group, entity, pubkeys) do
    roles = directory_roles(entity)

    {account_ids, failures} =
      Enum.reduce(pubkeys, {[], []}, fn pubkey, {account_ids, failures} ->
        role = Map.get(roles, pubkey, "user")

        with {:ok, %User{} = account} <-
               Identity.resolve(%{
                 type: :profile,
                 pubkey: pubkey,
                 relays: [entity.relay_url]
               }),
             {:ok, _membership} <-
               GroupMembership.sync_directory_member(group, account, role) do
          NostrProfileBackfillWorker.enqueue(account)
          {[account.id | account_ids], failures}
        else
          error -> {account_ids, [{pubkey, error} | failures]}
        end
      end)

    prune_stale_memberships(group.id, account_ids)

    if failures != [] do
      Logger.warning("Could not synchronize every Nostr group member",
        group: group.ap_id,
        failed: length(failures),
        reasons: failures |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.take(3) |> inspect()
      )
    end

    :ok
  end

  defp member_pubkeys(%Entity{metadata: metadata}) when is_map(metadata) do
    case Map.fetch(metadata, "member_pubkeys") do
      {:ok, pubkeys} when is_list(pubkeys) ->
        pubkeys =
          pubkeys
          |> Enum.filter(&valid_pubkey?/1)
          |> Enum.uniq()
          |> Enum.take(@max_members)

        {:ok, pubkeys}

      _ ->
        {:error, :member_directory_missing}
    end
  end

  defp member_pubkeys(_entity), do: {:error, :member_directory_missing}

  defp directory_roles(%Entity{metadata: metadata}) do
    metadata = metadata || %{}
    owner_pubkey = metadata["owner_pubkey"]

    administrators =
      metadata
      |> Map.get("administrators", [])
      |> Enum.flat_map(fn
        %{"pubkey" => pubkey} when is_binary(pubkey) -> [pubkey]
        _administrator -> []
      end)
      |> MapSet.new()

    metadata
    |> Map.get("member_pubkeys", [])
    |> Enum.reduce(%{}, fn pubkey, roles ->
      role =
        cond do
          pubkey == owner_pubkey -> "owner"
          MapSet.member?(administrators, pubkey) -> "moderator"
          true -> "user"
        end

      Map.put(roles, pubkey, role)
    end)
  end

  defp prune_stale_memberships(group_id, keep_account_ids) do
    query =
      GroupMembership
      |> join(:inner, [membership], entity in Entity, on: entity.user_id == membership.account_id)
      |> where(
        [membership, entity],
        membership.group_id == ^group_id and membership.state == "active" and
          entity.kind == "mirror_profile"
      )

    query =
      case keep_account_ids do
        [] -> query
        ids -> where(query, [membership], membership.account_id not in ^ids)
      end

    Repo.delete_all(query)
    :ok
  end

  defp followed_by_local_account?(group_id) do
    FollowingRelationship
    |> join(:inner, [relationship], follower in User, on: follower.id == relationship.follower_id)
    |> join(:left, [_relationship, follower], follower_entity in Entity,
      on:
        follower_entity.user_id == follower.id and
          follower_entity.kind in ["mirror_profile", "mirror_group"]
    )
    |> where(
      [relationship, follower, follower_entity],
      relationship.following_id == ^group_id and
        relationship.state == ^:follow_accept and follower.local and
        is_nil(follower_entity.id)
    )
    |> Repo.exists?()
  end

  defp valid_pubkey?(pubkey) do
    is_binary(pubkey) and Regex.match?(~r/^[0-9a-f]{64}$/, pubkey)
  end
end

# end of workers/nostr_group_member_sync_worker.ex
