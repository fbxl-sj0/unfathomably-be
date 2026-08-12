# Unfathomably: ActivityPub discovery connectors
#
# File: fedi_buzz_connector.ex

# Purpose:
#   Consume the optional FediBuzz public firehose for locally solicited posts.

# Responsibilities:
#   - maintain one bounded server-side event-stream connection
#   - match updates against locally followed actors and hashtags
#   - enqueue canonical ActivityPub fetches with courtesy rate limits
#   - reconnect with bounded exponential backoff

# This file intentionally does NOT trust Mastodon status JSON as authoritative
# ActivityPub data or insert remote activities directly.

defmodule Pleroma.Web.ActivityPub.FediBuzzConnector do
  @moduledoc """
  Optional, solicited discovery through the FediBuzz public SSE firehose.

  Firehose records are only hints. Matching records enter the ordinary remote
  object fetch pipeline, where signatures, MRF, visibility, blocking, and
  object validation continue to apply.
  """

  use GenServer

  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.FollowingRelationship
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.User.HashtagFollow
  alias Pleroma.Workers.RemoteFetcherWorker

  require Logger

  @default_url "https://fedi.buzz/api/v1/streaming/public"
  @finch_name Pleroma.FediBuzzFinch
  @minute_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl GenServer
  def init(_state) do
    state = %{
      enabled: enabled?(),
      finch: nil,
      task: nil,
      retry_ms: config_integer(:reconnect_min_ms, 1_000),
      actors: MapSet.new(),
      tags: MapSet.new(),
      window_started_at: System.monotonic_time(:millisecond),
      window_count: 0
    }

    if state.enabled do
      Process.flag(:trap_exit, true)

      case Finch.start_link(name: @finch_name, pools: %{default: [size: 1]}) do
        {:ok, finch} ->
          send(self(), :refresh_subscriptions)
          send(self(), :connect)
          {:ok, %{state | finch: finch}}

        {:error, {:already_started, finch}} ->
          Process.link(finch)
          send(self(), :refresh_subscriptions)
          send(self(), :connect)
          {:ok, %{state | finch: finch}}

        {:error, reason} ->
          Logger.warning("FediBuzz connector could not start its HTTP pool: #{inspect(reason)}")
          {:ok, %{state | enabled: false}}
      end
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_info(:refresh_subscriptions, %{enabled: true} = state) do
    state = refresh_subscriptions(state)

    Process.send_after(
      self(),
      :refresh_subscriptions,
      config_integer(:subscription_refresh_ms, 300_000)
    )

    {:noreply, state}
  end

  def handle_info(:connect, %{enabled: true, task: nil} = state) do
    parent = self()
    task = Task.async(fn -> stream(parent) end)
    {:noreply, %{state | task: task}}
  end

  def handle_info({:fedibuzz_connected, task_pid}, %{task: %Task{pid: task_pid}} = state) do
    {:noreply, %{state | retry_ms: config_integer(:reconnect_min_ms, 1_000)}}
  end

  def handle_info({:fedibuzz_event, "update", status}, state) when is_map(status) do
    {:noreply, maybe_enqueue_status(status, state)}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, schedule_reconnect(result, %{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, schedule_reconnect(reason, %{state | task: nil})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{task: %Task{pid: pid}}) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp stream(parent) do
    request =
      Finch.build(:get, connector_url(), [
        {"accept", "text/event-stream"},
        {"user-agent", Pleroma.Application.user_agent()}
      ])

    initial = %{
      parent: parent,
      status: nil,
      connected: false,
      buffer: "",
      event: nil,
      data: [],
      data_bytes: 0,
      dropping: false
    }

    options = [receive_timeout: config_integer(:receive_timeout_ms, 90_000)]

    case Finch.stream(request, @finch_name, initial, &stream_message/2, options) do
      {:ok, %{status: 200}} -> {:error, :stream_closed}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_message({:status, 200}, state) do
    if not state.connected, do: send(state.parent, {:fedibuzz_connected, self()})
    %{state | status: 200, connected: true}
  end

  defp stream_message({:status, status}, state), do: %{state | status: status}
  defp stream_message({:headers, _headers}, state), do: state

  defp stream_message({:data, chunk}, %{status: 200} = state) when is_binary(chunk) do
    parse_chunk(chunk, state)
  end

  defp stream_message({:data, _chunk}, state), do: state

  defp parse_chunk(chunk, state) do
    buffered = state.buffer <> chunk

    if byte_size(buffered) > config_integer(:max_buffer_bytes, 524_288) do
      reset_event(%{state | buffer: ""})
    else
      {tail, lines} = buffered |> String.split("\n", trim: false) |> List.pop_at(-1)
      Enum.reduce(lines, %{state | buffer: tail || ""}, &parse_line/2)
    end
  end

  defp parse_line(line, state) do
    line = String.trim_trailing(line, "\r")

    cond do
      line == "" ->
        state |> dispatch_event() |> reset_event()

      String.starts_with?(line, "event:") ->
        %{state | event: field_value(line, "event:"), data: [], data_bytes: 0, dropping: false}

      String.starts_with?(line, "data:") ->
        append_data(field_value(line, "data:"), state)

      true ->
        state
    end
  end

  defp append_data(_value, %{dropping: true} = state), do: state

  defp append_data(value, state) do
    data_bytes = state.data_bytes + byte_size(value)

    if data_bytes > config_integer(:max_event_bytes, 262_144) do
      %{state | data: [], data_bytes: 0, dropping: true}
    else
      %{state | data: [value | state.data], data_bytes: data_bytes}
    end
  end

  defp dispatch_event(%{dropping: false, event: event, data: data, parent: parent} = state)
       when is_binary(event) and data != [] do
    case data |> Enum.reverse() |> Enum.join("\n") |> Jason.decode() do
      {:ok, decoded} when is_map(decoded) -> send(parent, {:fedibuzz_event, event, decoded})
      _invalid -> :ok
    end

    state
  end

  defp dispatch_event(state), do: state

  defp reset_event(state) do
    %{state | event: nil, data: [], data_bytes: 0, dropping: false}
  end

  defp field_value(line, prefix) do
    line
    |> binary_part(byte_size(prefix), byte_size(line) - byte_size(prefix))
    |> String.trim_leading()
  end

  defp maybe_enqueue_status(%{"reblog" => reblog}, state) when is_map(reblog) do
    maybe_enqueue_status(reblog, state)
  end

  defp maybe_enqueue_status(status, state) do
    with true <- solicited?(status, state),
         {:ok, url} <- status_url(status),
         {:ok, state} <- reserve_window_slot(state) do
      %{
        "op" => "fetch_remote",
        "id" => url,
        "depth" => 0,
        "force" => true,
        "source" => "fedibuzz"
      }
      |> RemoteFetcherWorker.new()
      |> Oban.insert()

      state
    else
      {:limit, state} -> state
      _not_solicited_or_invalid -> state
    end
  end

  defp solicited?(status, state) do
    actor = get_in(status, ["account", "uri"]) || get_in(status, ["account", "url"])
    followed_actor? = is_binary(actor) and MapSet.member?(state.actors, normalize_actor(actor))

    followed_tag? =
      status
      |> Map.get("tags", [])
      |> List.wrap()
      |> Enum.any?(fn
        %{"name" => name} when is_binary(name) -> MapSet.member?(state.tags, normalize_tag(name))
        _other -> false
      end)

    followed_actor? or followed_tag?
  end

  defp status_url(status) do
    url = status["uri"] || status["url"]

    case URI.parse(url || "") do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, url}

      _invalid ->
        :error
    end
  end

  defp reserve_window_slot(state) do
    now = System.monotonic_time(:millisecond)

    state =
      if now - state.window_started_at >= @minute_ms do
        %{state | window_started_at: now, window_count: 0}
      else
        state
      end

    if state.window_count < config_integer(:max_events_per_minute, 120) do
      {:ok, %{state | window_count: state.window_count + 1}}
    else
      {:limit, state}
    end
  end

  defp refresh_subscriptions(state) do
    actors =
      FollowingRelationship
      |> join(:inner, [relationship], follower in User,
        on: follower.id == relationship.follower_id
      )
      |> join(:inner, [relationship, _follower], following in User,
        on: following.id == relationship.following_id
      )
      |> where(
        [relationship, follower, following],
        relationship.state == :follow_accept and follower.local == true and
          follower.is_active == true and following.local == false
      )
      |> select([_relationship, _follower, following], following.ap_id)
      |> Repo.all()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize_actor/1)
      |> MapSet.new()

    tags =
      HashtagFollow
      |> join(:inner, [follow], user in assoc(follow, :user))
      |> join(:inner, [follow, _user], hashtag in assoc(follow, :hashtag))
      |> where([_follow, user], user.local == true and user.is_active == true)
      |> select([_follow, _user, hashtag], hashtag.name)
      |> Repo.all()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize_tag/1)
      |> MapSet.new()

    %{state | actors: actors, tags: tags}
  rescue
    error ->
      Logger.warning("FediBuzz subscription refresh failed: #{inspect(error)}")
      state
  end

  defp schedule_reconnect(reason, state) do
    delay = state.retry_ms
    jitter = :rand.uniform(max(div(delay, 4), 1)) - 1
    Process.send_after(self(), :connect, delay + jitter)

    Logger.info("FediBuzz stream disconnected; reconnecting",
      reason: inspect(reason),
      delay_ms: delay
    )

    max_delay = config_integer(:reconnect_max_ms, 60_000)
    %{state | retry_ms: min(delay * 2, max_delay)}
  end

  defp normalize_actor(actor), do: String.trim_trailing(String.trim(actor), "/")

  defp normalize_tag(tag),
    do: tag |> String.trim() |> String.trim_leading("#") |> String.downcase()

  defp connector_url do
    case Config.get([__MODULE__, :url], @default_url) do
      url when is_binary(url) and url != "" -> url
      _invalid -> @default_url
    end
  end

  defp enabled? do
    case Config.get([__MODULE__, :enabled], false) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(value) in ~w(true 1 yes on)
      _invalid -> false
    end
  end

  defp config_integer(key, default) do
    case Config.get([__MODULE__, key], default) do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_integer(value, default)
      _invalid -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _invalid -> default
    end
  end
end

# end of fedi_buzz_connector.ex
