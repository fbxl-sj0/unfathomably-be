# Unfathomably instance metadata maintenance
# -------------------------------------------
#
# File: instance_metadata_worker.ex
#
# Purpose:
#
#     Discover or refresh metadata for a remote host outside request and
#     federation transaction paths.
#
# Responsibilities:
#
#     * validate the queued ActivityPub actor URL and expected host
#     * coalesce metadata probes for the same host
#     * invoke the existing freshness-aware NodeInfo persistence path
#
# This file intentionally does NOT contain:
#
#     * follow relationship changes
#     * NodeInfo parsing
#     * arbitrary URL fetching outside the instance metadata helper

defmodule Pleroma.Workers.InstanceMetadataWorker do
  use Oban.Worker,
    queue: :background,
    max_attempts: 1,
    unique: [period: 21_600, states: :incomplete, keys: [:host]]

  alias Pleroma.Instances.Instance

  def enqueue(actor_url) when is_binary(actor_url) do
    with %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri <-
           URI.parse(actor_url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "" do
      %{"url" => URI.to_string(uri), "host" => String.downcase(host)}
      |> new()
      |> Oban.insert()
    else
      _ -> {:error, :invalid_uri}
    end
  end

  def enqueue(_actor_url), do: {:error, :invalid_uri}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url, "host" => expected_host}})
      when is_binary(url) and is_binary(expected_host) do
    with %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host),
         true <- String.downcase(host) == expected_host do
      _metadata = Instance.get_or_update_metadata(uri)
      :ok
    else
      _ -> :discard
    end
  end

  def perform(%Oban.Job{}), do: :discard
end

# end of instance_metadata_worker.ex
