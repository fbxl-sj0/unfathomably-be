# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.GroupMembership do
  @moduledoc """
  Local group membership and moderation state.

  ActivityPub follows remain the federated compatibility layer for groups.
  This table stores the local policy state that follows cannot express:
  group owners, co-moderators, pending local approval, and group bans.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias FlakeId.Ecto.CompatType
  alias Pleroma.FollowingRelationship
  alias Pleroma.Notification
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.CommonAPI

  require Logger

  @primary_key {:id, CompatType, autogenerate: true}
  @roles ~w(owner moderator user)
  @states ~w(active pending banned)
  @manager_roles ~w(owner moderator)

  schema "group_memberships" do
    field(:role, :string, default: "user")
    field(:state, :string, default: "active")

    belongs_to(:group, User, type: CompatType)
    belongs_to(:account, User, type: CompatType)

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:group_id, :account_id, :role, :state])
    |> validate_required([:group_id, :account_id, :role, :state])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:group_id,
      name: :group_memberships_group_id_account_id_index
    )
  end

  def local_group?(%User{actor_type: "Group", local: true}), do: true
  def local_group?(_), do: false

  def get(%User{} = group, %User{} = account) do
    __MODULE__
    |> where(group_id: ^group.id, account_id: ^account.id)
    |> Repo.one()
  end

  def ensure_owner(%User{} = group, %User{} = account) do
    upsert(group, account, %{role: "owner", state: "active"})
  end

  @doc """
  Checks whether an incoming ActivityPub Follow may create a group membership.

  Group bans are local policy and must not be overwritten merely because the
  banned account sends another Follow. Person actors and remote groups do not
  use this table, so validation is a no-op for them.
  """
  def validate_federated_follow(%User{} = group, %User{} = account) do
    if local_group?(group) and banned?(group, account) do
      {:error, :banned}
    else
      :ok
    end
  end

  @doc """
  Mirrors an ActivityPub Follow into the explicit local group membership table.

  The generic following relationship remains the federated compatibility
  layer. This function records the policy state needed by group APIs while
  preserving manager roles and refusing to replace a ban.
  """
  def sync_federated_follow(%User{} = group, %User{} = account, state)
      when state in ["active", "pending"] do
    if local_group?(group) do
      case get(group, account) do
        %__MODULE__{state: "banned"} ->
          {:error, :banned}

        %__MODULE__{role: role} when role in @manager_roles ->
          upsert(group, account, %{role: role, state: "active"})

        _membership ->
          upsert(group, account, %{role: "user", state: state})
      end
    else
      {:ok, nil}
    end
  end

  def sync_federated_follow(%User{}, %User{}, _state), do: {:error, :invalid_membership_state}

  @doc """
  Removes the ordinary membership mirrored from an ActivityPub Follow.

  Repeated Undo or Reject deliveries are harmless. Manager roles and bans are
  explicit local policy records and therefore survive a remote unfollow.
  """
  def sync_federated_unfollow(%User{} = group, %User{} = account) do
    if local_group?(group) do
      case get(group, account) do
        %__MODULE__{role: "user", state: state} when state in ["active", "pending"] ->
          delete_membership(group, account)

        %__MODULE__{} = membership ->
          {:ok, membership}

        nil ->
          {:ok, nil}
      end
    else
      {:ok, nil}
    end
  end

  def join(%User{} = account, %User{} = group) do
    cond do
      not local_group?(group) ->
        CommonAPI.follow(account, group)

      banned?(group, account) ->
        {:error, :banned}

      true ->
        with {:ok, _follower, followed, activity} <- CommonAPI.follow(account, group) do
          state = if activity.data["state"] == "accept", do: "active", else: "pending"
          {:ok, _membership} = upsert(group, account, %{role: "user", state: state})
          {:ok, account, followed, activity}
        end
    end
  end

  def leave(%User{} = account, %User{} = group) do
    case role(group, account) do
      "owner" ->
        {:error, :owner}

      _ ->
        delete_membership(group, account)
        CommonAPI.unfollow(account, group)
    end
  end

  def approve(%User{} = actor, %User{} = group, %User{} = account) do
    with :ok <- require_manager(actor, group),
         {:ok, follower} <- CommonAPI.accept_follow_request(account, group),
         {:ok, membership} <- upsert(group, account, %{role: "user", state: "active"}) do
      mark_join_request(group, account, "accept")
      {:ok, follower, membership}
    end
  end

  def reject(%User{} = actor, %User{} = group, %User{} = account) do
    with :ok <- require_manager_or_self(actor, group, account),
         {:ok, follower} <- CommonAPI.reject_follow_request(account, group) do
      delete_membership(group, account)
      mark_join_request(group, account, "reject")
      {:ok, follower}
    end
  end

  def promote(%User{} = actor, %User{} = group, accounts, role) when is_list(accounts) do
    with :ok <- require_manager(actor, group),
         {:ok, role} <- normalize_role(role),
         true <- role == "moderator" do
      accounts
      |> Enum.reject(&owner?(group, &1))
      |> Enum.map(fn account ->
        {:ok, membership} = upsert(group, account, %{role: role, state: "active"})
        membership
      end)
      |> then(&{:ok, &1})
    else
      false -> {:error, :unsupported_role}
      error -> error
    end
  end

  def demote(%User{} = actor, %User{} = group, accounts, role) when is_list(accounts) do
    with :ok <- require_owner(actor, group),
         {:ok, role} <- normalize_role(role),
         true <- role == "user" do
      accounts
      |> Enum.reject(&owner?(group, &1))
      |> Enum.map(fn account ->
        {:ok, membership} = upsert(group, account, %{role: role, state: "active"})
        membership
      end)
      |> then(&{:ok, &1})
    else
      false -> {:error, :unsupported_role}
      error -> error
    end
  end

  def kick(%User{} = actor, %User{} = group, accounts) when is_list(accounts) do
    with :ok <- require_manager(actor, group) do
      accounts
      |> Enum.reject(&protected_from?(actor, group, &1))
      |> Enum.each(fn account ->
        delete_membership(group, account)
        CommonAPI.unfollow(account, group)
      end)

      :ok
    end
  end

  def ban(%User{} = actor, %User{} = group, accounts) when is_list(accounts) do
    with :ok <- require_manager(actor, group) do
      accounts
      |> Enum.reject(&protected_from?(actor, group, &1))
      |> Enum.map(fn account ->
        CommonAPI.unfollow(account, group)
        maybe_federate_group_block(group, account)
        {:ok, membership} = upsert(group, account, %{role: "user", state: "banned"})
        membership
      end)
      |> then(&{:ok, &1})
    end
  end

  def unban(%User{} = actor, %User{} = group, accounts) when is_list(accounts) do
    with :ok <- require_manager(actor, group) do
      Enum.each(accounts, fn account ->
        delete_membership(group, account)
        maybe_federate_group_unblock(group, account)
      end)

      :ok
    end
  end

  def members(%User{} = group, role) do
    role = role || "user"
    role = if role == "admin", do: "moderator", else: role

    __MODULE__
    |> where(group_id: ^group.id, role: ^role, state: "active")
    |> join(:inner, [membership], account in assoc(membership, :account))
    |> preload([_membership, account], account: account)
    |> order_by([_membership, account], asc: account.nickname)
    |> Repo.all()
  end

  def membership_requests(%User{} = group) do
    explicit =
      __MODULE__
      |> where(group_id: ^group.id, state: "pending")
      |> join(:inner, [membership], account in assoc(membership, :account))
      |> select([_membership, account], account)
      |> Repo.all()

    follow_requests = User.get_follow_requests(group)

    (explicit ++ follow_requests)
    |> Enum.uniq_by(& &1.id)
  end

  def banned_accounts(%User{} = group) do
    __MODULE__
    |> where(group_id: ^group.id, state: "banned")
    |> join(:inner, [membership], account in assoc(membership, :account))
    |> select([_membership, account], account)
    |> Repo.all()
  end

  def relationship(nil, %User{} = group) do
    %{
      id: to_string(group.id),
      blocked_by: false,
      member: false,
      muting: false,
      notifying: false,
      pending_requests: false,
      requested: false,
      role: "user"
    }
  end

  def relationship(%User{} = account, %User{} = group) do
    membership = get(group, account)

    %{
      id: to_string(group.id),
      blocked_by: membership && membership.state == "banned",
      member: active_member?(membership) || FollowingRelationship.following?(account, group),
      muting: false,
      notifying: false,
      pending_requests: manager?(account, group) && membership_requests?(group),
      requested: pending_member?(membership) || pending_follow?(account, group),
      role: role_from_membership(membership)
    }
  end

  def local_group_moderator_ap_ids(%User{} = group) do
    __MODULE__
    |> where(group_id: ^group.id, state: "active")
    |> where([membership], membership.role in ^@manager_roles)
    |> join(:inner, [membership], account in assoc(membership, :account))
    |> select([_membership, account], account.ap_id)
    |> Repo.all()
  end

  def require_owner(%User{} = actor, %User{} = group) do
    cond do
      not local_group?(group) -> {:error, :not_local_group}
      owner?(group, actor) -> :ok
      true -> {:error, :forbidden}
    end
  end

  def require_manager(%User{} = actor, %User{} = group) do
    cond do
      not local_group?(group) -> {:error, :not_local_group}
      manager?(actor, group) -> :ok
      true -> {:error, :forbidden}
    end
  end

  def manager?(%User{} = account, %User{} = group) do
    role(group, account) in @manager_roles or
      User.privileged?(account, :users_manage_activation_state)
  end

  def owner?(%User{} = group, %User{} = account), do: role(group, account) == "owner"

  def role(%User{} = group, %User{} = account) do
    case get(group, account) do
      %__MODULE__{state: "active", role: role} -> role
      _ -> "user"
    end
  end

  defp upsert(%User{} = group, %User{} = account, attrs) do
    attrs =
      attrs
      |> Map.put(:group_id, group.id)
      |> Map.put(:account_id, account.id)

    case get(group, account) do
      %__MODULE__{} = membership ->
        membership
        |> changeset(attrs)
        |> Repo.update()
        |> preload_membership()

      nil ->
        %__MODULE__{}
        |> changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:group_id, :account_id],
          returning: true
        )
        |> preload_membership()
    end
  end

  defp preload_membership({:ok, %__MODULE__{} = membership}) do
    {:ok, Repo.preload(membership, [:group, :account])}
  end

  defp preload_membership(error), do: error

  defp delete_membership(%User{} = group, %User{} = account) do
    case get(group, account) do
      %__MODULE__{} = membership -> Repo.delete(membership)
      nil -> {:ok, nil}
    end
  end

  defp normalize_role(role) when role in ["admin", :admin], do: {:ok, "moderator"}
  defp normalize_role(role) when role in ["moderator", :moderator], do: {:ok, "moderator"}
  defp normalize_role(role) when role in ["user", :user], do: {:ok, "user"}
  defp normalize_role(_), do: {:error, :unsupported_role}

  defp require_manager_or_self(%User{id: id}, _group, %User{id: id}), do: :ok
  defp require_manager_or_self(actor, group, _account), do: require_manager(actor, group)

  defp protected_from?(actor, group, account) do
    owner?(group, account) or (role(group, account) == "moderator" and not owner?(group, actor))
  end

  defp banned?(group, account) do
    match?(%__MODULE__{state: "banned"}, get(group, account))
  end

  defp active_member?(%__MODULE__{state: "active"}), do: true
  defp active_member?(_), do: false

  defp pending_member?(%__MODULE__{state: "pending"}), do: true
  defp pending_member?(_), do: false

  defp pending_follow?(%User{} = account, %User{} = group) do
    match?(
      %FollowingRelationship{state: :follow_pending},
      FollowingRelationship.get(account, group)
    )
  end

  defp membership_requests?(%User{} = group), do: membership_requests(group) != []

  defp role_from_membership(%__MODULE__{state: "active", role: role}), do: role
  defp role_from_membership(_), do: "user"

  defp mark_join_request(%User{} = group, %User{} = account, state) do
    case Utils.get_existing_join(account.ap_id, group.ap_id) do
      %Pleroma.Activity{} = join_activity ->
        maybe_notify_join_accept(group, account, join_activity, state)
        Utils.update_join_state(join_activity, state)

      _ ->
        :ok
    end
  end

  defp maybe_notify_join_accept(%User{} = group, %User{} = _account, join_activity, "accept") do
    with {:ok, accept_data, _} <- Builder.accept(group, join_activity),
         {:ok, activity, _} <-
           Pleroma.Web.ActivityPub.ActivityPub.persist(accept_data, local: true) do
      Notification.create_notifications(activity)
    else
      error ->
        Logger.warning("Could not create group join acceptance notification: #{inspect(error)}")
        :ok
    end
  end

  defp maybe_notify_join_accept(_group, _account, _join_activity, _state), do: :ok

  defp maybe_federate_group_block(%User{} = group, %User{} = account) do
    case CommonAPI.block(group, account) do
      {:ok, _activity} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "Could not federate local group block #{group.ap_id} -> #{account.ap_id}: #{inspect(error)}"
        )

        :ok
    end
  end

  defp maybe_federate_group_unblock(%User{} = group, %User{} = account) do
    case CommonAPI.unblock(group, account) do
      {:ok, _activity} ->
        :ok

      {:error, :not_blocking} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "Could not federate local group unblock #{group.ap_id} -> #{account.ap_id}: #{inspect(error)}"
        )

        :ok
    end
  end
end

# end of lib/pleroma/group_membership.ex
