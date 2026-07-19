# Pleroma: federation status helpers
# ----------------------------------
#
# File: federation_status.ex
#
# Purpose:
#
#     Turn known local federation policy into a small, stable status object that
#     API clients can show near search and follow controls.
#
# Responsibilities:
#
#     * normalize host, URL, and acct-style identifiers
#     * report local MRF accept/reject/quarantine matches
#     * keep policy reasons close to the host that matched them
#
# This file intentionally does NOT contain:
#
#     * remote HTTP probing
#     * ActivityPub delivery retry bookkeeping
#     * frontend copy or presentation logic

defmodule Pleroma.FederationStatus do
  @moduledoc """
  Read-only federation policy status for a remote host or actor.

  This module answers only what the local server can know without doing a live
  network probe.  In practice that means local MRF policy and quarantine config.
  Remote-side defederation can still become visible through ordinary failed
  fetch/follow responses, but this helper does not guess at that state.
  """

  alias Pleroma.Config
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.MRF

  @none %{
    known: false,
    defederated: false,
    direction: nil,
    severity: "none",
    reason: nil,
    message: nil
  }

  @doc "Return a client-safe status map for a user actor."
  def for_user(%User{} = user) do
    identifier = user.ap_id || user.uri || user.nickname || ""

    for_identifier(identifier)
  end

  def for_user(_), do: Map.put(@none, :host, nil)

  @doc "Return a client-safe status map for a host, URL, or acct-style value."
  def for_identifier(identifier) when is_binary(identifier) do
    case host_from_identifier(identifier) do
      {:ok, host} -> for_host(host)
      _ -> Map.put(@none, :host, nil)
    end
  end

  def for_identifier(_), do: Map.put(@none, :host, nil)

  @doc "Return true if local policy blocks normal federation with this user."
  def defederated?(%User{} = user), do: defederated?(for_user(user))
  def defederated?(%{defederated: value}), do: value == true
  def defederated?(_), do: false

  @doc "Return the UI-facing federation message for a user or status map."
  def message(%User{} = user), do: user |> for_user() |> message()
  def message(%{message: message}) when is_binary(message), do: message
  def message(_), do: "This remote server is blocked by this instance's federation policy."

  def for_host(host) when is_binary(host) do
    host = normalize_host(host)

    cond do
      host == "" ->
        Map.put(@none, :host, nil)

      match = simple_reject_match(host) ->
        status(host, "reject", elem(match, 1))

      not simple_accepts_host?(host) ->
        status(host, "accept_list", "Host is not in the local federation accept list")

      match = quarantined_match(host) ->
        status(host, "quarantine", elem(match, 1), defederated: false)

      true ->
        Map.put(@none, :host, host)
    end
  end

  def for_host(_), do: Map.put(@none, :host, nil)

  defp status(host, severity, reason, opts \\ []) do
    defederated = Keyword.get(opts, :defederated, severity in ["reject", "accept_list"])

    %{
      host: host,
      known: true,
      defederated: defederated,
      direction: "local_policy",
      severity: severity,
      reason: empty_to_nil(reason),
      message: status_message(severity, reason)
    }
  end

  defp status_message("reject", reason) do
    reason_message(reason, "This remote server is blocked by this instance's federation policy.")
  end

  defp status_message("accept_list", reason) do
    reason_message(
      reason,
      "This remote server is not allowed by this instance's federation policy."
    )
  end

  defp status_message("quarantine", reason) do
    reason_message(
      reason,
      "This remote server is quarantined by this instance's federation policy."
    )
  end

  defp status_message(_, reason), do: empty_to_nil(reason)

  defp reason_message(reason, fallback) do
    case empty_to_nil(reason) do
      nil -> fallback
      reason -> reason
    end
  end

  defp simple_reject_match(host), do: simple_config_match(:reject, host)

  defp simple_accepts_host?(host) do
    accepts = simple_config(:accept)

    accepts == [] or match_instance?(accepts, host)
  end

  defp quarantined_match(host) do
    Config.get([:instance, :quarantined_instances], [])
    |> normalize_instance_list()
    |> Enum.find(&instance_matches?(&1, host))
  end

  defp simple_config_match(key, host) do
    key
    |> simple_config()
    |> Enum.find(&instance_matches?(&1, host))
  end

  defp simple_config(key) do
    [:mrf_simple, key]
    |> Config.get([])
    |> normalize_instance_list()
  end

  defp normalize_instance_list(values) when is_list(values) do
    MRF.normalize_instance_list(values)
  rescue
    _ -> []
  end

  defp normalize_instance_list(_), do: []

  defp match_instance?(instances, host), do: Enum.any?(instances, &instance_matches?(&1, host))

  defp instance_matches?({pattern, _reason}, host) do
    pattern
    |> List.wrap()
    |> MRF.subdomains_regex()
    |> MRF.subdomain_match?(host)
  rescue
    _ -> false
  end

  defp host_from_identifier(identifier) do
    identifier = String.trim(identifier)

    cond do
      identifier == "" ->
        :error

      String.starts_with?(identifier, "acct:") ->
        identifier
        |> String.replace_prefix("acct:", "")
        |> host_from_acct()

      String.starts_with?(identifier, "@") or String.contains?(identifier, "@") ->
        host_from_acct(identifier)

      String.match?(identifier, ~r/^https?:\/\//i) ->
        case URI.parse(identifier) do
          %URI{host: host} when is_binary(host) -> {:ok, normalize_host(host)}
          _ -> :error
        end

      true ->
        {:ok, normalize_host(identifier)}
    end
  end

  defp host_from_acct(identifier) do
    case identifier |> String.trim_leading("@") |> String.split("@") do
      [_name, host | _] -> {:ok, normalize_host(host)}
      [host] -> {:ok, normalize_host(host)}
      _ -> :error
    end
  end

  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp empty_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp empty_to_nil(_), do: nil
end

# end of lib/pleroma/federation_status.ex
