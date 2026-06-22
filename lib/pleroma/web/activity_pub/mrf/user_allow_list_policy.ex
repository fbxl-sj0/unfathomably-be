# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.UserAllowListPolicy do
  alias Pleroma.Config

  @moduledoc "Accept-list of users from specified instances"
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  defp filter_by_list(activity, []), do: {:ok, activity}

  defp filter_by_list(%{"actor" => actor} = activity, allow_list) do
    if actor in allow_list do
      {:ok, activity}
    else
      {:reject, "[UserAllowListPolicy] #{actor} not in the list"}
    end
  end

  @impl true
  def filter(%{"actor" => actor} = activity) do
    actor_info = URI.parse(actor)

    allow_list = allow_list_for_host(actor_info.host)

    filter_by_list(activity, allow_list)
  end

  def filter(activity), do: {:ok, activity}

  defp allow_list_for_host(host) do
    configured_hosts()
    |> host_config(host)
  end

  defp configured_hosts do
    config = Config.get([:mrf_user_allowlist], %{})

    cond do
      is_map(config) and Map.has_key?(config, :hosts) -> Map.get(config, :hosts)
      is_map(config) and Map.has_key?(config, "hosts") -> Map.get(config, "hosts")
      Keyword.keyword?(config) and Keyword.has_key?(config, :hosts) -> Keyword.get(config, :hosts)
      true -> config
    end
  end

  defp host_config(hosts, host) when is_map(hosts), do: Map.get(hosts, host, [])

  defp host_config(hosts, host) when is_list(hosts) do
    Enum.find_value(hosts, [], fn {key, value} ->
      if to_string(key) == host, do: value
    end)
  end

  defp host_config(_, _), do: []

  @impl true
  def describe do
    mrf_user_allowlist =
      configured_hosts()
      |> Map.new(fn {k, v} -> {k, length(v)} end)

    {:ok, %{mrf_user_allowlist: mrf_user_allowlist}}
  end

  @impl true
  def config_description do
    %{
      key: :mrf_user_allowlist,
      related_policy: "Pleroma.Web.ActivityPub.MRF.UserAllowListPolicy",
      description: "Accept-list of users from specified instances",
      children: [
        %{
          key: :hosts,
          type: :map,
          description:
            "The keys in this section are the domain names that the policy should apply to." <>
              " Each key should be assigned a list of users that should be allowed " <>
              "through by their ActivityPub ID",
          suggestions: [%{"example.org" => ["https://example.org/users/admin"]}]
        }
      ]
    }
  end
end
