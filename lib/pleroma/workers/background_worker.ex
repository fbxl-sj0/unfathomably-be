# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.BackgroundWorker do
  alias Pleroma.Instances.Instance
  alias Pleroma.User

  use Pleroma.Workers.WorkerHelper, queue: "background"

  defguardp valid_job_id(id) when (is_binary(id) and byte_size(id) > 0) or is_integer(id)

  @impl Oban.Worker

  def perform(%Job{args: %{"op" => "user_activation", "user_id" => user_id, "status" => status}})
      when valid_job_id(user_id) and is_boolean(status) do
    with %User{} = user <- get_cached_user(user_id) do
      User.perform(:set_activation_async, user, status)
    else
      nil -> {:cancel, :user_not_found}
    end
  end

  def perform(%Job{args: %{"op" => "force_password_reset", "user_id" => user_id}})
      when valid_job_id(user_id) do
    with %User{} = user <- get_cached_user(user_id) do
      User.perform(:force_password_reset, user)
    else
      nil -> {:cancel, :user_not_found}
    end
  end

  def perform(%Job{args: %{"op" => op, "user_id" => user_id, "identifiers" => identifiers}})
      when op in ["blocks_import", "follow_import", "mutes_import"] and valid_job_id(user_id) and
             is_list(identifiers) do
    with %User{} = user <- get_cached_user(user_id) do
      User.Import.perform(String.to_existing_atom(op), user, identifiers)
    else
      nil -> {:cancel, :user_not_found}
    end
  end

  def perform(%Job{args: %{"op" => op, "user_id" => user_id, "actor" => actor}})
      when op in ["block_import", "follow_import", "mute_import"] and valid_job_id(user_id) and
             is_binary(actor) do
    with %User{} = user <- get_cached_user(user_id) do
      User.Import.perform(String.to_existing_atom(op), user, actor)
    else
      nil -> {:cancel, :user_not_found}
    end
  end

  def perform(%Job{
        args: %{"op" => "move_following", "origin_id" => origin_id, "target_id" => target_id}
      })
      when valid_job_id(origin_id) and valid_job_id(target_id) do
    origin = get_cached_user(origin_id)
    target = get_cached_user(target_id)

    case {origin, target} do
      {%User{} = origin, %User{} = target} ->
        Pleroma.FollowingRelationship.move_following(origin, target)

      {nil, _} ->
        {:cancel, :origin_not_found}

      {_, nil} ->
        {:cancel, :target_not_found}
    end
  end

  def perform(%Job{args: %{"op" => "verify_fields_links", "user_id" => user_id}})
      when valid_job_id(user_id) do
    with %User{} = user <- get_user(user_id) do
      User.perform(:verify_fields_links, user)
    else
      nil -> {:cancel, :user_not_found}
    end
  end

  def perform(%Job{args: %{"op" => "delete_instance", "host" => host}})
      when is_binary(host) and byte_size(host) > 0 do
    Instance.perform(:delete_instance, host)
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(15)

  defp get_cached_user(user_id) do
    User.get_cached_by_id(user_id)
  rescue
    _ -> nil
  end

  defp get_user(user_id) do
    User.get_by_id(user_id)
  rescue
    _ -> nil
  end
end
