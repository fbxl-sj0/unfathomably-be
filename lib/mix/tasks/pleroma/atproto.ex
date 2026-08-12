# Unfathomably BE
# ----------------
#
# File: mix/tasks/pleroma/atproto.ex
#
# Purpose:
#   Manage selective native AT identities and migrate locally followed Bluesky
#   bridge actors away from proxy accounts.
#
# Responsibilities:
#   - find bridge actors that have active local followers
#   - resolve their native DID or handle through the configured AppView
#   - follow a native identity for a local user by its readable handle or DID
#   - establish the equivalent native local follow before removing the proxy
#   - schedule an immediate bounded author-feed synchronization
#   - retire bridge actors that no active local account still follows
#
# This file intentionally does NOT delete historical bridge posts, migrate
# unrelated ActivityPub accounts, or enable bridging for local users.

defmodule Mix.Tasks.Pleroma.Atproto do
  use Mix.Task

  import Ecto.Query
  import Mix.Pleroma

  alias Pleroma.ATProto
  alias Pleroma.ATProto.BridgyCompat
  alias Pleroma.ATProto.Identities
  alias Pleroma.ATProto.Identity
  alias Pleroma.ConfigDB
  alias Pleroma.FollowingRelationship
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.ATProtoSyncWorker

  @shortdoc "Manages native AT identities and Bluesky bridge follows"
  @default_limit 20_000
  @sync_interval "*/5 * * * *"
  @sync_queue_limit 4

  def run(["migrate_bridgy" | options]) do
    start_pleroma()

    {opts, _remaining} =
      OptionParser.parse!(options,
        strict: [execute: :boolean, limit: :integer],
        aliases: [e: :execute, l: :limit]
      )

    execute? = opts[:execute] == true
    limit = normalize_limit(opts[:limit])
    candidates = bridgy_candidates(limit)

    mode =
      if execute?,
        do: "Migration enabled.",
        else: "Dry run; pass --execute to change follows."

    shell_info("Found #{length(candidates)} Bluesky bridge actor(s). #{mode}")

    summary =
      Enum.reduce(
        candidates,
        %{actors: 0, followers: 0, migrated: 0, skipped: 0, failed: 0, scheduled: 0},
        fn actor, acc -> migrate_actor(actor, execute?, acc) end
      )

    shell_info(
      "AT bridge migration summary: actors=#{summary.actors} " <>
        "followers=#{summary.followers} migrated=#{summary.migrated} " <>
        "skipped=#{summary.skipped} failed=#{summary.failed} " <>
        "scheduled=#{summary.scheduled}"
    )
  end

  def run(["sync", identifier]) when is_binary(identifier) do
    start_pleroma()

    identity =
      Identities.get_by_did(identifier) ||
        Identities.get_by_handle(String.downcase(identifier))

    case identity do
      %Identity{} = identity ->
        case schedule_sync(identity) do
          {:ok, job} -> shell_info("Scheduled AT identity synchronization as job #{job.id}.")
          error -> shell_error("AT identity synchronization was not scheduled: #{inspect(error)}")
        end

      nil ->
        shell_error("AT identity was not found: #{identifier}")
    end
  end

  def run(["follow", nickname, identifier])
      when is_binary(nickname) and is_binary(identifier) do
    start_pleroma()

    with %User{local: true} = follower <- User.get_cached_by_nickname(nickname),
         {:ok, %User{} = native} <- ATProto.resolve(identifier),
         %Identity{} = identity <- Identities.get_by_user(native),
         :ok <- ensure_native_follow(follower, native) do
      shell_info("@#{follower.nickname} now follows @#{identity.handle || identity.did}.")

      case schedule_sync(identity) do
        {:ok, job} -> shell_info("Scheduled AT identity synchronization as job #{job.id}.")
        error -> shell_error("AT identity synchronization was not scheduled: #{inspect(error)}")
      end
    else
      nil ->
        shell_error("The local user or resolved AT identity was not found.")

      {:error, reason} ->
        shell_error("The AT identity was not followed: #{inspect(reason)}")

      _error ->
        shell_error("The AT identity was not followed safely.")
    end
  end

  def run(["install_scheduler"]) do
    start_pleroma()

    case ConfigDB.get_by_group_and_key(:pleroma, Oban) do
      %{value: value} when is_list(value) ->
        queues = value |> Keyword.get(:queues, []) |> Keyword.put_new(:atproto, @sync_queue_limit)
        crontab = ensure_sync_crontab(Keyword.get(value, :crontab, []))

        value =
          value
          |> Keyword.put(:queues, queues)
          |> Keyword.put(:crontab, crontab)

        case ConfigDB.update_or_create(%{group: :pleroma, key: Oban, value: value}) do
          {:ok, _config} ->
            shell_info("Installed the ATProto queue and five-minute followed-feed scheduler.")

          error ->
            shell_error("ATProto scheduler configuration was not saved: #{inspect(error)}")
        end

      nil ->
        shell_info("No database Oban override is present; the source scheduler remains active.")

      _invalid ->
        shell_error("The database Oban override is not a keyword list; no changes were made.")
    end
  end

  def run(_args) do
    shell_error(
      "Usage: mix pleroma.atproto migrate_bridgy [--limit 20000] [--execute] | " <>
        "mix pleroma.atproto follow <local-user> <did-or-handle> | " <>
        "mix pleroma.atproto sync <did-or-handle> | " <>
        "mix pleroma.atproto install_scheduler"
    )
  end

  defp bridgy_candidates(limit) do
    User
    |> join(:inner, [followed], relationship in FollowingRelationship,
      on: relationship.following_id == followed.id
    )
    |> join(:inner, [_followed, relationship], follower in User,
      on: follower.id == relationship.follower_id
    )
    |> where([followed], not followed.local)
    |> where(
      [_followed, relationship, follower],
      follower.local and follower.is_active and
        relationship.state in ^[:follow_accept, :follow_pending]
    )
    |> distinct(true)
    |> order_by([followed], asc: followed.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.filter(&BridgyCompat.legacy_actor?/1)
  end

  defp migrate_actor(%User{} = actor, execute?, acc) do
    followers = local_followers(actor)

    acc = %{
      acc
      | actors: acc.actors + 1,
        followers: acc.followers + length(followers)
    }

    case BridgyCompat.native_identifier(actor) do
      identifier when is_binary(identifier) ->
        migrate_identifier(actor, followers, identifier, execute?, acc)

      nil ->
        shell_error("#{actor_label(actor)}: native DID or handle was not found")
        %{acc | failed: acc.failed + max(length(followers), 1)}
    end
  end

  defp migrate_identifier(actor, followers, identifier, false, acc) do
    shell_info("#{actor_label(actor)}: #{length(followers)} local follow(s) -> #{identifier}")
    %{acc | skipped: acc.skipped + length(followers)}
  end

  defp migrate_identifier(actor, followers, identifier, true, acc) do
    with {:ok, %User{} = native} <- BridgyCompat.resolve_native_actor(actor),
         false <- native.id == actor.id,
         %Identity{} = identity <- Identities.get_by_user(native) do
      shell_info(
        "#{actor_label(actor)}: #{length(followers)} local follow(s) -> " <>
          "#{native.nickname} (#{identifier})"
      )

      before = acc.migrated

      acc =
        Enum.reduce(followers, acc, fn follower, inner ->
          migrate_follow(follower, actor, native, inner)
        end)

      migrated = acc.migrated - before

      if migrated > 0 do
        retire_legacy_actor(actor)

        case schedule_sync(identity) do
          {:ok, _job} ->
            %{acc | scheduled: acc.scheduled + 1}

          error ->
            shell_error(
              "#{actor_label(actor)}: native feed synchronization was not scheduled: " <>
                inspect(error)
            )

            acc
        end
      else
        acc
      end
    else
      {:error, reason} ->
        shell_error(
          "#{actor_label(actor)}: native AT identity could not be resolved: #{inspect(reason)}"
        )

        %{acc | failed: acc.failed + max(length(followers), 1)}

      true ->
        shell_info("#{actor_label(actor)}: already maps to the native identity")
        %{acc | skipped: acc.skipped + length(followers)}

      _ ->
        shell_error("#{actor_label(actor)}: native AT identity was not persisted safely")
        %{acc | failed: acc.failed + max(length(followers), 1)}
    end
  end

  defp migrate_follow(follower, legacy, native, acc) do
    with :ok <- ensure_native_follow(follower, native),
         :ok <- remove_legacy_follow(follower, legacy) do
      shell_info("  migrated @#{follower.nickname}")
      %{acc | migrated: acc.migrated + 1}
    else
      error ->
        shell_error("  @#{follower.nickname} was not migrated: #{inspect(error)}")
        %{acc | failed: acc.failed + 1}
    end
  end

  defp ensure_native_follow(follower, native) do
    case FollowingRelationship.get(follower, native) do
      %FollowingRelationship{state: :follow_accept} ->
        :ok

      %FollowingRelationship{} ->
        case FollowingRelationship.update(follower, native, :follow_accept) do
          {:ok, _follower, _native} -> :ok
          error -> error
        end

      nil ->
        case CommonAPI.follow(follower, native) do
          {:ok, _follower, _native, _activity} -> :ok
          error -> error
        end
    end
  end

  defp remove_legacy_follow(follower, legacy) do
    case CommonAPI.unfollow(follower, legacy) do
      {:ok, _follower} ->
        :ok

      _error ->
        case FollowingRelationship.unfollow(follower, legacy) do
          {:ok, _follower, _legacy} -> :ok
          {:ok, nil} -> :ok
          error -> error
        end
    end
  end

  defp schedule_sync(%Identity{id: identity_id}) do
    %{"identity_id" => identity_id}
    |> ATProtoSyncWorker.new()
    |> Oban.insert()
  end

  defp retire_legacy_actor(actor) do
    case local_followers(actor) do
      [] ->
        result =
          actor
          |> Ecto.Changeset.change(%{
            is_active: false,
            invisible: true,
            is_discoverable: false,
            is_suggested: false
          })
          |> Repo.update()

        case result do
          {:ok, retired} ->
            User.invalidate_cache(retired)

          error ->
            shell_error("#{actor_label(actor)}: proxy retirement failed: #{inspect(error)}")
        end

      _remaining ->
        :ok
    end
  end

  defp local_followers(actor) do
    FollowingRelationship
    |> join(:inner, [relationship], follower in User, on: relationship.follower_id == follower.id)
    |> where(
      [relationship, follower],
      relationship.following_id == ^actor.id and follower.local and follower.is_active and
        relationship.state in ^[:follow_accept, :follow_pending]
    )
    |> select([_relationship, follower], follower)
    |> Repo.all()
  end

  defp actor_label(%User{nickname: nickname}) when is_binary(nickname), do: nickname
  defp actor_label(%User{ap_id: ap_id}), do: ap_id

  defp normalize_limit(value) when is_integer(value) and value in 1..100_000, do: value
  defp normalize_limit(_value), do: @default_limit

  defp ensure_sync_crontab(crontab) when is_list(crontab) do
    if Enum.any?(crontab, fn
         {_schedule, ATProtoSyncWorker} -> true
         {_schedule, ATProtoSyncWorker, _options} -> true
         _entry -> false
       end) do
      crontab
    else
      [{@sync_interval, ATProtoSyncWorker} | crontab]
    end
  end

  defp ensure_sync_crontab(_crontab), do: [{@sync_interval, ATProtoSyncWorker}]
end

# end of mix/tasks/pleroma/atproto.ex
