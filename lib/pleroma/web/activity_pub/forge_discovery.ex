# Unfathomably forge discovery
# --------------------------------
#
# File: forge_discovery.ex
#
# Purpose:
#   Search reviewed Forgejo catalogues for public software repositories.
#
# Responsibilities:
#   - issue bounded, user-triggered public repository searches
#   - validate repository and owner metadata returned by Forgejo
#   - expose native project pages without claiming every repository is an actor
#   - avoid inventing owner handles when a forge does not advertise federation
#
# This file intentionally does not clone repositories, use private API tokens,
# create issues, or assume experimental ForgeFed repository support is enabled.

defmodule Pleroma.Web.ActivityPub.ForgeDiscovery do
  alias Pleroma.Config
  alias Pleroma.HTTP

  @http_timeout 15_000
  @max_body_bytes 4_000_000
  @max_indexes 3
  @max_results 20

  @type provider_result :: %{
          items: [map()],
          total: non_neg_integer(),
          has_more: boolean(),
          provider: map()
        }

  @spec searches(String.t(), pos_integer(), non_neg_integer()) :: [provider_result()]
  def searches(query, limit, offset)
      when is_binary(query) and is_integer(limit) and limit > 0 and is_integer(offset) and
             offset >= 0 do
    query = query |> String.trim() |> String.slice(0, 200)
    limit = min(limit, @max_results)

    configured_indexes()
    |> Enum.map(&search_index(&1, query, limit, offset))
  end

  def searches(_query, _limit, _offset), do: []

  defp search_index(index, "", _limit, _offset), do: result(index, [], false, "ready")

  defp search_index(index, query, limit, offset) do
    with {:ok, payload} <- fetch_search(index, query, limit, offset),
         repositories when is_list(repositories) <- Map.get(payload, "data") do
      items =
        repositories
        |> Enum.map(&normalize_repository(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(limit)

      has_more = length(repositories) >= limit
      result(index, items, has_more, "ready")
    else
      _ -> result(index, [], false, "unavailable")
    end
  end

  defp fetch_search(index, query, limit, offset) do
    page = div(offset, limit) + 1

    query_string =
      URI.encode_query(%{
        "limit" => limit,
        "order" => "desc",
        "page" => page,
        "q" => query,
        "sort" => "updated"
      })

    url =
      index
      |> URI.parse()
      |> URI.merge("/api/v1/repos/search?" <> query_string)
      |> to_string()

    headers = [{"accept", "application/json"}]

    with {:ok, %{status: 200, body: body}}
         when is_binary(body) and byte_size(body) <= @max_body_bytes <-
           HTTP.get(url, headers, pool: :default, recv_timeout: @http_timeout),
         {:ok, payload} when is_map(payload) <- Jason.decode(body) do
      {:ok, payload}
    else
      _ -> {:error, :provider_unavailable}
    end
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    _, _ -> {:error, :provider_unavailable}
  end

  defp normalize_repository(repository, index) when is_map(repository) do
    host = index |> URI.parse() |> Map.get(:host)
    title = bounded_text(repository["full_name"] || repository["name"], 300)
    project_url = same_origin_url(repository["html_url"], index)
    owner = normalize_owner(repository["owner"], index)

    with host when is_binary(host) <- host,
         title when is_binary(title) <- title,
         project_url when is_binary(project_url) <- project_url,
         %{login: login} = owner when is_binary(login) <- owner do
      %{
        id: "forgejo:" <> String.downcase(host) <> ":" <> title,
        family: "development",
        kind: "repository",
        title: title,
        summary: bounded_text(repository["description"], 1_000),
        url: project_url,
        clone_url: same_origin_url(repository["clone_url"], index),
        website_url: https_url(repository["website"]),
        owner: owner,
        language: bounded_text(repository["language"], 80),
        stars_count: non_negative_integer(repository["stars_count"]),
        forks_count: non_negative_integer(repository["forks_count"]),
        open_issues_count: non_negative_integer(repository["open_issues_count"]),
        topics: bounded_string_list(repository["topics"], 8, 80),
        updated_at: iso8601(repository["updated_at"]),
        source_host: String.downcase(host),
        local_action: "view"
      }
    else
      _ -> nil
    end
  end

  defp normalize_repository(_repository, _index), do: nil

  defp normalize_owner(owner, index) when is_map(owner) do
    login = bounded_text(owner["login"] || owner["username"], 100)
    url = same_origin_url(owner["html_url"], index)

    if valid_login?(login) and is_binary(url) do
      %{login: login, name: bounded_text(owner["full_name"], 200) || login, url: url}
    end
  end

  defp normalize_owner(_owner, _index), do: nil

  defp valid_login?(login) when is_binary(login) do
    String.match?(login, ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\z/)
  end

  defp valid_login?(_login), do: false

  defp bounded_text(value, limit) when is_binary(value) do
    value =
      value
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, limit)

    if value == "", do: nil, else: value
  end

  defp bounded_text(_value, _limit), do: nil

  defp bounded_string_list(values, count, length) when is_list(values) do
    values
    |> Enum.map(&bounded_text(&1, length))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(count)
  end

  defp bounded_string_list(_values, _count, _length), do: []

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> String.slice(value, 0, 40)
      _ -> nil
    end
  end

  defp iso8601(_value), do: nil

  defp same_origin_url(value, index) when is_binary(value) and is_binary(index) do
    index_uri = URI.parse(index)
    uri = URI.parse(value)

    if uri.scheme == "https" and is_binary(uri.host) and uri.userinfo == nil and
         String.downcase(uri.host) == String.downcase(index_uri.host) do
      uri |> URI.to_string() |> String.slice(0, 2_000)
    end
  rescue
    _ -> nil
  end

  defp same_origin_url(_value, _index), do: nil

  defp https_url(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == "https" and is_binary(uri.host) and uri.userinfo == nil do
      uri |> URI.to_string() |> String.slice(0, 2_000)
    end
  rescue
    _ -> nil
  end

  defp https_url(_value), do: nil

  defp result(index, items, has_more, status) do
    %{
      items: items,
      total: length(items),
      has_more: has_more,
      provider: %{
        type: "forgejo",
        host: URI.parse(index).host,
        status: status,
        accepted_peer_count: 0
      }
    }
  end

  defp configured_indexes do
    Config.get([:native_discovery, :forge_indexes], [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&valid_index_url?/1)
    |> Enum.uniq()
    |> Enum.take(@max_indexes)
  end

  defp valid_index_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and path in [nil, "", "/"] ->
        true

      _ ->
        false
    end
  end
end

# end of forge_discovery.ex
