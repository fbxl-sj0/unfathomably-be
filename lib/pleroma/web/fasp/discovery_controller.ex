# Unfathomably FASP discovery disclosure
# ---------------------------------------
#
# File: discovery_controller.ex
#
# Purpose:
#   Disclose active third-party account discovery providers to clients.
#
# Responsibilities:
#   - expose only accepted providers with an active account-search capability
#   - return provider names, base URLs, and signed privacy-policy links
#   - omit relationship keys, fingerprints, and inactive registrations
#
# This file intentionally does not register providers, activate capabilities,
# execute searches, or expose cryptographic relationship material.

defmodule Pleroma.Web.FASP.DiscoveryController do
  use Pleroma.Web, :controller

  import Ecto.Query

  alias Pleroma.FASP.Registration
  alias Pleroma.Repo

  def index(conn, _params) do
    providers =
      Registration
      |> where([registration], registration.state == "accepted")
      |> order_by([registration], asc: registration.name, asc: registration.id)
      |> Repo.all()
      |> Enum.filter(&active_account_search?/1)
      |> Enum.map(&public_provider/1)

    json(conn, %{providers: providers})
  end

  defp active_account_search?(registration) do
    registration.active_capabilities
    |> List.wrap()
    |> Enum.any?(fn capability ->
      field(capability, "id") == "account_search" and field(capability, "version") == "0.1"
    end)
  end

  defp public_provider(registration) do
    provider_info = registration.provider_info || %{}

    %{
      name: bounded_text(field(provider_info, "name"), 200) || registration.name,
      base_url: registration.base_url,
      privacy_policy:
        provider_info
        |> field("privacy_policy")
        |> List.wrap()
        |> Enum.map(&privacy_policy/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(10)
    }
  end

  defp privacy_policy(policy) when is_map(policy) do
    url = field(policy, "url")
    language = bounded_text(field(policy, "language"), 35)

    if secure_url?(url) and is_binary(language) do
      %{url: url, language: language}
    end
  end

  defp privacy_policy(_policy), do: nil

  defp field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp field(_map, _key), do: nil

  defp bounded_text(value, limit) when is_binary(value) do
    value =
      value
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, limit)

    if value == "", do: nil, else: value
  end

  defp bounded_text(_value, _limit), do: nil

  defp secure_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) -> true
      _ -> false
    end
  end

  defp secure_url?(_url), do: false
end

# end of discovery_controller.ex
