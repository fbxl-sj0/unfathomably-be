# Pleroma: A lightweight social networking server
# Copyright © 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.DNSRBLPolicy do
  @moduledoc """
  Dynamic activity filtering based on a DNS realtime blocklist.

  DNSRBL checks are borrowed from the email anti-spam world: the actor host is
  looked up under a configured zone and a non-empty answer means the host is
  listed. The policy is fail-open so resolver errors do not interrupt
  federation.
  """

  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  alias Pleroma.Config

  require Logger

  @query_retries 1
  @query_timeout 500

  @impl true
  def filter(%{"actor" => actor} = object) when is_binary(actor) do
    actor
    |> URI.parse()
    |> check_rbl(object)
  end

  @impl true
  def filter(object), do: {:ok, object}

  @impl true
  def describe do
    mrf_dnsrbl =
      Config.get(:mrf_dnsrbl)
      |> Enum.into(%{})

    {:ok, %{mrf_dnsrbl: mrf_dnsrbl}}
  end

  @impl true
  def config_description do
    %{
      key: :mrf_dnsrbl,
      related_policy: "Pleroma.Web.ActivityPub.MRF.DNSRBLPolicy",
      label: "MRF DNSRBL",
      description: "DNS realtime blocklist policy",
      children: [
        %{
          key: :nameserver,
          type: :string,
          description: "DNSRBL nameserver to query",
          suggestions: ["127.0.0.1"]
        },
        %{
          key: :port,
          type: :integer,
          description: "Nameserver port",
          suggestions: [53]
        },
        %{
          key: :zone,
          type: :string,
          description: "Root DNSRBL zone",
          suggestions: ["bl.pleroma.com"]
        }
      ]
    }
  end

  defp check_rbl(%{host: actor_host}, object) when is_binary(actor_host) do
    with false <- actor_host == Pleroma.Web.Endpoint.host(),
         zone when is_binary(zone) <- Keyword.get(Config.get([:mrf_dnsrbl]), :zone),
         [] <- rblquery(Enum.join([actor_host, zone], ".") |> String.to_charlist()) do
      {:ok, object}
    else
      true ->
        {:ok, object}

      nil ->
        {:ok, object}

      [_ | _] ->
        log_rejection(actor_host)
        {:reject, "[DNSRBLPolicy]"}

      _ ->
        {:ok, object}
    end
  end

  defp check_rbl(_, object), do: {:ok, object}

  defp log_rejection(actor_host) do
    Task.start(fn ->
      zone = Keyword.get(Config.get([:mrf_dnsrbl]), :zone)
      query = Enum.join([actor_host, zone], ".") |> String.to_charlist()

      reason =
        case rblquery(query, :txt) do
          [[result]] -> result
          _ -> "undefined"
        end

      Logger.warning("DNSRBL rejected activity from #{actor_host} for reason: #{inspect(reason)}")
    end)
  end

  defp get_rblhost_ip(rblhost) when is_binary(rblhost) do
    case rblhost |> String.to_charlist() |> :inet_parse.address() do
      {:ok, _} = result ->
        result

      _ ->
        case rblhost |> String.to_charlist() |> :inet_res.lookup(:in, :a) do
          [ip | _] -> {:ok, ip}
          _ -> :error
        end
    end
  end

  defp get_rblhost_ip(_), do: :error

  defp rblquery(query, type \\ :a) do
    config = Config.get([:mrf_dnsrbl])

    with {:ok, rblnsip} <- get_rblhost_ip(config[:nameserver]) do
      :inet_res.lookup(query, :in, type,
        nameservers: [{rblnsip, config[:port]}],
        timeout: @query_timeout,
        retry: @query_retries
      )
    else
      _ -> []
    end
  end
end
