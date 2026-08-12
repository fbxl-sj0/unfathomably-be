# Unfathomably BE
# ----------------
#
# File: mix/tasks/pleroma/nostr.ex
#
# Purpose:
#   Provide operator tools for maintaining native Nostr identities and moving
#   Mostr-backed follows without deleting historical ActivityPub records.
#
# Responsibilities:
#   - bootstrap bounded Nostr projections for recently active local users
#   - discover likely Mostr actors with bounded database queries
#   - extract their NIP-19 or hexadecimal Nostr public keys
#   - report migration effects before changing follow relationships
#   - follow the native identity before unfollowing its Mostr counterpart
#   - retire bridge actors and relay metadata without deleting historical posts
#
# This file intentionally does NOT create ActivityPub posts, export private
# posts, delete remote users, import private keys, or make Nostr identities
# canonical over local ActivityPub users.

defmodule Mix.Tasks.Pleroma.Nostr do
  use Mix.Task

  import Ecto.Query
  import Mix.Pleroma

  alias Pleroma.Activity
  alias Pleroma.FollowingRelationship
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.MostrCompat
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Repo
  alias Pleroma.User

  @shortdoc "Maintains local Nostr projections and migrates Mostr follows"
  @content_kinds [1, 9, 11, 1_111, 30_023]
  @npub ~r/\bnpub1[023456789acdefghjklmnpqrstuvwxyz]{58}\b/i
  @hex_pubkey ~r/(?:^|[\/:@])([0-9a-f]{64})(?:$|[\/?#])/i

  def run(["migrate_mostr" | options]) do
    start_pleroma()

    {opts, _remaining} =
      OptionParser.parse!(options,
        strict: [execute: :boolean, relay: :string],
        aliases: [e: :execute, r: :relay]
      )

    relay = normalize_relay_option(opts[:relay])
    execute? = opts[:execute] == true
    candidates = mostr_candidates()

    mode =
      if execute?, do: "Migration enabled.", else: "Dry run; pass --execute to change follows."

    shell_info("Found #{length(candidates)} likely Mostr actors. #{mode}")

    summary =
      Enum.reduce(candidates, %{actors: 0, followers: 0, migrated: 0, skipped: 0, failed: 0}, fn
        actor, acc -> migrate_actor(actor, relay, execute?, acc)
      end)

    cleanup = retire_legacy_records(execute?)

    shell_info(
      "Mostr migration summary: actors=#{summary.actors} followers=#{summary.followers} " <>
        "migrated=#{summary.migrated} skipped=#{summary.skipped} failed=#{summary.failed} " <>
        "retired_actors=#{cleanup.actors} cleared_entities=#{cleanup.entities} " <>
        "cleared_events=#{cleanup.events} cleared_presentations=#{cleanup.presentations} " <>
        "cancelled_jobs=#{cleanup.jobs}"
    )
  end

  def run(["backfill_media" | options]) do
    start_pleroma()

    {opts, _remaining} =
      OptionParser.parse!(options,
        strict: [limit: :integer, after_id: :string],
        aliases: [l: :limit]
      )

    limit =
      case opts[:limit] do
        value when is_integer(value) and value in 1..5_000 -> value
        _ -> 500
      end

    after_id = normalize_backfill_cursor(opts[:after_id])

    events_with_lookahead =
      after_id
      |> media_backfill_query()
      |> limit(^(limit + 1))
      |> Repo.all()

    {events, more?} =
      if length(events_with_lookahead) > limit do
        {Enum.take(events_with_lookahead, limit), true}
      else
        {events_with_lookahead, false}
      end

    updated =
      Enum.count(events, fn event ->
        Bridge.backfill_media(event) == :updated
      end)

    next_after_id = if more?, do: List.last(events).id, else: nil

    shell_info(
      "Nostr media backfill: scanned=#{length(events)} updated=#{updated} " <>
        "complete=#{not more?} next_after_id=#{next_after_id || "none"}"
    )
  end

  def run(["bootstrap_local" | options]) do
    start_pleroma()

    {opts, _remaining} =
      OptionParser.parse!(options,
        strict: [
          execute: :boolean,
          days: :integer,
          limit: :integer,
          posts: :integer,
          nickname: :string,
          refresh: :boolean
        ],
        aliases: [e: :execute, l: :limit]
      )

    days = bounded_option(opts[:days], 1, 3_650, 180)
    limit = bounded_option(opts[:limit], 1, 500, 100)
    posts = bounded_option(opts[:posts], 0, 20, 3)
    execute? = opts[:execute] == true
    refresh? = opts[:refresh] == true

    candidates = local_bootstrap_candidates(days, limit, opts[:nickname], refresh?)

    mode =
      if execute?,
        do: "Bootstrap enabled.",
        else: "Dry run; pass --execute to publish Nostr projections."

    shell_info("Found #{length(candidates)} incomplete local projection(s). #{mode}")

    summary =
      Enum.reduce(candidates, %{actors: 0, posts: 0, failed: 0}, fn candidate, acc ->
        bootstrap_local_actor(candidate, posts, execute?, acc)
      end)

    shell_info(
      "Local Nostr bootstrap summary: actors=#{summary.actors} " <>
        "posts=#{summary.posts} failed=#{summary.failed}"
    )
  end

  def run(_args) do
    shell_error(
      "Usage: mix pleroma.nostr migrate_mostr [--relay wss://relay] [--execute] | " <>
        "mix pleroma.nostr backfill_media [--limit 500] [--after-id EVENT_ID] | " <>
        "mix pleroma.nostr bootstrap_local [--days 180] [--limit 100] " <>
        "[--posts 3] [--nickname USER] [--refresh] [--execute]"
    )
  end

  def media_backfill_query(after_id \\ nil) do
    Event
    |> where([event], event.kind in ^@content_kinds and not is_nil(event.ap_activity_id))
    |> maybe_after_event_id(after_id)
    |> order_by([event], asc: event.id)
  end

  defp maybe_after_event_id(query, nil), do: query

  defp maybe_after_event_id(query, after_id) do
    where(query, [event], event.id > ^after_id)
  end

  defp normalize_backfill_cursor(nil), do: nil

  defp normalize_backfill_cursor(after_id) when is_binary(after_id) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, after_id) do
      after_id
    else
      raise OptionParser.ParseError,
        message: "--after-id must be a lowercase 64-character Nostr event id"
    end
  end

  defp bounded_option(value, minimum, maximum, default) do
    if is_integer(value) and value >= minimum and value <= maximum do
      value
    else
      default
    end
  end

  defp local_bootstrap_candidates(days, limit, nickname, refresh?) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -days * 86_400, :second)

    User
    |> where(
      [user],
      user.local and user.is_active and user.actor_type == "Person" and
        user.invisible == false and user.last_active_at >= ^cutoff
    )
    |> maybe_bootstrap_nickname(nickname)
    |> order_by([user], desc: user.last_active_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&{&1, local_projection_state(&1)})
    |> Enum.filter(fn {user, state} ->
      refresh? or not state.profile? or not state.relay_list? or
        ((user.note_count || 0) > 0 and not state.note?)
    end)
  end

  defp maybe_bootstrap_nickname(query, nickname) when is_binary(nickname) and nickname != "" do
    where(query, [user], user.nickname == ^nickname)
  end

  defp maybe_bootstrap_nickname(query, _nickname), do: query

  defp local_projection_state(user) do
    case Identity.get_by_user(user) do
      %Entity{pubkey: pubkey} ->
        %{
          profile?: local_event_exists?(pubkey, [0]),
          relay_list?: local_event_exists?(pubkey, [10_002]),
          note?: local_event_exists?(pubkey, @content_kinds)
        }

      _entity ->
        %{profile?: false, relay_list?: false, note?: false}
    end
  end

  defp local_event_exists?(pubkey, kinds) do
    Event
    |> where([event], event.local and event.pubkey == ^pubkey and event.kind in ^kinds)
    |> Repo.exists?()
  end

  defp bootstrap_local_actor({user, state}, post_limit, execute?, acc) do
    activities =
      if state.note? do
        []
      else
        recent_public_activities(user, post_limit)
      end

    shell_info(
      "@#{user.nickname}: profile=#{state.profile?} relay_list=#{state.relay_list?} " <>
        "notes=#{state.note?} selected_posts=#{length(activities)}"
    )

    if execute? do
      profile_result = Bridge.publish_profile(user)

      post_results =
        Enum.map(activities, fn activity ->
          Process.sleep(100)
          Bridge.publish_activity(activity)
        end)

      failures =
        Enum.count([profile_result | post_results], fn result -> result != :ok end)

      %{acc |
        actors: acc.actors + 1,
        posts: acc.posts + Enum.count(post_results, &(&1 == :ok)),
        failed: acc.failed + failures
      }
    else
      %{acc | actors: acc.actors + 1, posts: acc.posts + length(activities)}
    end
  end

  defp recent_public_activities(_user, 0), do: []

  defp recent_public_activities(user, post_limit) do
    Activity
    |> where([activity], activity.actor == ^user.ap_id)
    |> where([activity], fragment("?->>'type' = 'Create'", activity.data))
    |> order_by([activity], desc: activity.inserted_at)
    |> limit(100)
    |> Repo.all()
    |> Enum.filter(&public_activity?/1)
    |> Enum.take(post_limit)
  end

  defp public_activity?(%Activity{data: data}) do
    public_uri = "https://www.w3.org/ns/activitystreams#Public"
    public_uri in (List.wrap(data["to"]) ++ List.wrap(data["cc"]))
  end

  defp mostr_candidates do
    User
    |> join(:inner, [user], relationship in Pleroma.FollowingRelationship,
      on: relationship.following_id == user.id
    )
    |> join(:inner, [_user, relationship], follower in User,
      on: follower.id == relationship.follower_id
    )
    |> where([user], not user.local)
    |> where([_user, _relationship, follower], follower.local)
    |> where(
      [user, _relationship, _follower],
      fragment("? ~* '^https{0,1}://[^/]*mostr[^/]*/'", user.ap_id) or
        fragment("? ~* '@[^@]*mostr[^@]*$'", user.nickname)
    )
    |> distinct(true)
    |> order_by([user], asc: user.id)
    |> Repo.all()
  end

  defp migrate_actor(%User{} = actor, relay, execute?, acc) do
    followers = local_followers(actor)
    acc = %{acc | actors: acc.actors + 1, followers: acc.followers + length(followers)}

    with {:ok, identifier} <- actor_identifier(actor),
         {:ok, identity} <- Protocol.decode_identifier(identifier),
         identity <- add_relay(identity, relay) do
      migrate_resolved_actor(actor, followers, identifier, identity, execute?, acc)
    else
      {:error, reason} ->
        shell_error(
          "#{actor.nickname}: could not decode native Nostr identity: #{inspect(reason)}"
        )

        %{acc | failed: acc.failed + max(length(followers), 1)}
    end
  end

  defp migrate_resolved_actor(actor, followers, identifier, _identity, false, acc) do
    shell_info("#{actor.nickname}: #{length(followers)} local follow(s) -> #{identifier}")

    Enum.reduce(followers, acc, fn follower, inner ->
      migrate_follow(follower, actor, nil, false, inner)
    end)
  end

  defp migrate_resolved_actor(actor, followers, identifier, identity, true, acc) do
    with {:ok, %User{} = native} <- Identity.resolve(identity),
         false <- native.id == actor.id do
      shell_info(
        "#{actor.nickname}: #{length(followers)} local follow(s) -> #{native.nickname} " <>
          "(#{identifier})"
      )

      Enum.reduce(followers, acc, fn follower, inner ->
        migrate_follow(follower, actor, native, true, inner)
      end)
    else
      {:error, reason} ->
        shell_error(
          "#{actor.nickname}: could not resolve native Nostr identity: #{inspect(reason)}"
        )

        %{acc | failed: acc.failed + max(length(followers), 1)}

      true ->
        shell_info("#{actor.nickname}: already maps to the native identity")
        %{acc | skipped: acc.skipped + length(followers)}

      _ ->
        shell_error("#{actor.nickname}: native Nostr identity could not be resolved safely")
        %{acc | failed: acc.failed + max(length(followers), 1)}
    end
  end

  defp migrate_follow(follower, _actor, _native, false, acc) do
    shell_info("  would migrate @#{follower.nickname}")
    %{acc | skipped: acc.skipped + 1}
  end

  defp migrate_follow(follower, actor, native, true, acc) do
    with :ok <- ensure_native_follow(follower, native),
         :ok <- remove_legacy_follow(follower, actor) do
      shell_info("  migrated @#{follower.nickname}")
      %{acc | migrated: acc.migrated + 1}
    else
      error ->
        shell_error("  @#{follower.nickname} was not migrated: #{inspect(error)}")
        %{acc | failed: acc.failed + 1}
    end
  end

  defp remove_legacy_follow(follower, actor) do
    FollowingRelationship
    |> where(
      [relationship],
      relationship.follower_id == ^follower.id and relationship.following_id == ^actor.id
    )
    |> Repo.delete_all()

    User.invalidate_cache(follower)
    User.invalidate_cache(actor)
    User.invalidate_following_cache(follower)

    case User.update_following_count(follower) do
      {:ok, _follower} -> :ok
      error -> error
    end
  end

  defp ensure_native_follow(follower, native) do
    if FollowingRelationship.following?(follower, native) do
      :ok
    else
      case Bridge.follow(follower, native) do
        {:ok, _follower} -> :ok
        error -> error
      end
    end
  end

  defp local_followers(actor) do
    FollowingRelationship
    |> join(:inner, [relationship], follower in User, on: relationship.follower_id == follower.id)
    |> where(
      [relationship],
      relationship.following_id == ^actor.id and
        relationship.state in ^[:follow_accept, :follow_pending]
    )
    |> where([_relationship, follower], follower.local and follower.is_active)
    |> select([_relationship, follower], follower)
    |> Repo.all()
  end

  defp actor_identifier(actor) do
    actor
    |> Map.from_struct()
    |> Map.take([:ap_id, :nickname, :actor_extensions, :also_known_as, :fields])
    |> collect_strings()
    |> Enum.find_value(&extract_identifier/1)
    |> case do
      nil -> {:error, :identifier_not_found}
      identifier -> {:ok, identifier}
    end
  end

  defp collect_strings(value) when is_binary(value), do: [value]
  defp collect_strings(value) when is_list(value), do: Enum.flat_map(value, &collect_strings/1)

  defp collect_strings(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.flat_map(&collect_strings/1)
  end

  defp collect_strings(_value), do: []

  defp extract_identifier(value) do
    case Regex.run(@npub, value, capture: :first) do
      [npub] ->
        String.downcase(npub)

      _ ->
        case Regex.run(@hex_pubkey, value, capture: :all_but_first) do
          [pubkey] -> String.downcase(pubkey)
          _ -> nil
        end
    end
  end

  defp add_relay(identity, nil), do: identity

  defp add_relay(identity, relay) do
    Map.update(identity, :relays, [relay], fn relays -> Enum.uniq([relay | relays]) end)
  end

  defp normalize_relay_option(nil), do: nil

  defp normalize_relay_option(relay) do
    Protocol.normalize_relay_url(relay) ||
      raise OptionParser.ParseError, message: "--relay must be a ws:// or wss:// URL"
  end

  defp retire_legacy_records(false) do
    cleanup = legacy_cleanup_counts()

    shell_info(
      "Would retire #{cleanup.actors} inactive bridge actor(s), clear " <>
        "#{cleanup.entities} bridge relay mapping(s), #{cleanup.events} event provenance " <>
        "value(s), #{cleanup.presentations} account presentation value(s), and " <>
        "cancel #{cleanup.jobs} incomplete bridge job(s)."
    )

    cleanup
  end

  defp retire_legacy_records(true) do
    user_now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    nostr_now = DateTime.utc_now() |> DateTime.truncate(:second)
    entity_rows = legacy_relay_rows(Entity)
    event_rows = legacy_relay_rows(Event)
    entity_ids = Enum.map(entity_rows, &elem(&1, 0))
    event_ids = Enum.map(event_rows, &elem(&1, 0))

    presentation_ids =
      User
      |> where([user], fragment("?::text ILIKE ?", user.actor_extensions, "%mostr%"))
      |> select([user], user.id)
      |> Repo.all()

    presentations =
      update_in_batches(presentation_ids, fn ids ->
        User
        |> where([user], user.id in ^ids)
        |> update(
          [user],
          set: [
            actor_extensions:
              fragment(
                "((coalesce(?, '{}'::jsonb) #- '{nostr,relay}') #- '{nostr,relays}') #- '{nostr,nip05}'",
                user.actor_extensions
              ),
            updated_at: ^user_now
          ]
        )
        |> Repo.update_all([])
      end)

    entities =
      update_in_batches(entity_ids, fn ids ->
        Entity
        |> where([entity], entity.id in ^ids)
        |> Repo.update_all(set: [relay_url: nil, updated_at: nostr_now])
      end)

    events =
      update_in_batches(event_ids, fn ids ->
        Event
        |> where([event], event.id in ^ids)
        |> Repo.update_all(set: [relay_url: nil, updated_at: nostr_now])
      end)

    clear_legacy_metadata(nostr_now)
    cancelled_jobs = cancel_legacy_jobs()

    remaining_follow_targets =
      FollowingRelationship
      |> join(:inner, [relationship], follower in User,
        on: follower.id == relationship.follower_id
      )
      |> join(:inner, [relationship, _follower], followed in User,
        on: followed.id == relationship.following_id
      )
      |> where(
        [relationship, follower, followed],
        follower.local and follower.is_active and
          relationship.state in ^[:follow_accept, :follow_pending] and
          (fragment("? ~* '^https{0,1}://[^/]*mostr[^/]*/'", followed.ap_id) or
             fragment("? ~* '@[^@]*mostr[^@]*$'", followed.nickname))
      )
      |> select([relationship], relationship.following_id)
      |> distinct(true)
      |> Repo.all()

    {actors, _rows} =
      legacy_users_query()
      |> where([user], user.id not in ^remaining_follow_targets)
      |> Repo.update_all(
        set: [
          is_active: false,
          invisible: true,
          is_discoverable: false,
          is_suggested: false,
          updated_at: user_now
        ]
      )

    %{
      actors: actors,
      entities: entities,
      events: events,
      presentations: presentations,
      jobs: cancelled_jobs
    }
  end

  defp legacy_cleanup_counts do
    remaining_follow_targets =
      FollowingRelationship
      |> join(:inner, [relationship], follower in User,
        on: follower.id == relationship.follower_id
      )
      |> where(
        [relationship, follower],
        follower.local and follower.is_active and
          relationship.state in ^[:follow_accept, :follow_pending]
      )
      |> select([relationship], relationship.following_id)
      |> distinct(true)
      |> Repo.all()

    actor_count =
      legacy_users_query()
      |> where([user], user.id not in ^remaining_follow_targets)
      |> Repo.aggregate(:count, :id)

    entity_rows = legacy_relay_rows(Entity)
    event_rows = legacy_relay_rows(Event)

    %{
      actors: actor_count,
      entities: length(entity_rows),
      events: length(event_rows),
      presentations: legacy_presentation_count(),
      jobs: legacy_job_count()
    }
  end

  defp legacy_users_query do
    User
    |> where([user], not user.local)
    |> where(
      [user],
      fragment("? ~* '^https{0,1}://[^/]*mostr[^/]*/'", user.ap_id) or
        fragment("? ~* '@[^@]*mostr[^@]*$'", user.nickname)
    )
  end

  defp legacy_relay_rows(schema) do
    schema
    |> where([record], not is_nil(record.relay_url))
    |> select([record], {record.id, record.relay_url})
    |> Repo.all()
    |> Enum.filter(fn {_id, relay_url} -> Nostr.compatibility_relay?(relay_url) end)
  end

  defp clear_legacy_metadata(now) do
    Entity
    |> where([entity], fragment("?::text ILIKE ?", entity.metadata, "%mostr%"))
    |> select([entity], {entity.id, entity.metadata})
    |> Repo.all()
    |> Enum.each(fn {id, metadata} ->
      cleaned = strip_legacy_references(metadata)

      Entity
      |> where([entity], entity.id == ^id)
      |> Repo.update_all(set: [metadata: cleaned, updated_at: now])
    end)
  end

  defp strip_legacy_references(value) when is_binary(value) do
    if MostrCompat.legacy_reference?(value), do: nil, else: value
  end

  defp strip_legacy_references(value) when is_list(value) do
    value
    |> Enum.map(&strip_legacy_references/1)
    |> Enum.reject(&is_nil/1)
  end

  defp strip_legacy_references(value) when is_map(value) do
    if MostrCompat.legacy_reference?(value["url"]) do
      nil
    else
      Enum.reduce(value, %{}, fn {key, item}, acc ->
        case strip_legacy_references(item) do
          nil -> acc
          cleaned -> Map.put(acc, key, cleaned)
        end
      end)
    end
  end

  defp strip_legacy_references(value), do: value

  defp update_in_batches(ids, callback) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.reduce(0, fn batch, total ->
      {count, _rows} = callback.(batch)
      total + count
    end)
  end

  defp legacy_presentation_count do
    User
    |> where([user], fragment("?::text ILIKE ?", user.actor_extensions, "%mostr%"))
    |> Repo.aggregate(:count, :id)
  end

  defp legacy_job_count do
    Oban.Job
    |> where([job], job.state in ^["available", "scheduled", "executing", "retryable"])
    |> where([job], fragment("?::text ILIKE ?", job.args, "%mostr.pub%"))
    |> Repo.aggregate(:count, :id)
  end

  defp cancel_legacy_jobs do
    job_ids =
      Oban.Job
      |> where([job], job.state in ^["available", "scheduled", "executing", "retryable"])
      |> where([job], fragment("?::text ILIKE ?", job.args, "%mostr.pub%"))
      |> select([job], job.id)
      |> Repo.all()

    Enum.each(job_ids, &Oban.cancel_job/1)
    length(job_ids)
  end
end

# end of mix/tasks/pleroma/nostr.ex
