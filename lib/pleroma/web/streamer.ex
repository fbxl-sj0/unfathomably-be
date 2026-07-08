# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Streamer do
  require Logger
  require Pleroma.Constants

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Chat.MessageReference
  alias Pleroma.Config
  alias Pleroma.Conversation.Participation
  alias Pleroma.FollowingRelationship
  alias Pleroma.Hashtag
  alias Pleroma.Marker
  alias Pleroma.Notification
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.OAuth.Token
  alias Pleroma.Web.Plugs.OAuthScopesPlug
  alias Pleroma.Web.StreamerView

  @mix_env Mix.env()
  @registry Pleroma.Web.StreamerRegistry

  def registry, do: @registry

  @public_streams Pleroma.Constants.public_streams()
  @local_streams ["public:local", "public:local:media"]
  @aggregate_target_streams ["user:groups", "user:sources"]
  @user_streams ["user", "user:notification", "direct", "user:pleroma_chat"] ++
                  @aggregate_target_streams
  @max_target_stream_identifier_bytes 2048

  @doc "Expands and authorizes a stream, and registers the process for streaming."
  @spec get_topic_and_add_socket(
          stream :: String.t(),
          User.t() | nil,
          Token.t() | nil,
          map() | nil
        ) ::
          {:ok, topic :: String.t()} | {:error, :bad_topic} | {:error, :unauthorized}
  def get_topic_and_add_socket(stream, user, oauth_token, params \\ %{}) do
    with {:ok, topic} <- get_topic(stream, user, oauth_token, params) do
      add_socket(topic, oauth_token)
    end
  end

  defp can_access_stream(user, oauth_token, kind) do
    with {_, true} <- {:restrict?, Config.restrict_unauthenticated_access?(:timelines, kind)},
         {_, %User{id: user_id}, %Token{user_id: user_id}} <- {:user, user, oauth_token},
         {_, true} <-
           {:scopes,
            OAuthScopesPlug.filter_descendants(["read:statuses"], oauth_token.scopes) != []} do
      true
    else
      {:restrict?, _} ->
        true

      _ ->
        false
    end
  end

  @doc "Expand and authorizes a stream"
  @spec get_topic(stream :: String.t() | nil, User.t() | nil, Token.t() | nil, map()) ::
          {:ok, topic :: String.t() | nil} | {:error, :bad_topic}
  def get_topic(stream, user, oauth_token, params \\ %{})

  def get_topic(nil = _stream, _user, _oauth_token, _params) do
    {:ok, nil}
  end

  # Allow all public steams if the instance allows unauthenticated access.
  # Otherwise, only allow users with valid oauth tokens.
  def get_topic(stream, user, oauth_token, _params) when stream in @public_streams do
    kind = if stream in @local_streams, do: :local, else: :federated

    if can_access_stream(user, oauth_token, kind) do
      {:ok, stream}
    else
      {:error, :unauthorized}
    end
  end

  # Allow all hashtags streams.
  def get_topic("hashtag", _user, _oauth_token, %{"tag" => tag} = _params) do
    {:ok, "hashtag:" <> tag}
  end

  # Allow remote instance streams.
  def get_topic("public:remote", user, oauth_token, %{"instance" => instance} = _params) do
    if can_access_stream(user, oauth_token, :federated) do
      {:ok, "public:remote:" <> instance}
    else
      {:error, :unauthorized}
    end
  end

  def get_topic("public:remote:media", user, oauth_token, %{"instance" => instance} = _params) do
    if can_access_stream(user, oauth_token, :federated) do
      {:ok, "public:remote:media:" <> instance}
    else
      {:error, :unauthorized}
    end
  end

  # Expand user streams.
  def get_topic(
        stream,
        %User{id: user_id} = user,
        %Token{user_id: user_id} = oauth_token,
        _params
      )
      when stream in @user_streams do
    # Note: "read" works for all user streams (not mentioning it since it's an ancestor scope)
    required_scopes =
      if stream == "user:notification" do
        ["read:notifications"]
      else
        ["read:statuses"]
      end

    if OAuthScopesPlug.filter_descendants(required_scopes, oauth_token.scopes) == [] do
      {:error, :unauthorized}
    else
      {:ok, stream <> ":" <> to_string(user.id)}
    end
  end

  def get_topic("group:" <> id, user, oauth_token, params) do
    get_topic("group", user, oauth_token, Map.put(params, "group", id))
  end

  def get_topic("group", user, oauth_token, %{"group" => id}) when is_binary(id) do
    with {:ok, id} <- normalize_target_stream_identifier(id),
         true <- can_access_stream(user, oauth_token, :federated),
         {:ok, %User{id: group_id}} <- FederatedTarget.resolve_group(id) do
      {:ok, "group:" <> to_string(group_id)}
    else
      false -> {:error, :unauthorized}
      _ -> {:error, :bad_topic}
    end
  end

  def get_topic("group", _user, _oauth_token, _params), do: {:error, :bad_topic}

  def get_topic("source:" <> id, user, oauth_token, params) do
    get_topic("source", user, oauth_token, Map.put(params, "source", id))
  end

  def get_topic("source", user, oauth_token, %{"source" => id}) when is_binary(id) do
    with {:ok, id} <- normalize_target_stream_identifier(id),
         true <- can_access_stream(user, oauth_token, :federated),
         {:ok, %User{id: source_id}} <- FederatedTarget.resolve_source(id) do
      {:ok, "source:" <> to_string(source_id)}
    else
      false -> {:error, :unauthorized}
      _ -> {:error, :bad_topic}
    end
  end

  def get_topic("source", _user, _oauth_token, _params), do: {:error, :bad_topic}

  def get_topic(stream, _user, _oauth_token, _params) when stream in @user_streams do
    {:error, :unauthorized}
  end

  # List streams.
  def get_topic(
        "list",
        %User{id: user_id} = user,
        %Token{user_id: user_id} = oauth_token,
        %{"list" => id}
      ) do
    cond do
      OAuthScopesPlug.filter_descendants(["read", "read:lists"], oauth_token.scopes) == [] ->
        {:error, :unauthorized}

      Pleroma.List.get(id, user) ->
        {:ok, "list:" <> to_string(id)}

      true ->
        {:error, :bad_topic}
    end
  end

  def get_topic("list", _user, _oauth_token, _params) do
    {:error, :unauthorized}
  end

  def get_topic(_stream, _user, _oauth_token, _params) do
    {:error, :bad_topic}
  end

  defp normalize_target_stream_identifier(id) when is_binary(id) do
    if byte_size(id) <= @max_target_stream_identifier_bytes and String.valid?(id) do
      id = String.trim(id)

      if id == "" or String.contains?(id, <<0>>) do
        {:error, :bad_topic}
      else
        {:ok, id}
      end
    else
      {:error, :bad_topic}
    end
  end

  @doc "Registers the process for streaming. Use `get_topic/3` to get the full authorized topic."
  def add_socket(topic, oauth_token) do
    do_add_socket(topic, oauth_token)
  end

  def remove_socket(topic) do
    do_remove_socket(topic)
  end

  def stream(topics, items) do
    do_stream_topics(topics, items)
  end

  def filtered_by_user?(user, item, streamed_type \\ :activity)

  def filtered_by_user?(%User{} = user, %Activity{} = item, streamed_type) do
    %{block: blocked_ap_ids, mute: muted_ap_ids, reblog_mute: reblog_muted_ap_ids} =
      User.outgoing_relationships_ap_ids(user, [:block, :mute, :reblog_mute])

    recipient_blocks = MapSet.new(blocked_ap_ids ++ muted_ap_ids)
    recipients = MapSet.new(item.recipients)
    domain_blocks = Pleroma.Web.ActivityPub.MRF.subdomains_regex(user.domain_blocks)

    with parent <- Object.normalize(item, fetch: false) || item,
         true <- Enum.all?([blocked_ap_ids, muted_ap_ids], &(item.actor not in &1)),
         true <- item.data["type"] != "Announce" || item.actor not in reblog_muted_ap_ids,
         true <-
           !(streamed_type == :activity && item.data["type"] == "Announce" &&
               parent.data["actor"] == user.ap_id),
         true <- Enum.all?([blocked_ap_ids, muted_ap_ids], &(parent.data["actor"] not in &1)),
         true <- MapSet.disjoint?(recipients, recipient_blocks),
         %{host: item_host} <- URI.parse(item.actor),
         %{host: parent_host} <- URI.parse(parent.data["actor"]),
         false <- Pleroma.Web.ActivityPub.MRF.subdomain_match?(domain_blocks, item_host),
         false <- Pleroma.Web.ActivityPub.MRF.subdomain_match?(domain_blocks, parent_host),
         true <- thread_containment(item, user),
         false <- CommonAPI.thread_muted?(user, parent) do
      false
    else
      _ -> true
    end
  end

  def filtered_by_user?(%User{} = user, %Notification{activity: activity}, _) do
    filtered_by_user?(user, activity, :notification)
  end

  defp do_stream("direct", item) do
    recipient_topics =
      User.get_recipients_from_activity(item)
      |> Enum.map(fn %{id: id} -> "direct:#{id}" end)

    Enum.each(recipient_topics, fn user_topic ->
      Logger.debug("Trying to push direct message to #{user_topic}\n\n")
      push_to_socket(user_topic, item)
    end)
  end

  defp do_stream("follow_relationship", item) do
    user_topic = "user:#{item.follower.id}"
    text = StreamerView.render("follow_relationships_update.json", item, user_topic)

    Logger.debug("Trying to push follow relationship update to #{user_topic}\n\n")

    Registry.dispatch(@registry, user_topic, fn list ->
      Enum.each(list, fn {pid, _auth} ->
        send(pid, {:text, text})
      end)
    end)
  end

  defp do_stream("participation", participation) do
    user_topic = "direct:#{participation.user_id}"
    Logger.debug("Trying to push a conversation participation to #{user_topic}\n\n")

    push_to_socket(user_topic, participation)
  end

  defp do_stream("list", item) do
    # filter the recipient list if the activity is not public, see #270.
    recipient_lists =
      case Visibility.is_public?(item) do
        true ->
          Pleroma.List.get_lists_from_activity(item)

        _ ->
          Pleroma.List.get_lists_from_activity(item)
          |> Enum.filter(fn list ->
            owner = User.get_cached_by_id(list.user_id)

            Visibility.visible_for_user?(item, owner)
          end)
      end

    recipient_topics =
      recipient_lists
      |> Enum.map(fn %{id: id} -> "list:#{id}" end)

    Enum.each(recipient_topics, fn list_topic ->
      Logger.debug("Trying to push message to #{list_topic}\n\n")
      push_to_socket(list_topic, item)
    end)
  end

  defp do_stream(topic, %Notification{} = item)
       when topic in ["user", "user:notification"] do
    user_topic = "#{topic}:#{item.user_id}"

    Registry.dispatch(@registry, user_topic, fn list ->
      Enum.each(list, fn {pid, _auth} ->
        send(pid, {:render_with_user, StreamerView, "notification.json", item, user_topic})
      end)
    end)
  end

  defp do_stream(topic, {user, %MessageReference{} = cm_ref})
       when topic in ["user", "user:pleroma_chat"] do
    topic = "#{topic}:#{user.id}"

    text = StreamerView.render("chat_update.json", %{chat_message_reference: cm_ref}, topic)

    Registry.dispatch(@registry, topic, fn list ->
      Enum.each(list, fn {pid, _auth} ->
        send(pid, {:text, text})
      end)
    end)
  end

  defp do_stream(topic, %Marker{} = marker) do
    Registry.dispatch(@registry, "#{topic}:#{marker.user_id}", fn list ->
      Enum.each(list, fn {pid, _auth} ->
        text = StreamerView.render("marker.json", marker)

        send(pid, {:text, text})
      end)
    end)
  end

  defp do_stream("user", %Activity{} = item) do
    Logger.debug("Trying to push to users")

    recipient_topics =
      User.get_recipients_from_activity(item)
      |> Enum.map(fn %{id: id} -> "user:#{id}" end)

    hashtag_recipients =
      if Pleroma.Constants.as_public() in item.recipients do
        item
        |> Hashtag.get_recipients_for_activity()
        |> Enum.map(fn id -> "user:#{id}" end)
      else
        []
      end

    all_recipients = Enum.uniq(recipient_topics ++ hashtag_recipients)

    Enum.each(all_recipients, fn topic ->
      push_to_socket(topic, item)
    end)
  end

  defp do_stream("group:" <> group_id = topic, %Activity{} = item) do
    stream_followed_target("user:groups", group_id, item)
    stream_target(topic, item)
  end

  defp do_stream("source:" <> source_id = topic, %Activity{} = item) do
    stream_followed_target("user:sources", source_id, item)
    stream_target(topic, item)
  end

  defp do_stream(topic, item) do
    stream_target(topic, item)
  end

  defp stream_target(topic, item) do
    Logger.debug("Trying to push to #{topic}")
    Logger.debug("Pushing item to #{topic}")
    push_to_socket(topic, item)
  end

  defp stream_followed_target(user_stream, target_id, item) when is_binary(target_id) do
    target_id
    |> local_follower_ids()
    |> Enum.each(fn user_id ->
      push_to_socket("#{user_stream}:#{user_id}", item)
    end)
  end

  defp local_follower_ids(target_id) do
    FollowingRelationship
    |> join(:inner, [r], follower in User, on: r.follower_id == follower.id)
    |> where([r, follower], r.following_id == ^target_id and r.state == ^:follow_accept)
    |> where([_r, follower], follower.local == true and follower.is_active == true)
    |> select([_r, follower], follower.id)
    |> Repo.all()
  end

  defp push_to_socket(topic, %Participation{} = participation) do
    rendered = StreamerView.render("conversation.json", participation, topic)

    Registry.dispatch(@registry, topic, fn list ->
      Enum.each(list, fn {pid, _} ->
        send(pid, {:text, rendered})
      end)
    end)
  end

  defp push_to_socket(topic, %Activity{
         data: %{"type" => "Delete", "deleted_activity_id" => deleted_activity_id}
       }) do
    rendered = Jason.encode!(%{event: "delete", payload: to_string(deleted_activity_id)})

    Registry.dispatch(@registry, topic, fn list ->
      Enum.each(list, fn {pid, _} ->
        send(pid, {:text, rendered})
      end)
    end)
  end

  defp push_to_socket(_topic, %Activity{data: %{"type" => "Delete"}}), do: :noop

  defp push_to_socket(topic, %Activity{data: %{"type" => "Update"}} = item) do
    create_activity =
      Pleroma.Activity.get_create_by_object_ap_id(item.object.data["id"])
      |> Map.put(:object, item.object)

    anon_render = StreamerView.render("status_update.json", create_activity, topic)

    Registry.dispatch(@registry, topic, fn list ->
      Enum.each(list, fn {pid, auth?} ->
        if auth? do
          send(
            pid,
            {:render_with_user, StreamerView, "status_update.json", create_activity, topic}
          )
        else
          send(pid, {:text, anon_render})
        end
      end)
    end)
  end

  defp push_to_socket(topic, item) do
    Registry.dispatch(@registry, topic, fn list ->
      anon_render =
        if Enum.any?(list, fn {_pid, auth?} -> !auth? end) do
          StreamerView.render("update.json", item, topic)
        end

      Enum.each(list, fn {pid, auth?} ->
        if auth? do
          send(pid, {:render_with_user, StreamerView, "update.json", item, topic})
        else
          send(pid, {:text, anon_render})
        end
      end)
    end)
  end

  defp thread_containment(_activity, %User{skip_thread_containment: true}), do: true

  defp thread_containment(activity, user) do
    if Config.get([:instance, :skip_thread_containment]) do
      true
    else
      ActivityPub.contain_activity(activity, user)
    end
  end

  def close_streams_by_oauth_token(oauth_token) do
    do_close_streams_by_oauth_token(oauth_token)
  end

  defp register_socket(topic, oauth_token) do
    oauth_token_id = if oauth_token, do: oauth_token.id, else: false
    Registry.register(@registry, topic, oauth_token_id)
  end

  defp stream_topics(topics, items) do
    for topic <- List.wrap(topics), item <- List.wrap(items) do
      spawn_streamer(topic, item)
    end
  end

  if @mix_env == :test do
    @test_streamer_table :pleroma_streamer_test_workers

    def wait_for_test_streams(_owner, timeout \\ 5000) do
      ensure_test_streamer_table()

      deadline = System.monotonic_time(:millisecond) + timeout

      @test_streamer_table
      |> :ets.tab2list()
      |> Enum.map(fn {_owner, pid} -> pid end)
      |> Enum.uniq()
      |> Enum.each(fn pid ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          remaining ->
            Process.demonitor(ref, [:flush])
        end
      end)

      :ets.delete_all_objects(@test_streamer_table)

      :ok
    end

    defp spawn_streamer(topic, item) do
      owner = self()

      pid =
        spawn(fn ->
          try do
            do_stream(topic, item)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end)

      track_test_streamer(owner, pid)

      pid
    end

    defp track_test_streamer(owner, pid) do
      ensure_test_streamer_table()
      :ets.insert(@test_streamer_table, {owner, pid})
    end

    defp ensure_test_streamer_table do
      case :ets.whereis(@test_streamer_table) do
        :undefined ->
          try do
            :ets.new(@test_streamer_table, [:named_table, :public, :bag])
          rescue
            ArgumentError -> :ok
          end

        _ ->
          :ok
      end
    end
  else
    defp spawn_streamer(topic, item) do
      spawn(fn -> do_stream(topic, item) end)
    end
  end

  defp close_streams(oauth_token) do
    Registry.select(
      @registry,
      [
        {
          {:"$1", :"$2", :"$3"},
          [{:==, :"$3", oauth_token.id}],
          [:"$2"]
        }
      ]
    )
    |> Enum.each(fn pid -> send(pid, :close) end)
  end

  defp streamer_registry_started? do
    case Process.whereis(@registry) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  cond do
    @mix_env == :test ->
      defp do_add_socket(topic, oauth_token) do
        if streamer_registry_started?() do
          register_socket(topic, oauth_token)
        end

        {:ok, topic}
      end

      defp do_remove_socket(topic) do
        if streamer_registry_started?(), do: Registry.unregister(@registry, topic)
      end

      defp do_stream_topics(topics, items) do
        if streamer_registry_started?(), do: stream_topics(topics, items)
      end

      defp do_close_streams_by_oauth_token(oauth_token) do
        if streamer_registry_started?(), do: close_streams(oauth_token)
      end

    @mix_env == :benchmark ->
      defp do_add_socket(topic, _oauth_token), do: {:ok, topic}
      defp do_remove_socket(_topic), do: :ok
      defp do_stream_topics(_topics, _items), do: :ok
      defp do_close_streams_by_oauth_token(_oauth_token), do: :ok

    true ->
      defp do_add_socket(topic, oauth_token) do
        if streamer_registry_started?(), do: register_socket(topic, oauth_token)
        {:ok, topic}
      end

      defp do_remove_socket(topic) do
        if streamer_registry_started?(), do: Registry.unregister(@registry, topic)
      end

      defp do_stream_topics(topics, items) do
        if streamer_registry_started?(), do: stream_topics(topics, items)
      end

      defp do_close_streams_by_oauth_token(oauth_token) do
        if streamer_registry_started?(), do: close_streams(oauth_token)
      end
  end

  # Streaming depends on whether the registry has been started.
  #
  # In dev and production, the streamer registry is part of the normal
  # supervision tree, so the runtime application config allows streaming
  # without a compile-time Mix environment branch. Tests and smoke stacks can
  # disable the registry in Pleroma.Application config while still allowing
  # individual tests to start the registry and exercise streaming behavior.
  def should_env_send? do
    if Application.get_env(:pleroma, Pleroma.Application, [])
       |> Keyword.get(:streamer_registry, false) do
      true
    else
      streamer_registry_started?()
    end
  end
end
