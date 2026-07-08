# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.User.Import do
  use Ecto.Schema

  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.BackgroundWorker

  require Logger

  @spec perform(atom(), User.t(), String.t() | list()) :: :ok | {:ok, any()} | {:error, any()}
  def perform(:mutes_import, %User{} = user, [_ | _] = identifiers) do
    perform_many(:mute_import, user, identifiers)
  end

  def perform(:blocks_import, %User{} = blocker, [_ | _] = identifiers) do
    perform_many(:block_import, blocker, identifiers)
  end

  def perform(:follow_import, %User{} = follower, [_ | _] = identifiers) do
    perform_many(:follow_import, follower, identifiers)
  end

  def perform(:mute_import, %User{} = user, identifier) when is_binary(identifier) do
    with {:ok, %User{} = muted_user} <- User.get_or_fetch(identifier),
         {_, false} <- {:existing_mute, User.mutes_user?(user, muted_user)},
         {:ok, _} <- User.mute(user, muted_user) do
      {:ok, muted_user}
    else
      {:existing_mute, true} -> :ok
      error -> handle_error(:mute_import, identifier, error)
    end
  end

  def perform(:block_import, %User{} = blocker, identifier) when is_binary(identifier) do
    with {:ok, %User{} = blocked} <- User.get_or_fetch(identifier),
         {_, false} <- {:existing_block, User.blocks_user?(blocker, blocked)},
         {:ok, _block} <- CommonAPI.block(blocker, blocked) do
      {:ok, blocked}
    else
      {:existing_block, true} -> :ok
      error -> handle_error(:block_import, identifier, error)
    end
  end

  def perform(:follow_import, %User{} = follower, identifier) when is_binary(identifier) do
    with {:ok, %User{} = followed} <- User.get_or_fetch(identifier),
         {_, false} <- {:existing_follow, User.following?(follower, followed)},
         {:ok, follower, followed} <- User.maybe_direct_follow(follower, followed),
         {:ok, _, _, _} <- CommonAPI.follow(follower, followed) do
      {:ok, followed}
    else
      {:existing_follow, true} -> :ok
      error -> handle_error(:follow_import, identifier, error)
    end
  end

  def perform(_, _, _), do: :ok

  defp handle_error(op, user_id, error) do
    Logger.debug("#{op} failed for #{user_id} with: #{inspect(error)}")
    {:error, error}
  end

  def blocks_import(%User{} = blocker, [_ | _] = identifiers) do
    enqueue_import_jobs(blocker, identifiers, "blocks_import")
  end

  def blocks_import(%User{}, []), do: {:ok, []}

  def follow_import(%User{} = follower, [_ | _] = identifiers) do
    follows_import(follower, identifiers)
  end

  def follow_import(%User{}, []), do: {:ok, []}

  def follows_import(%User{} = follower, [_ | _] = identifiers) do
    enqueue_import_jobs(follower, identifiers, "follow_import")
  end

  def follows_import(%User{}, []), do: {:ok, []}

  def mutes_import(%User{} = user, [_ | _] = identifiers) do
    enqueue_import_jobs(user, identifiers, "mutes_import")
  end

  def mutes_import(%User{}, []), do: {:ok, []}

  defp enqueue_import_jobs(%User{} = user, identifiers, op) do
    BackgroundWorker.enqueue(
      op,
      %{"user_id" => user.id, "identifiers" => identifiers}
    )
  end

  defp perform_many(op, %User{} = user, identifiers) do
    imported_users =
      identifiers
      |> Enum.reduce([], fn identifier, acc ->
        case perform(op, user, identifier) do
          {:ok, %User{} = imported_user} -> [imported_user | acc]
          :ok -> acc
          {:error, _reason} -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, imported_users}
  end
end
