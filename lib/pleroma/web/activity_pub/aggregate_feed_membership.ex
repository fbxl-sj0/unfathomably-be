# Unfathomably Backend
#
# File: aggregate_feed_membership.ex
#
# Purpose:
#   Store the communities selected by an ActivityPub Feed actor.
#
# Responsibilities:
#   - authorize Feed-owned following collection changes
#   - apply idempotent Add and Remove activities
#   - expose normalized community membership to discovery code
#
# This file intentionally does not create account follows, fetch remote
# collections, or decide whether a user subscribes to a Feed.

defmodule Pleroma.Web.ActivityPub.AggregateFeedMembership do
  @moduledoc """
  A normalized projection of communities selected by an aggregate Feed actor.

  PieFed models a curated aggregate as an ActivityPub `Feed` actor whose
  `following` collection contains community actors. Incremental membership is
  delivered as `Add` and `Remove` activities. These records are deliberately
  separate from ordinary following relationships because receiving a Feed must
  not silently subscribe a local account to every community in that Feed.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias FlakeId.Ecto.CompatType
  alias Pleroma.Repo
  alias Pleroma.User

  @primary_key {:id, CompatType, autogenerate: true}

  schema "aggregate_feed_memberships" do
    belongs_to(:feed, User, type: CompatType)
    belongs_to(:community, User, type: CompatType)

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:feed_id, :community_id])
    |> validate_required([:feed_id, :community_id])
    |> unique_constraint(:feed_id,
      name: :aggregate_feed_memberships_feed_id_community_id_index
    )
  end

  @doc """
  Returns true only when a Feed actor changes its own following collection and
  the supplied object resolves to a community actor.

  Collection and object references may be bare IDs or embedded objects. The
  latter is common in ActivityPub software that emits a typed Collection as the
  target of an Add or Remove.
  """
  def authorized?(target, %User{actor_type: "Feed"} = feed, object) do
    with target_id when is_binary(target_id) <- reference_id(target),
         following_id when is_binary(following_id) <- feed.following_address,
         true <- target_id == following_id,
         community_id when is_binary(community_id) <- reference_id(object),
         %User{actor_type: "Group"} <- User.get_cached_by_ap_id(community_id) do
      true
    else
      _ -> false
    end
  end

  def authorized?(_target, _feed, _object), do: false

  @doc """
  Applies one authorized aggregate membership change.

  Replayed Add and Remove deliveries are harmless. The unique database index
  is the final concurrency guard when multiple inbox workers receive the same
  activity at once.
  """
  def apply_change(type, target, %User{} = feed, object) when type in ["Add", "Remove"] do
    with true <- authorized?(target, feed, object),
         community_id when is_binary(community_id) <- reference_id(object),
         %User{} = community <- User.get_cached_by_ap_id(community_id) do
      apply_authorized_change(type, feed, community)
    else
      false -> {:error, :unauthorized_aggregate_feed_change}
      nil -> {:error, :community_not_found}
      _ -> {:error, :invalid_aggregate_feed_change}
    end
  end

  def apply_change(_type, _target, _feed, _object),
    do: {:error, :invalid_aggregate_feed_change}

  def member?(%User{} = feed, %User{} = community) do
    __MODULE__
    |> where(feed_id: ^feed.id, community_id: ^community.id)
    |> Repo.exists?()
  end

  def list_communities(%User{} = feed) do
    User
    |> join(:inner, [community], membership in __MODULE__,
      on: membership.community_id == community.id
    )
    |> where([_community, membership], membership.feed_id == ^feed.id)
    |> order_by([community, _membership], asc: community.nickname)
    |> Repo.all()
  end

  @doc """
  Searches known aggregate Feed memberships for native discovery.

  The result retains the curating Feed alongside each community so clients can
  explain why an unfamiliar community appeared. Limits are clamped here as a
  second boundary below the controller-level discovery limits.
  """
  def search_communities(search, limit, offset) do
    search = search |> to_string() |> String.trim() |> String.slice(0, 200)
    limit = limit |> normalize_integer(12) |> max(1) |> min(24)
    offset = offset |> normalize_integer(0) |> max(0) |> min(10_000)

    query =
      from(community in User,
        join: membership in __MODULE__,
        on: membership.community_id == community.id,
        join: feed in User,
        on: feed.id == membership.feed_id,
        where: community.actor_type == "Group" and feed.actor_type == "Feed"
      )

    query = maybe_search(query, search)
    total = Repo.aggregate(query, :count, :id)

    entries =
      query
      |> order_by([community, _membership, feed],
        asc: community.nickname,
        asc: feed.nickname
      )
      |> limit(^limit)
      |> offset(^offset)
      |> select([community, _membership, feed], {community, feed})
      |> Repo.all()

    %{entries: entries, total: total}
  end

  @doc """
  Adds the bounded set of communities observed in a Feed collection snapshot.

  A collection page may be partial, so absence is not evidence for deletion.
  Explicit signed Remove activities remain authoritative for removing members.
  """
  def sync_communities(%User{actor_type: "Feed"} = feed, communities)
      when is_list(communities) do
    communities
    |> Enum.uniq_by(&Map.get(&1, :id))
    |> Enum.reduce_while({:ok, 0}, fn
      %User{actor_type: "Group"} = community, {:ok, count} ->
        case upsert_membership(feed, community) do
          {:ok, _membership} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _unsupported_actor, result ->
        {:cont, result}
    end)
  end

  def sync_communities(_feed, _communities), do: {:error, :invalid_aggregate_feed_snapshot}

  defp apply_authorized_change("Add", feed, community) do
    upsert_membership(feed, community)
  end

  defp apply_authorized_change("Remove", feed, community) do
    __MODULE__
    |> where(feed_id: ^feed.id, community_id: ^community.id)
    |> Repo.delete_all()

    {:ok, nil}
  end

  defp upsert_membership(feed, community) do
    attrs = %{feed_id: feed.id, community_id: community.id}

    with {:ok, _membership} <-
           %__MODULE__{}
           |> changeset(attrs)
           |> Repo.insert(
             on_conflict: :nothing,
             conflict_target: [:feed_id, :community_id]
           ) do
      {:ok, Repo.get_by!(__MODULE__, attrs)}
    end
  end

  defp reference_id(reference) when is_binary(reference), do: reference
  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(%{"href" => href}) when is_binary(href), do: href
  defp reference_id(%User{ap_id: ap_id}) when is_binary(ap_id), do: ap_id
  defp reference_id(_reference), do: nil

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    pattern = "%#{search}%"

    where(
      query,
      [community, _membership, feed],
      ilike(community.name, ^pattern) or
        ilike(community.nickname, ^pattern) or
        ilike(community.ap_id, ^pattern) or
        ilike(feed.name, ^pattern) or
        ilike(feed.nickname, ^pattern)
    )
  end

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp normalize_integer(_value, default), do: default
end

# end of lib/pleroma/web/activity_pub/aggregate_feed_membership.ex
