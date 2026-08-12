# Unfathomably instance metadata maintenance
# -------------------------------------------
#
# File: instance_favicon_worker.ex
#
# Purpose:
#
#     Refresh a remote instance favicon outside user-facing request paths.
#
# Responsibilities:
#
#     * validate the queued remote instance URL and host
#     * invoke the existing bounded favicon fetch and persistence path
#     * invalidate the host cache after a refresh completes
#
# This file intentionally does NOT contain:
#
#     * account rendering
#     * favicon HTML parsing
#     * arbitrary URL fetching outside the instance favicon helper

defmodule Pleroma.Workers.InstanceFaviconWorker do
  use Oban.Worker,
    queue: :background,
    max_attempts: 1,
    unique: [period: 86_400, states: :incomplete, keys: [:host]]

  alias Pleroma.Instances.Instance

  def enqueue(%URI{scheme: scheme, host: host} = uri)
      when scheme in ["http", "https"] and is_binary(host) do
    %{"url" => URI.to_string(uri), "host" => String.downcase(host)}
    |> new()
    |> Oban.insert()
  end

  def enqueue(_uri), do: {:error, :invalid_uri}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url, "host" => expected_host}})
      when is_binary(url) and is_binary(expected_host) do
    with %URI{scheme: scheme, host: host} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host),
         true <- String.downcase(host) == expected_host do
      _favicon = Instance.get_or_update_favicon(uri)
      Cachex.del(:host_meta_cache, Instance.favicon_cache_key(host))
      :ok
    else
      _ -> :discard
    end
  end

  def perform(%Oban.Job{}), do: :discard
end

# end of instance_favicon_worker.ex
