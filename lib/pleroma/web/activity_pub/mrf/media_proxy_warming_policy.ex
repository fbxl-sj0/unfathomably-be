# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.MediaProxyWarmingPolicy do
  @moduledoc "Preloads any attachments in the MediaProxy cache by prefetching them"
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  alias Pleroma.HTTP
  alias Pleroma.Web.MediaProxy

  require Logger

  @adapter_options [
    pool: :media,
    recv_timeout: 10_000
  ]

  @impl true
  def history_awareness, do: :auto

  defp prefetch(url) do
    # Fetching only proxiable resources
    if MediaProxy.enabled?() and MediaProxy.url_proxiable?(url) do
      # If preview proxy is enabled, it'll also hit media proxy (so we're caching both requests)
      prefetch_url = MediaProxy.preview_url(url)

      Logger.debug("Prefetching #{inspect(url)} as #{inspect(prefetch_url)}")

      fetch(prefetch_url)
    end
  end

  defp fetch(url) do
    # Redirect following is handled by the HTTP middleware layer.
    # Do not enable adapter-level redirects here: Hackney has known edge
    # cases around relative redirects and CONNECT proxies.
    http_client_opts =
      Pleroma.Config.get([:media_proxy, :proxy_opts, :http], @adapter_options)
      |> Keyword.drop([:follow_redirect, :force_redirect])

    HTTP.get(url, [], http_client_opts)
  end

  defp preload_object(%{"attachment" => attachments}) when is_list(attachments) do
    Enum.each(attachments, fn
      %{"url" => url} when is_list(url) ->
        url
        |> Enum.each(fn
          %{"href" => href} ->
            prefetch(href)

          x ->
            Logger.debug("Unhandled attachment URL object #{inspect(x)}")
        end)

      x ->
        Logger.debug("Unhandled attachment #{inspect(x)}")
    end)
  end

  defp preload_object(_object), do: :ok

  defp preload_history(%{"formerRepresentations" => %{"orderedItems" => items}})
       when is_list(items) do
    Enum.each(items, &preload_object/1)
  end

  defp preload_history(_object), do: :ok

  defp preload(%{"object" => object}) when is_map(object) do
    preload_object(object)
    preload_history(object)
  end

  @impl true
  def filter(%{"type" => type, "object" => object} = activity)
      when type in ["Create", "Update"] and is_map(object) do
    preload(activity)

    {:ok, activity}
  end

  @impl true
  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{}}
end
