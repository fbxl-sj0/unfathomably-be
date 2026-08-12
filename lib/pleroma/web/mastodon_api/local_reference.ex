# Unfathomably Backend
#
# File: local_reference.ex
#
# Purpose:
#   Map canonical ActivityPub links in rendered content to known local routes.
#
# Responsibilities:
#   - parse sanitized HTML without regular-expression rewriting
#   - bound reference extraction for a status page
#   - resolve cached actors and visible stored objects in bulk
#   - return mappings scoped to the status that contained each link
#
# This file intentionally does not fetch remote URLs, mutate stored content,
# change link labels, or bypass status visibility checks.

defmodule Pleroma.Web.MastodonAPI.LocalReference do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Visibility

  @maximum_references_per_status 32
  @maximum_references_per_page 200
  @maximum_url_bytes 2_048

  @doc "Resolve canonical links from sanitized status HTML to local FE routes."
  def for_statuses(entries, reading_user) when is_list(entries) do
    candidates_by_activity = collect_candidates(entries)

    canonical_urls =
      candidates_by_activity
      |> Map.values()
      |> List.flatten()
      |> Enum.map(fn {_original, canonical} -> canonical end)
      |> Enum.uniq()
      |> Enum.take(@maximum_references_per_page)

    resolved = resolve_urls(canonical_urls, reading_user)

    Map.new(candidates_by_activity, fn {activity_id, candidates} ->
      references =
        candidates
        |> Enum.reduce(%{}, fn {original, canonical}, result ->
          case Map.fetch(resolved, canonical) do
            {:ok, route} -> Map.put(result, original, route)
            :error -> result
          end
        end)

      {activity_id, references}
    end)
  end

  def for_statuses(_entries, _reading_user), do: %{}

  defp collect_candidates(entries) do
    entries
    |> Enum.reduce({%{}, 0}, fn
      {%Activity{id: activity_id}, html}, {result, count}
      when is_binary(html) and count < @maximum_references_per_page ->
        remaining = @maximum_references_per_page - count

        candidates =
          html
          |> extract_candidates()
          |> Enum.take(min(remaining, @maximum_references_per_status))

        {Map.put(result, activity_id, candidates), count + length(candidates)}

      {%Activity{id: activity_id}, _html}, {result, count} ->
        {Map.put_new(result, activity_id, []), count}

      _invalid, state ->
        state
    end)
    |> elem(0)
  end

  defp extract_candidates(html) do
    with {:ok, nodes} <- Floki.parse_fragment(html) do
      nodes
      |> Floki.attribute("a", "href")
      |> Enum.uniq()
      |> Enum.flat_map(fn href ->
        case canonical_http_url(href) do
          {:ok, canonical} -> [{href, canonical}]
          :error -> []
        end
      end)
    else
      _invalid -> []
    end
  rescue
    _error -> []
  catch
    _, _error -> []
  end

  defp canonical_http_url(url)
       when is_binary(url) and byte_size(url) > 0 and byte_size(url) <= @maximum_url_bytes do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, URI.to_string(%{uri | fragment: nil})}

      _invalid ->
        :error
    end
  rescue
    _error -> :error
  end

  defp canonical_http_url(_url), do: :error

  defp resolve_urls([], _reading_user), do: %{}

  defp resolve_urls(urls, reading_user) do
    actor_routes = resolve_actor_routes(urls)
    object_routes = resolve_object_routes(urls, reading_user)
    Map.merge(actor_routes, object_routes)
  end

  defp resolve_actor_routes(urls) do
    User
    |> where(
      [user],
      user.is_active == true and user.invisible == false and
        (user.ap_id in ^urls or user.uri in ^urls)
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn user, result ->
      case User.full_nickname(user) do
        nickname when is_binary(nickname) and nickname != "" ->
          route = "/@#{nickname}"

          [user.ap_id, user.uri]
          |> Enum.filter(&(&1 in urls))
          |> Enum.reduce(result, &Map.put(&2, &1, route))

        _missing_nickname ->
          result
      end
    end)
  end

  defp resolve_object_routes(urls, reading_user) do
    urls
    |> Activity.create_by_object_ap_id_with_object()
    |> order_by([activity], desc: activity.inserted_at)
    |> Repo.all()
    |> Enum.reduce(%{}, fn activity, result ->
      with true <- Visibility.visible_for_user?(activity, reading_user, nil),
           %Object{data: %{"id" => object_id}} <- Object.normalize(activity, fetch: false),
           true <- object_id in urls do
        Map.put_new(result, object_id, "/notice/#{activity.id}")
      else
        _not_visible_or_invalid -> result
      end
    end)
  end
end

# end of lib/pleroma/web/mastodon_api/local_reference.ex
