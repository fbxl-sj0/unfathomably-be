# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.GroupActivityVerifier do
  @moduledoc """
  Selects the authoritative activity from a FEP-1b12 group wrapper.

  A group server may safely inline an activity whose identifier shares the
  enclosing Announce identifier's origin. Cross-origin activities are only
  forwarding hints: the canonical activity is fetched from its own identifier
  before the normal incoming validators apply it. This prevents a group server
  from changing an activity that belongs to another origin.

  Some older group implementations omit the embedded activity identifier. Such
  an activity is accepted only when its actor shares the wrapper's origin, so
  the authenticated group server is not allowed to impersonate a remote actor.
  """

  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.Utils

  @type verification_error ::
          {:reject, :invalid_group_activity}
          | {:reject, :group_activity_origin_mismatch}
          | term()

  @spec canonicalize(map(), map(), (String.t() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, verification_error()}
  def canonicalize(
        announce,
        activity,
        fetcher \\ &Fetcher.fetch_and_contain_remote_object_from_id/1
      )

  def canonicalize(%{} = announce, %{} = activity, fetcher) when is_function(fetcher, 1) do
    announce_id = Utils.get_ap_id(announce)
    announce_actor = Utils.get_ap_id(announce["actor"])
    activity_id = Utils.get_ap_id(activity)
    activity_actor = Utils.get_ap_id(activity["actor"])

    cond do
      same_origin?(announce_id, activity_id) ->
        {:ok, activity}

      valid_uri?(activity_id) ->
        fetch_canonical(activity, activity_id, fetcher)

      same_origin?(announce_id || announce_actor, activity_actor) ->
        {:ok, activity}

      true ->
        {:error, {:reject, :invalid_group_activity}}
    end
  end

  def canonicalize(_, _, _), do: {:error, {:reject, :invalid_group_activity}}

  defp fetch_canonical(activity, activity_id, fetcher) do
    case fetcher.(activity_id) do
      {:ok, %{"id" => ^activity_id, "type" => type} = canonical} ->
        if type == activity["type"] do
          {:ok, canonical}
        else
          {:error, {:reject, :group_activity_origin_mismatch}}
        end

      {:ok, _canonical} ->
        {:error, {:reject, :group_activity_origin_mismatch}}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, {:reject, :invalid_group_activity}}
    end
  end

  defp same_origin?(left, right) when is_binary(left) and is_binary(right) do
    with %URI{scheme: left_scheme, host: left_host, userinfo: nil} = left_uri <- URI.parse(left),
         %URI{scheme: right_scheme, host: right_host, userinfo: nil} = right_uri <-
           URI.parse(right),
         true <- left_scheme in ["http", "https"],
         true <- right_scheme == left_scheme,
         true <- is_binary(left_host) and is_binary(right_host) do
      String.downcase(left_host) == String.downcase(right_host) and
        effective_port(left_uri) == effective_port(right_uri)
    else
      _ -> false
    end
  rescue
    URI.Error -> false
  end

  defp same_origin?(_left, _right), do: false

  defp valid_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  rescue
    URI.Error -> false
  end

  defp valid_uri?(_uri), do: false

  defp effective_port(%URI{port: nil, scheme: scheme}), do: URI.default_port(scheme)
  defp effective_port(%URI{port: port}), do: port
end

# end of group_activity_verifier.ex
