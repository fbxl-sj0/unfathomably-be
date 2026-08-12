# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearch do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object.Fetcher
  alias Pleroma.Pagination
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Visibility

  require Pleroma.Constants

  import Ecto.Query

  @behaviour Pleroma.Search.SearchBackend

  @impl true
  def search(user, search_query, options \\ []) do
    index_type = if Config.get([:database, :rum_enabled]), do: :rum, else: :gin
    limit = Enum.min([Keyword.get(options, :limit), 40])
    offset = Keyword.get(options, :offset, 0)
    author = Keyword.get(options, :author)

    try do
      Activity
      |> Activity.with_preloaded_object()
      |> Activity.restrict_deactivated_users()
      |> restrict_public(user)
      |> query_with(index_type, search_query)
      |> maybe_restrict_local(user)
      |> maybe_restrict_author(author)
      |> maybe_restrict_blocked(user)
      |> Pagination.fetch_paginated(
        %{"offset" => offset, "limit" => limit, "skip_order" => index_type == :rum},
        :offset
      )
      |> maybe_fetch(user, search_query)
    rescue
      _ -> maybe_fetch([], user, search_query)
    end
  end

  @impl true
  def add_to_index(_activity), do: :ok

  @impl true
  def remove_from_index(_object), do: :ok

  @impl true
  def healthcheck_endpoints, do: nil

  def maybe_restrict_author(query, %User{} = author) do
    Activity.Queries.by_author(query, author)
  end

  def maybe_restrict_author(query, _), do: query

  def maybe_restrict_blocked(query, %User{} = user) do
    Activity.Queries.exclude_authors(query, User.blocked_users_ap_ids(user))
  end

  def maybe_restrict_blocked(query, _), do: query

  defp restrict_public(q, user) when not is_nil(user) do
    intended_recipients = [
      Pleroma.Constants.as_public(),
      Pleroma.Web.ActivityPub.Utils.as_local_public()
    ]

    from([a, o] in q,
      where: fragment("?->>'type' = 'Create'", a.data),
      where: fragment("? && ?", ^intended_recipients, a.recipients)
    )
  end

  defp restrict_public(q, _user) do
    from([a, o] in q,
      where: fragment("?->>'type' = 'Create'", a.data),
      where: ^Pleroma.Constants.as_public() in a.recipients
    )
  end

  defp query_with(q, :gin, search_query) do
    %{rows: [[tsc]]} =
      Ecto.Adapters.SQL.query!(
        Pleroma.Repo,
        "select current_setting('default_text_search_config')::regconfig::oid;"
      )

    query_with_gin(q, search_query, tsc, search_function())
  end

  defp query_with(q, :rum, search_query) do
    query_with_rum(q, search_query, search_function())
  end

  defp query_with_gin(q, search_query, tsc, :websearch) do
    from([a, o] in q,
      where:
        fragment(
          """
          to_tsvector(
            ?::oid::regconfig,
            COALESCE(?->>'summary', '') || ' ' || (?->>'content')
          ) @@ websearch_to_tsquery(?)
          """,
          ^tsc,
          o.data,
          o.data,
          ^search_query
        ),
      order_by: [desc: :inserted_at]
    )
  end

  defp query_with_gin(q, search_query, tsc, :plain) do
    from([a, o] in q,
      where:
        fragment(
          """
          to_tsvector(
            ?::oid::regconfig,
            COALESCE(?->>'summary', '') || ' ' || (?->>'content')
          ) @@ plainto_tsquery(?)
          """,
          ^tsc,
          o.data,
          o.data,
          ^search_query
        ),
      order_by: [desc: :inserted_at]
    )
  end

  defp query_with_rum(q, search_query, :websearch) do
    from([a, o] in q,
      where:
        fragment(
          "? @@ websearch_to_tsquery(?)",
          o.fts_content,
          ^search_query
        ),
      order_by: [fragment("? <=> now()::date", o.inserted_at)]
    )
  end

  defp query_with_rum(q, search_query, :plain) do
    from([a, o] in q,
      where:
        fragment(
          "? @@ plainto_tsquery(?)",
          o.fts_content,
          ^search_query
        ),
      order_by: [fragment("? <=> now()::date", o.inserted_at)]
    )
  end

  defp search_function do
    case :persistent_term.get({Pleroma.Repo, :postgres_version}, nil) do
      version when is_integer(version) and version < 110_000 -> :plain
      version when is_float(version) and version < 11.0 -> :plain
      _ -> :websearch
    end
  end

  def maybe_restrict_local(q, user) do
    limit = Config.get([:instance, :limit_to_local_content], :unauthenticated)

    case {limit, user} do
      {:all, _} -> restrict_local(q)
      {:unauthenticated, %User{}} -> q
      {:unauthenticated, _} -> restrict_local(q)
      {false, _} -> q
    end
  end

  defp restrict_local(q), do: where(q, local: true)

  def maybe_fetch(activities, user, search_query) do
    if Regex.match?(~r/https?:/, search_query) do
      case Fetcher.fetch_object_from_id(search_query) do
        {:ok, object} ->
          prepend_visible_activity(activities, user, fetched_search_activity(object))

        _ ->
          maybe_fetch_public_event(activities, user, search_query)
      end
    else
      activities
    end
  end

  # Some event platforms expose a public Event object at its canonical URL but
  # do not publish the matching Create activity. Search normally renders
  # statuses from Create activities, so accept this narrow compatibility form
  # only after the normal incoming pipeline verifies the actor, containment,
  # recipients, and object schema. Arbitrary object-only URLs must never gain
  # a synthetic status through this path.
  defp fetched_search_activity(%{data: %{"id" => object_id} = object})
       when is_binary(object_id) do
    Activity.get_create_by_object_ap_id(object_id) ||
      maybe_create_public_event_activity(object)
  end

  defp fetched_search_activity(_object), do: nil

  defp maybe_fetch_public_event(activities, user, event_url) do
    with {:ok, event} <- Fetcher.fetch_and_contain_remote_object_from_id(event_url) do
      prepend_visible_activity(activities, user, maybe_create_public_event_activity(event))
    else
      _ -> activities
    end
  end

  defp prepend_visible_activity(activities, user, %Activity{} = activity) do
    if Visibility.visible_for_user?(activity, user), do: [activity | activities], else: activities
  end

  defp prepend_visible_activity(activities, _user, _activity), do: activities

  defp maybe_create_public_event_activity(
         %{"id" => object_id, "type" => "Event", "actor" => actor} = object
       )
       when is_binary(object_id) and is_binary(actor) do
    with true <- public_event?(object),
         %{} = create <- public_event_create_activity(object, actor),
         {:ok, %Activity{}} <- Transmogrifier.handle_incoming(create) do
      Activity.get_create_by_object_ap_id(object_id)
    else
      _ -> nil
    end
  end

  defp maybe_create_public_event_activity(_object), do: nil

  defp public_event_create_activity(%{"id" => _object_id} = object, actor) do
    object =
      object
      |> Map.put("actor", actor)
      |> Map.put("attributedTo", actor)

    %{
      "type" => "Create",
      "actor" => actor,
      "object" => object,
      "to" => event_recipients(object["to"]),
      "cc" => event_recipients(object["cc"])
    }
  end

  defp public_event?(object) do
    recipients = event_recipients(object["to"]) ++ event_recipients(object["cc"])
    Pleroma.Constants.as_public() in recipients
  end

  defp event_recipients(value) when is_binary(value), do: [value]
  defp event_recipients(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp event_recipients(_value), do: []
end
