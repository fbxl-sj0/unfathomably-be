# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.GroupDiscussionCleanupWorker do
  @moduledoc """
  Purges old remote group discussion objects that nobody local has touched.

  Remote groups can pull in very large discussion trees. Keeping every untouched
  remote group post forever makes group support expensive for instances that
  follow busy communities, so this worker removes stale remote Create objects
  addressed to known group actors.

  A discussion is kept if a local non-group user has interacted with it. That
  includes local replies in the same context, local likes/reactions/repeats, and
  local bookmarks. Local Group actors are intentionally ignored here because
  group mirroring can create automatic local activities that should not pin the
  remote discussion forever.
  """

  use Oban.Worker, queue: "background"

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo

  @default_max_age_days 183
  @default_batch_size 200
  @seconds_per_day 86_400
  @group_service_actor_regex "fedigroups|gancio|gup\\.pe|buzzrelay|tootgroup"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?() do
      {:ok, purge_candidates()}
    else
      {:ok, 0}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  defp purge_candidates do
    cutoff = cutoff()
    batch_size = batch_size()

    cutoff
    |> candidates_query(batch_size)
    |> Repo.all(timeout: :infinity)
    |> Enum.reduce(0, &delete_object/2)
  end

  defp delete_object(%Object{} = object, count) do
    case Object.delete(object) do
      {:ok, _object, _activity} -> count + 1
      _ -> count
    end
  end

  defp candidates_query(cutoff, batch_size) do
    from(activity in Activity,
      join: object in Object,
      on:
        fragment(
          "(?->>'id') = associated_object_id(?)",
          object.data,
          activity.data
        ),
      where: activity.local == false,
      where: activity.inserted_at < ^cutoff,
      where: fragment("?->>'type' = 'Create'", activity.data),
      where:
        fragment(
          "?->>'type' in ('Note', 'Article', 'Page', 'Question', 'Event', 'Audio', 'Video')",
          object.data
        ),
      where: ^addressed_to_remote_group?(),
      where: ^no_local_user_activity?(),
      where: ^no_local_bookmark?(),
      distinct: object.id,
      limit: ^batch_size,
      select: object
    )
  end

  defp addressed_to_remote_group? do
    group_service_actor_regex = @group_service_actor_regex

    dynamic(
      [activity, object],
      fragment(
        """
        EXISTS (
          SELECT 1
          FROM users AS group_actor
          WHERE group_actor.local = false
            AND group_actor.is_active = true
            AND group_actor.invisible = false
            AND (
              group_actor.actor_type = 'Group'
              OR (
                group_actor.actor_type IN ('Application', 'Service')
                AND group_actor.ap_id ~* ?
              )
            )
            AND (
              (?->'to') \\? group_actor.ap_id
              OR (?->'cc') \\? group_actor.ap_id
              OR (?->'bto') \\? group_actor.ap_id
              OR (?->'bcc') \\? group_actor.ap_id
              OR (?->'to') \\? group_actor.ap_id
              OR (?->'cc') \\? group_actor.ap_id
              OR (?->'bto') \\? group_actor.ap_id
              OR (?->'bcc') \\? group_actor.ap_id
              OR ?->>'target' = group_actor.ap_id
              OR ?->>'context' = group_actor.ap_id
            )
        )
        """,
        ^group_service_actor_regex,
        object.data,
        object.data,
        object.data,
        object.data,
        activity.data,
        activity.data,
        activity.data,
        activity.data,
        object.data,
        object.data
      )
    )
  end

  defp no_local_user_activity? do
    dynamic(
      [_activity, object],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM activities AS local_activity
          JOIN users AS local_user ON local_user.ap_id = local_activity.actor
          LEFT JOIN objects AS local_object
            ON local_object.data->>'id' = associated_object_id(local_activity.data)
          WHERE local_activity.local = true
            AND local_user.local = true
            AND COALESCE(local_user.actor_type, 'Person') <> 'Group'
            AND (
              local_activity.data->>'object' = ?->>'id'
              OR associated_object_id(local_activity.data) = ?->>'id'
              OR local_object.data->>'inReplyTo' = ?->>'id'
              OR (
                ?->>'context' IS NOT NULL
                AND local_activity.data->>'context' = ?->>'context'
              )
            )
        )
        """,
        object.data,
        object.data,
        object.data,
        object.data,
        object.data
      )
    )
  end

  defp no_local_bookmark? do
    dynamic(
      [activity, _object],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM bookmarks AS bookmark
          JOIN users AS bookmark_user ON bookmark_user.id = bookmark.user_id
          WHERE bookmark.activity_id = ?
            AND bookmark_user.local = true
        )
        """,
        activity.id
      )
    )
  end

  defp enabled? do
    Config.get([__MODULE__, :enabled], true)
  end

  defp cutoff do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-max_age_days() * @seconds_per_day, :second)
  end

  defp max_age_days do
    __MODULE__
    |> config_integer(:max_age_days, @default_max_age_days)
    |> max(1)
  end

  defp batch_size do
    __MODULE__
    |> config_integer(:batch_size, @default_batch_size)
    |> max(1)
  end

  defp config_integer(module, key, default) do
    case Config.get([module, key], default) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end
end
