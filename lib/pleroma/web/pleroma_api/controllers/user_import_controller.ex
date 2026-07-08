# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.UserImportController do
  use Pleroma.Web, :controller

  require Logger

  alias Pleroma.User
  alias Pleroma.User.PostArchiveImport
  alias Pleroma.Web.ApiSpec
  alias Pleroma.Web.PleromaAPI.PostArchiveImportView
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["follow", "write:follows"]} when action == :follow)
  plug(OAuthScopesPlug, %{scopes: ["follow", "write:blocks"]} when action == :blocks)
  plug(OAuthScopesPlug, %{scopes: ["follow", "write:mutes"]} when action == :mutes)
  plug(OAuthScopesPlug, %{scopes: ["write:statuses"]} when action == :post_archive)
  plug(OAuthScopesPlug, %{scopes: ["read:accounts"]} when action == :post_archive_imports)

  plug(Pleroma.Web.ApiSpec.CastAndValidate)
  defdelegate open_api_operation(action), to: ApiSpec.UserImportOperation
  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  def follow(%Plug.Conn{} = conn, _) do
    case body_param(conn, :list) do
      %Plug.Upload{path: path} ->
        read_import_file(conn, path, &follow(&1, %{}))

      list when is_binary(list) ->
        %{assigns: %{user: follower}} = conn

        identifiers =
          list
          |> String.split("\n")
          |> Enum.map(&(&1 |> String.split(",") |> List.first()))
          |> List.delete("Account address")
          |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("@")))
          |> Enum.reject(&(&1 == ""))

        User.Import.follows_import(follower, identifiers)
        json(conn, "job started")

      _ ->
        render_error(conn, :bad_request, "Missing import list")
    end
  end

  def blocks(%Plug.Conn{} = conn, _) do
    case body_param(conn, :list) do
      %Plug.Upload{path: path} ->
        read_import_file(conn, path, &blocks(&1, %{}))

      list when is_binary(list) ->
        %{assigns: %{user: blocker}} = conn

        User.Import.blocks_import(blocker, prepare_user_identifiers(list))
        json(conn, "job started")

      _ ->
        render_error(conn, :bad_request, "Missing import list")
    end
  end

  def mutes(%Plug.Conn{} = conn, _) do
    case body_param(conn, :list) do
      %Plug.Upload{path: path} ->
        read_import_file(conn, path, &mutes(&1, %{}))

      list when is_binary(list) ->
        %{assigns: %{user: user}} = conn

        User.Import.mutes_import(user, prepare_user_identifiers(list))
        json(conn, "job started")

      _ ->
        render_error(conn, :bad_request, "Missing import list")
    end
  end

  def post_archive_imports(%{assigns: %{user: user}} = conn, _params) do
    imports = PostArchiveImport.list(user)

    conn
    |> put_view(PostArchiveImportView)
    |> render("index.json", post_archive_imports: imports)
  end

  def post_archive(
        %{assigns: %{user: user}, body_params: %{archive: %Plug.Upload{} = upload}} = conn,
        _params
      ) do
    with {:ok, import} <- PostArchiveImport.create(user, upload) do
      conn
      |> put_view(PostArchiveImportView)
      |> render("show.json", post_archive_import: import)
    end
  end

  defp prepare_user_identifiers(list) do
    list
    |> String.split()
    |> Enum.map(&String.trim_leading(&1, "@"))
  end

  defp body_param(%Plug.Conn{body_params: body_params}, key) do
    Map.get(body_params, key) || Map.get(body_params, Atom.to_string(key))
  end

  defp read_import_file(%Plug.Conn{} = conn, path, next) do
    case File.read(path) do
      {:ok, list} ->
        next.(%Plug.Conn{conn | body_params: %{"list" => list}})

      {:error, reason} ->
        Logger.warning("Could not read import file #{inspect(path)}: #{inspect(reason)}")
        render_error(conn, :bad_request, "Could not read import file")
    end
  end
end
