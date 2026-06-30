# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.PurgeExpiredToken do
  @moduledoc """
  Worker which purges expired OAuth tokens
  """

  use Oban.Worker, queue: :token_expiration, max_attempts: 1

  defguardp valid_job_id(id) when (is_binary(id) and byte_size(id) > 0) or is_integer(id)

  @spec enqueue(%{token_id: integer(), valid_until: DateTime.t(), mod: module()}) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(args) do
    {scheduled_at, args} = Map.pop(args, :valid_until)

    args
    |> __MODULE__.new(scheduled_at: scheduled_at)
    |> Oban.insert()
  end

  @impl true
  def perform(%Oban.Job{args: %{"token_id" => id, "mod" => module}}) when valid_job_id(id) do
    with {:ok, module} <- cast_module(module),
         token when not is_nil(token) <- get_token(module, id) do
      Pleroma.Repo.delete(token)
    else
      {:error, reason} -> {:cancel, reason}
      nil -> {:cancel, :token_not_found}
    end
  end

  def perform(%Oban.Job{}), do: :discard

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(5)

  defp cast_module(module) when is_binary(module) do
    {:ok, String.to_existing_atom(module)}
  rescue
    _ -> {:error, :invalid_token_module}
  end

  defp cast_module(_), do: {:error, :invalid_token_module}

  defp get_token(module, id) do
    Pleroma.Repo.get(module, id)
  rescue
    _ -> nil
  end
end
