# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ProfileUpdateWorker do
  @moduledoc """
  Federates the latest profile state after a short edit burst.

  Local profile changes are committed immediately. Federation is delayed long
  enough to combine closely spaced avatar, header, bio, and field edits into a
  single ActivityPub Update containing the final actor representation.
  """

  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.UserView

  use Oban.Worker,
    queue: "federator_outgoing",
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  def enqueue(user_id) when is_binary(user_id) do
    %{"user_id" => user_id}
    |> new(schedule_in: 2)
    |> Oban.insert()
  end

  def enqueue(_), do: {:error, :invalid_user_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Repo.get(User, user_id) do
      %User{local: true, is_active: true} = user ->
        actor =
          UserView.render("user.json", user: user)
          |> Map.delete("@context")

        with {:ok, update_data, _meta} <- Builder.update(user, actor),
             {:ok, _activity, _meta} <- Pipeline.common_pipeline(update_data, local: true) do
          :ok
        end

      _ ->
        :discard
    end
  end

  def perform(%Oban.Job{}), do: :discard
end

# end of profile_update_worker.ex
