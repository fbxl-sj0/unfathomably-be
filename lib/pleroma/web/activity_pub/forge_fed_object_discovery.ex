# Project: Unfathomably
# File: forgefed_object_discovery.ex
# Purpose: Search public ForgeFed resources already received through federation.
#
# Responsibilities:
# - discover known ForgeFed resource actors without hostname inference
# - search durable public forge objects and public Push activities
# - preserve project, tracker, author, commit, clone, and resolution context
#
# This file intentionally does not clone repositories, invoke forge write
# operations, expose non-public activities, or treat ordinary web pages as
# ActivityPub actors.

defmodule Pleroma.Web.ActivityPub.ForgeFedObjectDiscovery do
  @moduledoc """
  Local-first discovery for received ForgeFed resources and activity.

  ForgeFed distinguishes resource actors from durable objects and activities.
  The searches below preserve that distinction: repositories and projects come
  from known actors, tickets and commits come from public objects, and pushes
  come from explicitly public activities.
  """

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  @public "https://www.w3.org/ns/activitystreams#Public"
  @actor_types ~w[
    Factory PatchTracker Project ReleaseTracker Repository Roadmap Team
    TicketTracker Workflow
  ]
  @object_types ~w[
    Approval Branch Commit Enum EnumValue Field Milestone Patch Release Review
    SoftwareProject Ticket TicketDependency
  ]
  @lifecycle_activity_types ~w[Apply Assign Resolve]
  @default_limit 18
  @maximum_limit 30
  @maximum_offset 1_000

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query = params |> Map.get("q", "") |> string_value() |> String.trim()
    limit = bounded_integer(Map.get(params, "limit"), @default_limit, 1, @maximum_limit)
    offset = bounded_integer(Map.get(params, "offset"), 0, 0, @maximum_offset)

    fetch_limit = offset + limit + 1

    items =
      if query == "" or String.length(query) >= 2 do
        actor_results(query, fetch_limit, 0) ++
          object_results(query, fetch_limit, 0) ++
          push_results(query, fetch_limit, 0) ++
          lifecycle_results(query, fetch_limit, 0)
      else
        []
      end

    items =
      items
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1["activitypub_url"])
      |> Enum.sort_by(& &1["_sort_at"], {:desc, DateTime})

    page = Enum.drop(items, offset)
    has_more = length(page) > limit

    %{
      "items" => page |> Enum.take(limit) |> Enum.map(&Map.delete(&1, "_sort_at")),
      "has_more" => has_more,
      "next_offset" => if(has_more, do: offset + limit),
      "providers" => [
        %{
          "type" => "local_federation_cache",
          "host" => local_host(),
          "status" => "ready"
        }
      ]
    }
  end

  defp actor_results(query, limit, offset) do
    query
    |> actor_query(limit, offset)
    |> Repo.all(timeout: 30_000)
    |> Enum.map(&normalize_actor/1)
  end

  defp actor_query(query, limit, offset) do
    base_query =
      from(user in User,
        where: user.local == false,
        where: user.is_active == true,
        where: user.invisible == false,
        where: user.actor_type in ^@actor_types,
        order_by: [desc: user.updated_at, desc: user.id],
        limit: ^limit,
        offset: ^offset
      )

    if query == "" do
      base_query
    else
      from(user in base_query,
        where:
          fragment(
            """
            unfathomably_forgefed_actor_search_document(
              ?, ?, ?, ?, ?
            ) @@ websearch_to_tsquery('simple', ?)
            """,
            user.nickname,
            user.name,
            user.bio,
            user.ap_id,
            user.actor_extensions,
            ^query
          )
      )
    end
  end

  defp object_results(query, limit, offset) do
    query
    |> object_query(limit, offset)
    |> Repo.all(timeout: 30_000)
    |> Enum.map(&normalize_object/1)
  end

  defp object_query(query, limit, offset) do
    public_recipient = @public

    base_query =
      from(activity in Activity,
        join: object in Object,
        on:
          fragment(
            "(?->>'id') = associated_object_id(?)",
            object.data,
            activity.data
          ),
        where: fragment("?->>'type' IN ('Create', 'Update')", activity.data),
        where:
          fragment(
            """
            ?->>'type' IN (
              'Approval', 'Branch', 'Commit', 'Enum', 'EnumValue', 'Field',
              'Milestone', 'Patch', 'Release', 'Review', 'Ticket',
              'TicketDependency', 'https://unfathomably.social/ns#SoftwareProject'
            )
            """,
            object.data
          ),
        where:
          fragment(
            """
            jsonb_exists(coalesce(?->'to', '[]'::jsonb), ?) OR
            jsonb_exists(coalesce(?->'cc', '[]'::jsonb), ?) OR
            ?->>'to' = ? OR
            ?->>'cc' = ? OR
            jsonb_exists(coalesce(?->'to', '[]'::jsonb), ?) OR
            jsonb_exists(coalesce(?->'cc', '[]'::jsonb), ?) OR
            ?->>'to' = ? OR
            ?->>'cc' = ?
            """,
            object.data,
            ^public_recipient,
            object.data,
            ^public_recipient,
            object.data,
            ^@public,
            object.data,
            ^@public,
            activity.data,
            ^public_recipient,
            activity.data,
            ^public_recipient,
            activity.data,
            ^@public,
            activity.data,
            ^@public
          ),
        order_by: [desc: activity.inserted_at, desc: activity.id],
        limit: ^limit,
        offset: ^offset,
        select: {activity, object}
      )

    if query == "" do
      base_query
    else
      from([_activity, object] in base_query,
        where:
          fragment(
            "unfathomably_forgefed_object_search_document(?) @@ websearch_to_tsquery('simple', ?)",
            object.data,
            ^query
          )
      )
    end
  end

  defp push_results(query, limit, offset) do
    query
    |> push_query(limit, offset)
    |> Repo.all(timeout: 30_000)
    |> Enum.map(&normalize_push/1)
  end

  defp push_query(query, limit, offset) do
    public_recipient = @public

    base_query =
      from(activity in Activity,
        where: activity.local == false,
        where: fragment("?->>'type' = 'Push'", activity.data),
        where:
          fragment(
            """
            jsonb_exists(coalesce(?->'to', '[]'::jsonb), ?) OR
            jsonb_exists(coalesce(?->'cc', '[]'::jsonb), ?) OR
            ?->>'to' = ? OR
            ?->>'cc' = ?
            """,
            activity.data,
            ^public_recipient,
            activity.data,
            ^public_recipient,
            activity.data,
            ^@public,
            activity.data,
            ^@public
          ),
        order_by: [desc: activity.inserted_at, desc: activity.id],
        limit: ^limit,
        offset: ^offset
      )

    if query == "" do
      base_query
    else
      from(activity in base_query,
        where:
          fragment(
            "unfathomably_forgefed_push_search_document(?) @@ websearch_to_tsquery('simple', ?)",
            activity.data,
            ^query
          )
      )
    end
  end

  defp normalize_actor(%User{} = user) do
    extensions = user.actor_extensions || %{}
    actor_url = reference_url(user.ap_id)
    source_url = reference_url(user.uri) || actor_url
    title = clean_text(user.name, 300) || clean_text(user.nickname, 300)
    type = short_type(user.actor_type)
    component_urls = forgefed_collection_urls(extensions["components"], 8)
    subproject_urls = forgefed_collection_urls(extensions["subprojects"], 8)
    fork_urls = forgefed_collection_urls(extensions["forks"], 8)

    with type when type in @actor_types <- type,
         actor_url when is_binary(actor_url) <- actor_url,
         title when is_binary(title) <- title do
      %{
        "id" => user.id,
        "family" => "development",
        "kind" => kind_for_type(type),
        "object_type" => type,
        "title" => title,
        "summary" => user.bio |> plain_text() |> truncate(900),
        "url" => source_url,
        "activitypub_url" => actor_url,
        "source_host" => source_host(actor_url),
        "clone_url" => extension_reference(extensions, ["cloneUri", "cloneURI"]),
        "push_url" => extension_reference(extensions, ["pushUri", "pushURI"]),
        "context_url" => extension_reference(extensions, ["context"]),
        "tracker_url" => extension_reference(extensions, ["ticketsTrackedBy"]),
        "patch_tracker_url" => extension_reference(extensions, ["sendPatchesTo"]),
        "component_urls" => component_urls,
        "component_count" => forgefed_collection_count(extensions["components"], component_urls),
        "subproject_urls" => subproject_urls,
        "subproject_count" =>
          forgefed_collection_count(extensions["subprojects"], subproject_urls),
        "fork_urls" => fork_urls,
        "fork_count" => forgefed_collection_count(extensions["forks"], fork_urls),
        "team_url" => reference_url(extensions["team"]),
        "is_archived" => extensions["isArchived"] == true,
        "moved_to_url" => reference_url(extensions["movedTo"]),
        "topics" => extension_tags(extensions["tag"]),
        "updated_at" => iso8601(user.updated_at),
        "local_action" => "resolve",
        "_sort_at" => sort_datetime(user.updated_at)
      }
    else
      _ -> nil
    end
  end

  defp normalize_actor(_), do: nil

  defp normalize_object({activity, object}) do
    data = object.data || %{}
    type = short_type(data["type"])
    activitypub_url = reference_url(data["id"])
    source_url = reference_url(data["url"]) || activitypub_url
    author_url = reference_url(data["attributedTo"] || data["actor"])
    context_url = reference_url(data["context"])
    ticket_offer = forgefed_ticket_offer(data["attachment"])

    with type when type in @object_types <- type,
         activitypub_url when is_binary(activitypub_url) <- activitypub_url,
         title when is_binary(title) <- object_title(type, data) do
      %{
        "id" => activity.id,
        "family" => "development",
        "kind" => kind_for_type(type),
        "object_type" => type,
        "title" => title,
        "summary" => object_summary(type, data),
        "url" => source_url,
        "activitypub_url" => activitypub_url,
        "source_host" => source_host(source_url || activitypub_url),
        "author_url" => author_url,
        "author_label" => reference_label(author_url),
        "context_url" => context_url,
        "context_label" => reference_label(context_url),
        "ticket_kind" => forgefed_ticket_kind(type, ticket_offer),
        "can_file_locally" => activity.local == true and type == "SoftwareProject",
        "is_wip" => type == "Ticket" and data["isWip"] == true,
        "origin_url" => forgefed_offer_reference(ticket_offer, "origin"),
        "origin_label" => forgefed_offer_label(ticket_offer, "origin"),
        "target_url" => forgefed_offer_reference(ticket_offer, "target"),
        "target_label" => forgefed_offer_label(ticket_offer, "target"),
        "diff_url" => ticket_offer |> forgefed_offer_value("mrDiff") |> reference_url(),
        "patch_count" => forgefed_patch_count(ticket_offer),
        "required_approvals" => forgefed_non_negative_integer(data["requiredApprovalsNeeded"]),
        "given_approvals" => forgefed_non_negative_integer(data["requiredApprovalsGiven"]),
        "replies_url" => reference_url(data["replies"]),
        "dependencies_url" => reference_url(data["dependencies"]),
        "dependants_url" => reference_url(data["dependants"]),
        "assignee_urls" => forgefed_collection_urls(data["assignedTo"], 8),
        "milestone_url" => reference_url(data["milestone"]),
        "resolved_by_url" => reference_url(data["resolvedBy"]),
        "committed_by_url" => reference_url(data["committedBy"]),
        "created_at" => scalar_datetime(data["created"]),
        "committed_at" => scalar_datetime(data["committed"]),
        "status" => object_status(type, data),
        "hash" => clean_text(data["hash"], 160),
        "branch" => clean_text(data["name"] || data["ref"], 240),
        "published_at" => scalar_datetime(data["published"] || data["created"]),
        "resolved_at" => scalar_datetime(data["resolved"]),
        "topics" => object_tags(data["tag"]),
        "local_action" => "resolve",
        "_sort_at" => sort_datetime(activity.inserted_at)
      }
    else
      _ -> nil
    end
  end

  defp normalize_object(_), do: nil

  defp normalize_push(%Activity{} = activity) do
    data = activity.data || %{}
    activitypub_url = reference_url(data["id"])
    repository_url = reference_url(data["actor"])
    author_url = reference_url(data["attributedTo"])
    context_url = reference_url(data["context"]) || repository_url
    target_url = reference_url(data["target"])
    commits = normalize_commits(data["object"])

    with activitypub_url when is_binary(activitypub_url) <- activitypub_url,
         repository_url when is_binary(repository_url) <- repository_url do
      %{
        "id" => activity.id,
        "family" => "development",
        "kind" => "push",
        "object_type" => "Push",
        "title" => push_title(data, repository_url, target_url),
        "summary" => data["summary"] |> plain_text() |> truncate(900),
        "url" => activitypub_url,
        "activitypub_url" => activitypub_url,
        "source_host" => source_host(repository_url),
        "author_url" => author_url,
        "author_label" => reference_label(author_url),
        "context_url" => context_url,
        "context_label" => reference_label(context_url),
        "target_url" => target_url,
        "branch" => reference_label(target_url),
        "hash_before" => clean_text(data["hashBefore"], 160),
        "hash_after" => clean_text(data["hashAfter"], 160),
        "commit_count" => commit_count(data["object"], commits),
        "commits" => commits,
        "published_at" => scalar_datetime(data["published"]),
        "topics" => [],
        "local_action" => "resolve",
        "_sort_at" => sort_datetime(activity.inserted_at)
      }
    else
      _ -> nil
    end
  end

  defp normalize_push(_), do: nil

  defp lifecycle_results(query, limit, offset) do
    query
    |> lifecycle_query(limit, offset)
    |> Repo.all(timeout: 30_000)
    |> Enum.map(&normalize_lifecycle_activity/1)
  end

  defp lifecycle_query(query, limit, offset) do
    public_recipient = @public

    base_query =
      from(activity in Activity,
        where: activity.local == false,
        where: fragment("?->>'type' IN ('Apply', 'Assign', 'Resolve')", activity.data),
        where:
          fragment(
            """
            jsonb_exists(coalesce(?->'to', '[]'::jsonb), ?) OR
            jsonb_exists(coalesce(?->'cc', '[]'::jsonb), ?) OR
            ?->>'to' = ? OR
            ?->>'cc' = ?
            """,
            activity.data,
            ^public_recipient,
            activity.data,
            ^public_recipient,
            activity.data,
            ^@public,
            activity.data,
            ^@public
          ),
        order_by: [desc: activity.inserted_at, desc: activity.id],
        limit: ^limit,
        offset: ^offset
      )

    if query == "" do
      base_query
    else
      from(activity in base_query,
        where:
          fragment(
            """
            to_tsvector(
              'simple',
              coalesce(?->>'summary', '') || ' ' ||
              coalesce(?->>'actor', '') || ' ' ||
              coalesce(?->>'object', '') || ' ' ||
              coalesce(?->>'target', '') || ' ' ||
              coalesce(?->>'context', '')
            ) @@ websearch_to_tsquery('simple', ?)
            """,
            activity.data,
            activity.data,
            activity.data,
            activity.data,
            activity.data,
            ^query
          )
      )
    end
  end

  defp normalize_lifecycle_activity(%Activity{} = activity) do
    data = activity.data || %{}
    type = short_type(data["type"])
    activitypub_url = reference_url(data["id"])
    author_url = reference_url(data["actor"])
    object_url = reference_url(data["object"])
    target_url = reference_url(data["target"])
    context_url = reference_url(data["context"])
    source_url = context_url || target_url || object_url || author_url

    with type when type in @lifecycle_activity_types <- type,
         activitypub_url when is_binary(activitypub_url) <- activitypub_url,
         author_url when is_binary(author_url) <- author_url,
         source_url when is_binary(source_url) <- source_url do
      %{
        "id" => activity.id,
        "family" => "development",
        "kind" => type |> Macro.underscore(),
        "object_type" => type,
        "title" => lifecycle_activity_title(type, object_url, target_url),
        "summary" => data["summary"] |> plain_text() |> truncate(900),
        "url" => activitypub_url,
        "activitypub_url" => activitypub_url,
        "source_host" => source_host(source_url),
        "author_url" => author_url,
        "author_label" => reference_label(author_url),
        "object_url" => object_url,
        "object_label" => reference_label(object_url),
        "target_url" => target_url,
        "target_label" => reference_label(target_url),
        "context_url" => context_url,
        "context_label" => reference_label(context_url),
        "status" => lifecycle_activity_status(type),
        "published_at" => scalar_datetime(data["published"]),
        "topics" => [],
        "local_action" => "resolve",
        "_sort_at" => sort_datetime(activity.inserted_at)
      }
    else
      _ -> nil
    end
  end

  defp normalize_lifecycle_activity(_activity), do: nil

  defp lifecycle_activity_title("Assign", object_url, _target_url),
    do: "Assignment for #{reference_label(object_url) || "development resource"}"

  defp lifecycle_activity_title("Resolve", object_url, _target_url),
    do: "Resolved #{reference_label(object_url) || "development resource"}"

  defp lifecycle_activity_title("Apply", object_url, target_url),
    do:
      "Apply #{reference_label(object_url) || "proposed changes"} to #{reference_label(target_url) || "repository"}"

  defp lifecycle_activity_status("Assign"), do: "assigned"
  defp lifecycle_activity_status("Resolve"), do: "resolved"
  defp lifecycle_activity_status("Apply"), do: "applied"

  defp object_title("Ticket", data) do
    clean_text(data["summary"] || data["name"], 300)
  end

  defp object_title("Commit", data) do
    clean_text(data["summary"], 300) ||
      prefixed_identifier("Commit", data["hash"])
  end

  defp object_title(type, data) when type in ~w[Branch Milestone Release] do
    clean_text(data["name"] || data["summary"], 300) ||
      prefixed_identifier(type, data["id"])
  end

  defp object_title(type, data) do
    clean_text(data["name"] || data["summary"], 300) ||
      prefixed_identifier(type, data["id"])
  end

  defp object_summary("Ticket", data) do
    data["content"] |> plain_text() |> truncate(900)
  end

  defp object_summary("Commit", data) do
    (forgefed_content(data["description"]) || data["content"])
    |> plain_text()
    |> truncate(900)
  end

  defp object_summary(_type, data) do
    (data["content"] || data["summary"]) |> plain_text() |> truncate(900)
  end

  defp object_status("Ticket", %{"isResolved" => true}), do: "resolved"
  defp object_status("Ticket", %{"isResolved" => false}), do: "open"
  defp object_status("Ticket", data), do: clean_text(data["state"], 100)
  defp object_status("SoftwareProject", data), do: clean_text(data["projectStatus"], 100)
  defp object_status("Approval", _data), do: "approved"
  defp object_status("Review", data), do: clean_text(data["status"], 100)
  defp object_status(_type, _data), do: nil

  defp push_title(data, repository_url, target_url) do
    data["summary"]
    |> plain_text()
    |> truncate(300)
    |> case do
      title when is_binary(title) -> title
      _ -> "Push to #{reference_label(target_url || repository_url) || "repository"}"
    end
  end

  defp normalize_commits(%{} = collection) do
    (collection["orderedItems"] || collection["items"] || [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = commit ->
        hash = clean_text(commit["hash"], 160)
        summary = clean_text(commit["summary"] || commit["name"], 300)
        url = reference_url(commit["id"] || commit["url"])

        if hash || summary || url do
          [
            %{
              "hash" => hash,
              "summary" => summary,
              "url" => url,
              "author_url" => reference_url(commit["attributedTo"]),
              "author_label" => commit["attributedTo"] |> reference_url() |> reference_label(),
              "committed_by_url" => reference_url(commit["committedBy"]),
              "context_url" => reference_url(commit["context"]),
              "created_at" => scalar_datetime(commit["created"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.take(5)
  end

  defp normalize_commits(_), do: []

  defp commit_count(%{"totalItems" => count}, _commits)
       when is_integer(count) and count >= 0,
       do: count

  defp commit_count(_collection, commits), do: length(commits)

  defp kind_for_type("Project"), do: "project"
  defp kind_for_type("SoftwareProject"), do: "project"
  defp kind_for_type("Repository"), do: "repository"
  defp kind_for_type("TicketTracker"), do: "ticket_tracker"
  defp kind_for_type("PatchTracker"), do: "patch_tracker"
  defp kind_for_type("ReleaseTracker"), do: "release_tracker"
  defp kind_for_type("Ticket"), do: "ticket"
  defp kind_for_type(type), do: type |> Macro.underscore()

  defp short_type(value) when is_binary(value) do
    value
    |> String.split(["#", "/", ":"], trim: true)
    |> List.last()
  end

  defp short_type(_), do: nil

  defp prefixed_identifier(prefix, value) do
    case clean_text(value, 240) do
      value when is_binary(value) -> "#{prefix} #{String.slice(value, 0, 16)}"
      _ -> nil
    end
  end

  defp extension_reference(extensions, keys) do
    Enum.find_value(keys, fn key -> reference_url(extensions[key]) end)
  end

  defp extension_tags(tags), do: object_tags(tags)

  defp forgefed_collection_urls(%{} = collection, limit) do
    (collection["orderedItems"] || collection["items"] || [])
    |> forgefed_collection_urls(limit)
  end

  defp forgefed_collection_urls(values, limit) when is_list(values) do
    values
    |> Enum.map(&reference_url/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  defp forgefed_collection_urls(value, limit) do
    case reference_url(value) do
      url when is_binary(url) -> [url] |> Enum.take(limit)
      _ -> []
    end
  end

  defp forgefed_collection_count(%{"totalItems" => count}, _urls)
       when is_integer(count) and count >= 0,
       do: count

  defp forgefed_collection_count(_collection, urls), do: length(urls)

  defp forgefed_ticket_offer(attachments) do
    attachments
    |> List.wrap()
    |> Enum.find(fn
      %{"type" => type} -> short_type(type) == "Offer"
      _ -> false
    end)
  end

  defp forgefed_ticket_kind("Ticket", %{}), do: "merge_request"
  defp forgefed_ticket_kind("Ticket", _offer), do: "issue"
  defp forgefed_ticket_kind(_type, _offer), do: nil

  defp forgefed_offer_value(%{} = offer, key), do: offer[key]
  defp forgefed_offer_value(_offer, _key), do: nil

  defp forgefed_offer_reference(%{} = offer, key) do
    value = offer[key]
    reference_url(value) || if(is_map(value), do: reference_url(value["context"]))
  end

  defp forgefed_offer_reference(_offer, _key), do: nil

  defp forgefed_offer_label(%{} = offer, key) do
    value = offer[key]

    cond do
      is_map(value) and is_binary(value["ref"]) ->
        clean_text(value["ref"], 240)

      true ->
        value |> reference_url() |> reference_label()
    end
  end

  defp forgefed_offer_label(_offer, _key), do: nil

  defp forgefed_patch_count(%{"object" => %{"totalItems" => count}})
       when is_integer(count) and count >= 0,
       do: count

  defp forgefed_patch_count(%{"object" => %{} = collection}) do
    collection
    |> Map.get("orderedItems", Map.get(collection, "items", []))
    |> List.wrap()
    |> length()
  end

  defp forgefed_patch_count(_offer), do: nil

  defp forgefed_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp forgefed_non_negative_integer(_value), do: nil

  defp forgefed_content(%{"content" => content}) when is_binary(content), do: content
  defp forgefed_content(content) when is_binary(content), do: content
  defp forgefed_content(_content), do: nil

  defp object_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) ->
        [name |> String.trim_leading("#") |> clean_text(80)]

      name when is_binary(name) ->
        [name |> String.trim_leading("#") |> clean_text(80)]

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(12)
  end

  defp reference_label(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) ->
        tail =
          path
          |> to_string()
          |> String.split("/", trim: true)
          |> Enum.take(-2)
          |> Enum.join("/")

        if tail == "", do: String.downcase(host), else: "#{String.downcase(host)}/#{tail}"

      _ ->
        nil
    end
  end

  defp reference_label(_), do: nil

  defp reference_url(%URI{} = value), do: reference_url(URI.to_string(value))

  defp reference_url(value) when is_binary(value) do
    value = String.trim(value)

    with true <- byte_size(value) <= 2_048,
         %URI{scheme: scheme, host: host, userinfo: nil} <- URI.parse(value),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "" do
      value
    else
      _ -> nil
    end
  end

  defp reference_url(%{"url" => value}), do: reference_url(value)
  defp reference_url(%{"href" => value}), do: reference_url(value)
  defp reference_url(%{"id" => value}), do: reference_url(value)
  defp reference_url(%{"@id" => value}), do: reference_url(value)

  defp reference_url(values) when is_list(values) do
    Enum.find_value(values, &reference_url/1)
  end

  defp reference_url(_), do: nil

  defp scalar_datetime(value) when is_binary(value), do: clean_text(value, 120)
  defp scalar_datetime(_), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_), do: nil

  defp sort_datetime(%DateTime{} = value), do: value

  defp sort_datetime(%NaiveDateTime{} = value) do
    DateTime.from_naive!(value, "Etc/UTC")
  end

  defp sort_datetime(_), do: DateTime.from_unix!(0)

  defp plain_text(value) when is_binary(value) do
    value
    |> Pleroma.HTML.strip_non_content()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> blank_to_nil()
  end

  defp plain_text(_), do: nil

  defp clean_text(value, maximum) when is_binary(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(maximum)
    |> blank_to_nil()
  end

  defp clean_text(_, _), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp truncate(nil, _maximum), do: nil
  defp truncate(value, maximum) when byte_size(value) <= maximum, do: value

  defp truncate(value, maximum) do
    value
    |> String.slice(0, maximum)
    |> Kernel.<>("...")
  end

  defp source_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end

  defp source_host(_), do: nil

  defp bounded_integer(value, default, minimum, maximum) do
    parsed =
      case value do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {integer, ""} -> integer
            _ -> default
          end

        _ ->
          default
      end

    parsed
    |> max(minimum)
    |> min(maximum)
  end

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_), do: ""

  defp local_host do
    Config.get([Pleroma.Web.Endpoint, :url, :host], "local")
  end
end

# end of forgefed_object_discovery.ex
