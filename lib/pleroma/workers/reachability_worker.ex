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
    queue: "background",
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  @nodeinfo_headers [{"accept", "application/json"}]
  @webfinger_headers [{"accept", "application/jrd+json,application/json"}]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain" => domain}}) when is_binary(domain) do
    domain = Instances.host(domain)

    if nodeinfo_reachable?(domain) or webfinger_reachable?(domain) do
      Instances.set_reachable(domain)
    else
      {:error, :unreachable}
    end
  end

  def perform(%Oban.Job{}), do: :discard

  defp nodeinfo_reachable?(domain) do
    url = "https://#{domain}/.well-known/nodeinfo"

    case HTTP.get(url, @nodeinfo_headers, receive_timeout: :timer.seconds(5)) do
      {:ok, %{status: status}} when status in 200..299 -> true
      _ -> false
    end
  end

  defp webfinger_reachable?(domain) do
    with nickname when is_binary(nickname) <- known_actor_nickname(domain),
         encoded_resource <- URI.encode_www_form("acct:#{nickname}"),
         url <- "https://#{domain}/.well-known/webfinger?resource=#{encoded_resource}",
         {:ok, %{status: status}} when status in 200..299 <-
           HTTP.get(url, @webfinger_headers, receive_timeout: :timer.seconds(5)) do
      true
    else
      _ -> false
    end
  end

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
