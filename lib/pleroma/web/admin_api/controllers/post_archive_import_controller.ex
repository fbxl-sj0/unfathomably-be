# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.AdminAPI.PostArchiveImportController do
  use Pleroma.Web, :controller

  alias Pleroma.User.PostArchiveImport
  alias Pleroma.Web.Plugs.OAuthScopesPlug
  alias Pleroma.Web.PleromaAPI.PostArchiveImportView

  plug(OAuthScopesPlug, %{scopes: ["admin:read"]} when action in [:index])
  plug(OAuthScopesPlug, %{scopes: ["admin:write"]} when action in [:approve, :reject])

  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  def index(conn, _params) do
    imports = PostArchiveImport.list_reviewable()

    conn
    |> put_view(PostArchiveImportView)
    |> render("index.json", post_archive_imports: imports)
  end

  def approve(%{assigns: %{user: admin}} = conn, %{"id" => id}) do
    with %PostArchiveImport{} = import <- PostArchiveImport.get(id),
         {:ok, import} <- PostArchiveImport.approve(import, admin) do
      conn
      |> put_view(PostArchiveImportView)
      |> render("show.json", post_archive_import: import)
    end
  end

  def reject(%{assigns: %{user: admin}, body_params: params} = conn, %{"id" => id}) do
    reason = params["reason"] || params[:reason]

    with %PostArchiveImport{} = import <- PostArchiveImport.get(id),
         {:ok, import} <- PostArchiveImport.reject(import, admin, reason) do
      conn
      |> put_view(PostArchiveImportView)
      |> render("show.json", post_archive_import: import)
    end
  end
end
