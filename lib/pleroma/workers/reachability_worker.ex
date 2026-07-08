# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReachabilityWorker do
  @moduledoc """
  Checks whether a previously unreachable instance has become reachable again.

  The main publisher path records failures as they happen. This worker is the
  other side of that system: it performs small, low-cost NodeInfo and WebFinger
  probes for a domain and marks the instance reachable again when the remote
  server answers.
  """

  alias Pleroma.HTTP
  alias Pleroma.Instances
  alias Pleroma.Repo
  alias Pleroma.User

  import Ecto.Query

  use Oban.Worker,
    queue: "reachability",
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  @nodeinfo_headers [{"accept", "application/json"}]
  @webfinger_headers [{"accept", "application/jrd+json,application/json"}]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain" => domain}}) when is_binary(domain) do
    case normalize_domain(domain) do
      nil ->
        :discard

      domain ->
        if nodeinfo_reachable?(domain) or webfinger_reachable?(domain) do
          Instances.record_success(domain, source: "reachability")
        else
          Instances.record_failure(domain, :probe_failed, source: "reachability")
          {:error, :unreachable}
        end
    end
  end

  def perform(%Oban.Job{}), do: :discard

  def delete_jobs_for_host(host) when is_binary(host) do
    Oban.Job
    |> where([j], j.worker == "Pleroma.Workers.ReachabilityWorker")
    |> where([j], j.args["domain"] == ^host)
    |> Repo.delete_all()
  end

  def delete_jobs_for_host(_), do: {0, nil}

  defp normalize_domain(domain) do
    domain =
      domain
      |> Instances.host()
      |> case do
        domain when is_binary(domain) -> String.trim(domain)
        _ -> ""
      end

    if domain != "" and not String.match?(domain, ~r/\s/) and
         not String.contains?(domain, ["/", "\\"]) do
      domain
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp nodeinfo_reachable?(domain) do
    url = "https://#{domain}/.well-known/nodeinfo"

    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           HTTP.get(url, @nodeinfo_headers, receive_timeout: :timer.seconds(5)),
         {:ok, %{} = data} <- decode_json_body(body) do
      nodeinfo_document?(data)
    else
      _ -> false
    end
  end

  defp webfinger_reachable?(domain) do
    with nickname when is_binary(nickname) <- known_actor_nickname(domain),
         encoded_resource <- URI.encode_www_form("acct:#{nickname}"),
         url <- "https://#{domain}/.well-known/webfinger?resource=#{encoded_resource}",
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           HTTP.get(url, @webfinger_headers, receive_timeout: :timer.seconds(5)),
         {:ok, %{} = data} <- decode_json_body(body) do
      webfinger_document?(data)
    else
      _ -> false
    end
  end

  defp decode_json_body(%{} = body), do: {:ok, body}

  defp decode_json_body(body) when is_binary(body) do
    Jason.decode(body)
  end

  defp decode_json_body(_), do: {:error, :invalid_body}

  defp nodeinfo_document?(%{"links" => links}) when is_list(links) do
    Enum.any?(links, fn
      %{"href" => href} when is_binary(href) -> true
      _ -> false
    end)
  end

  defp nodeinfo_document?(_), do: false

  defp webfinger_document?(%{"subject" => "acct:" <> _}), do: true

  defp webfinger_document?(%{"links" => links}) when is_list(links) do
    Enum.any?(links, fn
      %{"rel" => "self", "href" => href} when is_binary(href) -> true
      _ -> false
    end)
  end

  defp webfinger_document?(_), do: false

  defp known_actor_nickname(domain) do
    normalized_domain = String.downcase(domain)

    User
    |> where([u], u.local == false)
    |> where([u], not is_nil(u.nickname))
    |> where([u], fragment("lower(split_part(?, '@', 2))", u.nickname) == ^normalized_domain)
    |> order_by([u], asc: u.id)
    |> limit(1)
    |> select([u], u.nickname)
    |> Repo.one()
  end
end
