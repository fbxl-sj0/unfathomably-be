# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.EmojiReactionController do
  use Pleroma.Web, :controller

  import Ecto.Query, only: [where: 3]

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.MastodonAPI.StatusView
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(Pleroma.Web.ApiSpec.CastAndValidate)

  plug(
    OAuthScopesPlug,
    %{scopes: ["write:statuses"]} when action in [:create, :delete, :dislike, :undislike]
  )

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:statuses"], fallback: :proceed_unauthenticated}
    when action in [:index, :disliked_by]
  )

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.EmojiReactionOperation

  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  def index(%{assigns: %{user: user}} = conn, %{id: activity_id} = params) do
    with true <- Pleroma.Config.get([:instance, :show_reactions]),
         %Activity{} = activity <- Activity.get_by_id_with_object(activity_id),
         {_, true} <- {:visible, Visibility.visible_for_user?(activity, user)},
         %Object{} = object <- Object.normalize(activity, fetch: false),
         reactions <- Object.get_emoji_reactions(object) do
      reactions =
        reactions
        |> filter(params)
        |> filter_allowed_users(user, Map.get(params, :with_muted, false))

      render(conn, "index.json", emoji_reactions: reactions, user: user)
    else
      {:visible, _} -> {:error, :forbidden}
      _e -> json(conn, [])
    end
  end

  def filter_allowed_users(reactions, user, with_muted) do
    exclude_ap_ids =
      user
      |> excluded_reaction_user_ap_ids(with_muted)
      |> MapSet.new()

    reactions
    |> enumerable_reactions()
    |> Stream.map(&filter_emoji_reaction(&1, exclude_ap_ids))
    |> Stream.reject(&is_nil/1)
  end

  defp enumerable_reactions(reactions) when is_list(reactions) or is_map(reactions), do: reactions
  defp enumerable_reactions(_reactions), do: []

  defp excluded_reaction_user_ap_ids(nil, _with_muted), do: []

  defp excluded_reaction_user_ap_ids(user, with_muted) do
    blocked_ap_ids = cached_relation_ap_ids(fn -> User.cached_blocked_users_ap_ids(user) end)

    muted_ap_ids =
      if include_muted_users?(with_muted) do
        []
      else
        cached_relation_ap_ids(fn -> User.cached_muted_users_ap_ids(user) end)
      end

    blocked_ap_ids ++ muted_ap_ids
  end

  defp cached_relation_ap_ids(fun) do
    case fun.() do
      ap_ids when is_list(ap_ids) -> ap_ids
      _ -> []
    end
  end

  defp include_muted_users?(value), do: value in [true, "true", "1", 1]

  defp filter_emoji_reaction([emoji, users], exclude_ap_ids) do
    filter_emoji_reaction([emoji, users, nil], exclude_ap_ids)
  end

  defp filter_emoji_reaction({emoji, users}, exclude_ap_ids) do
    filter_emoji_reaction([emoji, users, nil], exclude_ap_ids)
  end

  defp filter_emoji_reaction([emoji, users, url], exclude_ap_ids)
       when is_binary(emoji) and is_list(users) and (is_binary(url) or is_nil(url)) do
    users =
      users
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&MapSet.member?(exclude_ap_ids, &1))

    case users do
      [] -> nil
      users -> {emoji, users, url}
    end
  end

  defp filter_emoji_reaction(_reaction, _exclude_ap_ids), do: nil

  defp filter(reactions, %{emoji: emoji}) when is_binary(emoji) do
    Enum.filter(reactions, fn
      [e, _, _] -> e == emoji
      _ -> false
    end)
  end

  defp filter(reactions, _), do: reactions

  def create(%{assigns: %{user: user}} = conn, %{id: activity_id, emoji: emoji}) do
    emoji =
      emoji
      |> Pleroma.Emoji.fully_qualify_emoji()
      |> Pleroma.Emoji.maybe_quote()

    with {:ok, _activity} <- CommonAPI.react_with_emoji(activity_id, user, emoji) do
      activity = Activity.get_by_id(activity_id)

      conn
      |> put_view(StatusView)
      |> render("show.json", activity: activity, for: user, as: :activity)
    end
  end

  def delete(%{assigns: %{user: user}} = conn, %{id: activity_id, emoji: emoji}) do
    emoji =
      emoji
      |> Pleroma.Emoji.fully_qualify_emoji()
      |> Pleroma.Emoji.maybe_quote()

    with {:ok, _activity} <- CommonAPI.unreact_with_emoji(activity_id, user, emoji) do
      activity = Activity.get_by_id(activity_id)

      conn
      |> put_view(StatusView)
      |> render("show.json", activity: activity, for: user, as: :activity)
    end
  end

  def dislike(%{assigns: %{user: user}} = conn, %{id: activity_id}) do
    with {:ok, _activity} <- CommonAPI.dislike(activity_id, user) do
      render_status(conn, activity_id, user)
    end
  end

  def undislike(%{assigns: %{user: user}} = conn, %{id: activity_id}) do
    with {:ok, _activity} <- CommonAPI.undislike(activity_id, user) do
      render_status(conn, activity_id, user)
    end
  end

  def disliked_by(%{assigns: %{user: user}} = conn, %{id: activity_id}) do
    with true <- Pleroma.Config.get([:instance, :show_reactions]),
         %Activity{} = activity <- Activity.get_by_id_with_object(activity_id),
         {_, true} <- {:visible, Visibility.visible_for_user?(activity, user)},
         %Object{} = object <- Object.normalize(activity, fetch: false) do
      users = dislike_users(object, user)

      conn
      |> put_view(AccountView)
      |> render("index.json", for: user, users: users, as: :user)
    else
      {:visible, _} -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  defp dislike_users(object, user) do
    ap_ids =
      object
      |> Object.get_emoji_reactions()
      |> enumerable_reactions()
      |> Enum.find_value([], fn
        ["👎", users, _url] when is_list(users) -> users
        {"👎", users, _url} when is_list(users) -> users
        _ -> nil
      end)
      |> Enum.filter(&is_binary/1)

    User
    |> where([u], u.ap_id in ^ap_ids)
    |> Repo.all()
    |> Enum.reject(&User.blocks?(user, &1))
  end

  defp render_status(conn, activity_id, user) do
    activity = Activity.get_by_id(activity_id)

    conn
    |> put_view(StatusView)
    |> render("show.json", activity: activity, for: user, as: :activity)
  end
end
