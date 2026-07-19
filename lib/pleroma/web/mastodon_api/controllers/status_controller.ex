# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.StatusController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.ControllerHelper
  require Ecto.Query
  require Pleroma.Constants

  alias Pleroma.Activity
  alias Pleroma.Bookmark
  alias Pleroma.BookmarkFolder
  alias Pleroma.Language.Translation
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.ScheduledActivity
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.RemoteReplies
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.Web.MastodonAPI.ScheduledActivityView
  alias Pleroma.Web.Plugs.OAuthScopesPlug
  alias Pleroma.Web.Plugs.RateLimiter
  alias Pleroma.Web.RichMedia.Card

  plug(Pleroma.Web.ApiSpec.CastAndValidate)

  plug(:skip_public_check when action in [:index, :show])

  @unauthenticated_access %{fallback: :proceed_unauthenticated, scopes: []}

  plug(
    OAuthScopesPlug,
    %{@unauthenticated_access | scopes: ["read:statuses"]}
    when action in [
           :index,
           :show,
           :card,
           :context,
           :show_history,
           :show_source,
           :translate,
           :quotes
         ]
  )

  plug(
    OAuthScopesPlug,
    %{scopes: ["write:statuses"]}
    when action in [
           :create,
           :delete,
           :reblog,
           :unreblog,
           :update
         ]
  )

  plug(OAuthScopesPlug, %{scopes: ["read:favourites"]} when action == :favourites)

  plug(
    OAuthScopesPlug,
    %{scopes: ["write:favourites"]} when action in [:favourite, :unfavourite]
  )

  plug(
    OAuthScopesPlug,
    %{scopes: ["write:mutes"]} when action in [:mute_conversation, :unmute_conversation]
  )

  plug(
    OAuthScopesPlug,
    %{@unauthenticated_access | scopes: ["read:accounts"]}
    when action in [:favourited_by, :reblogged_by]
  )

  plug(OAuthScopesPlug, %{scopes: ["write:accounts"]} when action in [:pin, :unpin])

  # Note: scope not present in Mastodon: read:bookmarks
  plug(OAuthScopesPlug, %{scopes: ["read:bookmarks"]} when action == :bookmarks)

  # Note: scope not present in Mastodon: write:bookmarks
  plug(
    OAuthScopesPlug,
    %{scopes: ["write:bookmarks"]} when action in [:bookmark, :unbookmark]
  )

  @rate_limited_status_actions ~w(reblog unreblog favourite unfavourite create delete translate)a

  plug(
    RateLimiter,
    [name: :status_id_action, bucket_name: "status_id_action:reblog_unreblog", params: [:id]]
    when action in ~w(reblog unreblog)a
  )

  plug(
    RateLimiter,
    [name: :status_id_action, bucket_name: "status_id_action:fav_unfav", params: [:id]]
    when action in ~w(favourite unfavourite)a
  )

  plug(RateLimiter, [name: :statuses_actions] when action in @rate_limited_status_actions)

  plug(Pleroma.Web.Plugs.SetApplicationPlug, [] when action in [:create, :update])

  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.StatusOperation
  defp try_render(conn, target, params), do: ControllerHelper.try_render(conn, target, params)

  defp add_link_headers(conn, entries), do: ControllerHelper.add_link_headers(conn, entries)

  @doc """
  GET `/api/v1/statuses?ids[]=1&ids[]=2`

  `ids` query param is required
  """
  def index(%{assigns: %{user: user}} = conn, params) do
    ids = Map.get(params, :id, Map.get(params, :ids))
    limit = 100

    activities =
      ids
      |> Enum.take(limit)
      |> Activity.all_by_ids_with_object()
      |> Enum.filter(&Visibility.visible_for_user?(&1, user))

    render(conn, "index.json",
      activities: activities,
      for: user,
      as: :activity,
      with_muted: Map.get(params, :with_muted, false)
    )
  end

  @doc """
  POST /api/v1/statuses
  """
  # Creates a scheduled status when `scheduled_at` param is present and it's far enough
  def create(
        %Plug.Conn{
          assigns: %{user: user},
          body_params: %{status: _, scheduled_at: scheduled_at} = params
        } = conn,
        _
      )
      when not is_nil(scheduled_at) do
    params =
      params
      |> Map.put(:in_reply_to_status_id, params[:in_reply_to_id])
      |> Map.put(:generator, conn.assigns.application)

    attrs = %{
      params: Map.new(params, fn {key, value} -> {to_string(key), value} end),
      scheduled_at: scheduled_at
    }

    with {:far_enough, true} <- {:far_enough, ScheduledActivity.far_enough?(scheduled_at)},
         {:ok, scheduled_activity} <- ScheduledActivity.create(user, attrs) do
      conn
      |> put_view(ScheduledActivityView)
      |> render("show.json", scheduled_activity: scheduled_activity)
    else
      {:far_enough, _} ->
        params = Map.drop(params, [:scheduled_at])
        create(%Plug.Conn{conn | body_params: params}, %{})

      error ->
        error
    end
  end

  # Creates a regular status
  def create(%{assigns: %{user: user}, body_params: %{status: _} = params} = conn, _) do
    params =
      params
      |> Map.put(:in_reply_to_status_id, params[:in_reply_to_id])
      |> Map.put(:generator, conn.assigns.application)

    with {:ok, activity} <- CommonAPI.post(user, params) do
      try_render(conn, "show.json",
        activity: activity,
        for: user,
        as: :activity,
        with_direct_conversation_id: true
      )
    else
      {:error, {:reject, message}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})

      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})
    end
  end

  def create(%Plug.Conn{assigns: %{user: _user}, body_params: %{media_ids: _} = params} = conn, _) do
    params = Map.put(params, :status, "")
    create(%Plug.Conn{conn | body_params: params}, %{})
  end

  @doc "GET /api/v1/statuses/:id/history"
  def show_history(%{assigns: assigns} = conn, %{id: id} = params) do
    with user = assigns[:user],
         %Activity{} = activity <- Activity.get_by_id_with_object(id),
         true <- Visibility.visible_for_user?(activity, user) do
      try_render(conn, "history.json",
        activity: activity,
        for: user,
        with_direct_conversation_id: true,
        with_muted: Map.get(params, :with_muted, false)
      )
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "GET /api/v1/statuses/:id/source"
  def show_source(%{assigns: assigns} = conn, %{id: id} = _params) do
    with user = assigns[:user],
         %Activity{} = activity <- Activity.get_by_id_with_object(id),
         true <- Visibility.visible_for_user?(activity, user) do
      try_render(conn, "source.json",
        activity: activity,
        for: user
      )
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "PUT /api/v1/statuses/:id"
  def update(%{assigns: %{user: user}, body_params: body_params} = conn, %{id: id} = params) do
    with {_, %Activity{}} = {_, activity} <- {:activity, Activity.get_by_id_with_object(id)},
         {_, true} <- {:visible, Visibility.visible_for_user?(activity, user)},
         {_, true} <- {:is_create, activity.data["type"] == "Create"},
         actor <- Activity.user_actor(activity),
         {_, true} <- {:own_status, actor.id == user.id},
         {_, true} <- {:not_event, activity.object.data["type"] != "Event"},
         changes <- body_params |> Map.put(:generator, conn.assigns.application),
         {_, {:ok, _update_activity}} <- {:pipeline, CommonAPI.update(user, activity, changes)},
         {_, %Activity{}} = {_, activity} <- {:refetched, Activity.get_by_id_with_object(id)} do
      try_render(conn, "show.json",
        activity: activity,
        for: user,
        with_direct_conversation_id: true,
        with_muted: Map.get(params, :with_muted, false)
      )
    else
      {:own_status, _} -> {:error, :forbidden}
      {:not_event, _} -> {:error, :unprocessable_entity, "Use event update route"}
      {:pipeline, _} -> {:error, :internal_server_error}
      _ -> {:error, :not_found}
    end
  end

  @doc "GET /api/v1/statuses/:id"
  def show(%{assigns: %{user: user}} = conn, %{id: id} = params) do
    with %Activity{} = activity <- Activity.get_by_id_with_object(id),
         true <- Visibility.visible_for_user?(activity, user) do
      try_render(conn, "show.json",
        activity: activity,
        for: user,
        with_direct_conversation_id: true,
        with_muted: Map.get(params, :with_muted, false)
      )
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "DELETE /api/v1/statuses/:id"
  def delete(%{assigns: %{user: user}} = conn, %{id: id}) do
    with %Activity{} = activity <- Activity.get_by_id_with_object(id),
         {:ok, %Activity{}} <- CommonAPI.delete(id, user) do
      try_render(conn, "show.json",
        activity: activity,
        for: user,
        with_direct_conversation_id: true,
        with_source: true
      )
    else
      _e -> {:error, :not_found}
    end
  end

  @doc "POST /api/v1/statuses/:id/reblog"
  def reblog(%{assigns: %{user: user}, body_params: params} = conn, %{id: ap_id_or_id}) do
    with {:ok, announce} <- CommonAPI.repeat(ap_id_or_id, user, params),
         %Activity{} = announce <- Activity.normalize(announce.data) do
      try_render(conn, "show.json", %{activity: announce, for: user, as: :activity})
    end
  end

  @doc "POST /api/v1/statuses/:id/unreblog"
  def unreblog(%{assigns: %{user: user}} = conn, %{id: activity_id}) do
    with {:ok, _unannounce} <- CommonAPI.unrepeat(activity_id, user),
         %Activity{} = activity <- Activity.get_by_id(activity_id) do
      try_render(conn, "show.json", %{activity: activity, for: user, as: :activity})
    end
  end

  @doc "POST /api/v1/statuses/:id/favourite"
  def favourite(%{assigns: %{user: user}} = conn, %{id: activity_id}) do
    with {:ok, _fav} <- CommonAPI.favorite(user, activity_id),
         %Activity{} = activity <- Activity.get_by_id(activity_id) do
      try_render(conn, "show.json", activity: activity, for: user, as: :activity)
    end
  end

  @doc "POST /api/v1/statuses/:id/unfavourite"
  def unfavourite(%{assigns: %{user: user}} = conn, %{id: activity_id}) do
    with {:ok, _unfav} <- CommonAPI.unfavorite(activity_id, user),
         %Activity{} = activity <- Activity.get_by_id(activity_id) do
      try_render(conn, "show.json", activity: activity, for: user, as: :activity)
    end
  end

  @doc "POST /api/v1/statuses/:id/pin"
  def pin(%{assigns: %{user: user}} = conn, %{id: ap_id_or_id}) do
    with {:ok, activity} <- CommonAPI.pin(ap_id_or_id, user) do
      try_render(conn, "show.json", activity: activity, for: user, as: :activity)
    else
      {:error, :pinned_statuses_limit_reached} ->
        {:error, "You have already pinned the maximum number of statuses"}

      {:error, :ownership_error} ->
        {:error, :unprocessable_entity, "Someone else's status cannot be pinned"}

      {:error, :visibility_error} ->
        {:error, :not_found, "Record not found"}

      {:error, :non_public_error} ->
        {:error, :unprocessable_entity, "Non-public status cannot be pinned"}

      error ->
        error
    end
  end

  @doc "POST /api/v1/statuses/:id/unpin"
  def unpin(%{assigns: %{user: user}} = conn, %{id: ap_id_or_id}) do
    with {:ok, activity} <- CommonAPI.unpin(ap_id_or_id, user) do
      try_render(conn, "show.json", activity: activity, for: user, as: :activity)
    else
      {:error, :visibility_error} ->
        {:error, :not_found, "Record not found"}

      {:error, :ownership_error} ->
        {:error, :unprocessable_entity, "Someone else's status cannot be unpinned"}

      error ->
        error
    end
  end

  @doc "POST /api/v1/statuses/:id/bookmark"
  def bookmark(%{assigns: %{user: user}} = conn, %{id: id}) do
    body_params = if is_map(conn.body_params), do: conn.body_params, else: %{}

    with %Activity{} = activity <- Activity.get_by_id_with_object(id),
         %User{} = user <- User.get_cached_by_nickname(user.nickname),
         true <- Visibility.visible_for_user?(activity, user),
         folder_id <- Map.get(body_params, :folder_id),
         folder_id <-
           if(folder_id && BookmarkFolder.belongs_to_user?(folder_id, user.id),
             do: folder_id,
             else: nil
           ),
         {:ok, _bookmark} <- Bookmark.create(user.id, activity.id, folder_id) do
      try_render(conn, "show.json", activity: activity, for: user, as: :activity)
    else
      false ->
        {:error, :not_found, "Record not found"}

      error ->
        error
    end
  end

  @doc "POST /api/v1/statuses/:id/unbookmark"
  def unbookmark(%{assigns: %{user: user}} = conn, %{id: id}) do
    with %Activity{} = activity <- Activity.get_by_id_with_object(id),
         %User{} = user <- User.get_cached_by_nickname(user.nickname),
         true <- Visibility.visible_for_user?(activity, user),
         {:ok, _bookmark} <- Bookmark.destroy(user.id, activity.id) do
      try_render(conn, "show.json", activity: activity, for: user, as: :activity)
    else
      false ->
        {:error, :not_found, "Record not found"}

      error ->
        error
    end
  end

  @doc "POST /api/v1/statuses/:id/mute"
  def mute_conversation(%{assigns: %{user: user}, body_params: params} = conn, %{id: id}) do
    with %Activity{} = activity <- Activity.get_by_id(id),
         {:ok, activity} <- CommonAPI.add_mute(user, activity, params) do
      try_render(conn, "show.json", activity: activity, for: user, as: :activity)
    else
      {:error, :visibility_error} ->
        {:error, :not_found, "Record not found"}

      error ->
        error
    end
  end

  @doc "POST /api/v1/statuses/:id/unmute"
  def unmute_conversation(%{assigns: %{user: user}} = conn, %{id: id}) do
    with %Activity{} = activity <- Activity.get_by_id(id),
         {:ok, activity} <- CommonAPI.remove_mute(user, activity) do
      try_render(conn, "show.json", activity: activity, for: user, as: :activity)
    else
      {:error, :visibility_error} ->
        {:error, :not_found, "Record not found"}

      error ->
        error
    end
  end

  @doc "GET /api/v1/statuses/:id/card"
  @deprecated "https://github.com/tootsuite/mastodon/pull/11213"
  def card(%{assigns: %{user: user}} = conn, %{id: status_id}) do
    with %Activity{} = activity <- Activity.get_by_id(status_id),
         true <- Visibility.visible_for_user?(activity, user),
         %Card{} = card_data <- Card.get_by_activity(activity) do
      render(conn, "card.json", embed: card_data)
    else
      _ -> render_error(conn, :not_found, "Record not found")
    end
  end

  @doc "GET /api/v1/statuses/:id/favourited_by"
  def favourited_by(%{assigns: %{user: user}} = conn, %{id: id}) do
    with true <- Pleroma.Config.get([:instance, :show_reactions]),
         %Activity{} = activity <- Activity.get_by_id_with_object(id),
         {:visible, true} <- {:visible, Visibility.visible_for_user?(activity, user)},
         %Object{data: %{"likes" => likes}} <- Object.normalize(activity, fetch: false) do
      users =
        User
        |> Ecto.Query.where([u], u.ap_id in ^likes)
        |> Ecto.Query.order_by([u], fragment("array_position(?, ?)", ^likes, u.ap_id))
        |> Repo.all()
        |> Enum.filter(&(not User.blocks?(user, &1)))

      conn
      |> put_view(AccountView)
      |> render("index.json", for: user, users: users, as: :user)
    else
      {:visible, false} -> {:error, :not_found}
      _ -> json(conn, [])
    end
  end

  @doc "GET /api/v1/statuses/:id/reblogged_by"
  def reblogged_by(%{assigns: %{user: user}} = conn, %{id: id}) do
    with %Activity{} = activity <- Activity.get_by_id_with_object(id),
         {:visible, true} <- {:visible, Visibility.visible_for_user?(activity, user)},
         %Object{data: %{"announcements" => announces, "id" => ap_id}} <-
           Object.normalize(activity, fetch: false) do
      announces =
        "Announce"
        |> Activity.Queries.by_type()
        |> Ecto.Query.where([a], a.actor in ^announces)
        # this is to use the index
        |> Activity.Queries.by_object_id(ap_id)
        |> Repo.all()
        |> Enum.filter(&Visibility.visible_for_user?(&1, user))
        |> Enum.map(& &1.actor)
        |> Enum.uniq()

      users =
        User
        |> Ecto.Query.where([u], u.ap_id in ^announces)
        |> Ecto.Query.order_by([u], fragment("array_position(?, ?)", ^announces, u.ap_id))
        |> Repo.all()
        |> Enum.filter(&(not User.blocks?(user, &1)))

      conn
      |> put_view(AccountView)
      |> render("index.json", for: user, users: users, as: :user)
    else
      {:visible, false} -> {:error, :not_found}
      _ -> json(conn, [])
    end
  end

  @doc "GET /api/v1/statuses/:id/quotes"
  def quotes(%{assigns: %{user: user}} = conn, %{id: id} = params) do
    with %Activity{object: object} = activity <- Activity.get_by_id_with_object(id),
         true <- Visibility.visible_for_user?(activity, user) do
      params =
        params
        |> Map.put(:type, "Create")
        |> Map.put(:blocking_user, user)
        |> Map.put(:quote_url, object.data["id"])

      recipients =
        if user do
          [Pleroma.Constants.as_public()] ++ [user.ap_id | User.following(user)]
        else
          [Pleroma.Constants.as_public()]
        end

      activities =
        recipients
        |> ActivityPub.fetch_activities(params)
        |> Enum.reverse()

      conn
      |> add_link_headers(activities)
      |> render("index.json", activities: activities, for: user, as: :activity)
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  end

  @doc "GET /api/v1/statuses/:id/context"
  def context(%{assigns: %{user: user}} = conn, %{id: id}) do
    with %Activity{} = activity <- Activity.get_by_id(id) do
      RemoteReplies.fetch_for_activity(activity)

      activities =
        ActivityPub.fetch_activities_for_context(activity.data["context"], %{
          blocking_user: user,
          user: user,
          exclude_id: activity.id
        })

      render(conn, "context.json", activity: activity, activities: activities, user: user)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "POST /api/v1/statuses/:id/translate"
  def translate(%{body_params: params, assigns: %{user: user}} = conn, %{id: status_id}) do
    with {:authentication, true} <-
           {:authentication,
            !is_nil(user) ||
              Pleroma.Config.get([Pleroma.Language.Translation, :allow_unauthenticated])},
         %Activity{object: object} <- Activity.get_by_id_with_object(status_id),
         {:visibility, visibility} when visibility in ["public", "unlisted"] <-
           {:visibility, Visibility.get_visibility(object)},
         {:allow_remote, true} <-
           {:allow_remote,
            Object.local?(object) ||
              Pleroma.Config.get([Pleroma.Language.Translation, :allow_remote])},
         {:language, language} when is_binary(language) <-
           {:language,
            Map.get(params, :lang) || Map.get(params, :target_language) || user.language},
         {:ok, result} <-
           Translation.translate(
             object.data["content"],
             object.data["language"],
             language
           ) do
      render(conn, "translation.json", result)
    else
      {:authentication, false} ->
        render_error(conn, :unauthorized, "Authorization is required to translate statuses")

      {:allow_remote, false} ->
        render_error(conn, :bad_request, "You can't translate remote posts")

      {:language, nil} ->
        render_error(conn, :bad_request, "Language not specified")

      {:visibility, _} ->
        render_error(conn, :not_found, "Record not found")

      {:error, :not_found} ->
        render_error(conn, :not_found, "Translation service not configured")

      {:error, :unsupported_language} ->
        render_error(conn, :bad_request, "Target language is not supported")

      {:error, error}
      when error in [
             :unexpected_response,
             :quota_exceeded,
             :too_many_requests,
             :internal_server_error
           ] ->
        render_error(conn, :service_unavailable, "Translation service not available")

      nil ->
        render_error(conn, :not_found, "Record not found")
    end
  end

  @doc "GET /api/v1/favourites"
  def favourites(%{assigns: %{user: %User{} = user}} = conn, params) do
    activities = ActivityPub.fetch_favourites(user, params)

    conn
    |> add_link_headers(activities)
    |> render("index.json",
      activities: activities,
      for: user,
      as: :activity
    )
  end

  @doc "GET /api/v1/bookmarks"
  def bookmarks(%{assigns: %{user: user}} = conn, params) do
    user = User.get_cached_by_id(user.id)
    folder_id = Map.get(params, :folder_id)

    bookmarks =
      user.id
      |> Bookmark.for_user_query(folder_id)
      |> Pleroma.Pagination.fetch_paginated(params)

    activities =
      bookmarks
      |> Enum.map(fn b -> Map.put(b.activity, :bookmark, Map.delete(b, :activity)) end)

    conn
    |> add_link_headers(bookmarks)
    |> render("index.json",
      activities: activities,
      for: user,
      as: :activity
    )
  end
end
