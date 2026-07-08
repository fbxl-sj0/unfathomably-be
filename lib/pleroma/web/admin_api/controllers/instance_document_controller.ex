# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.AdminAPI.InstanceDocumentController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.InstanceDocument
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(Pleroma.Web.ApiSpec.CastAndValidate)

  action_fallback(Pleroma.Web.AdminAPI.FallbackController)

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.Admin.InstanceDocumentOperation

  plug(OAuthScopesPlug, %{scopes: ["admin:read"]} when action == :show)
  plug(OAuthScopesPlug, %{scopes: ["admin:write"]} when action in [:update, :delete])

  def show(conn, %{name: document_name}) do
    with {:ok, url} <- InstanceDocument.get(document_name),
         {:ok, content} <- read_instance_document(url) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, content)
    end
  end

  defp read_instance_document(url) do
    path = String.trim_leading(url, "/")

    [
      Path.join(Pleroma.Config.get!([:instance, :static_dir]), path),
      Path.join(Application.app_dir(:pleroma, "priv/static"), path)
    ]
    |> Enum.find_value({:error, :enoent}, fn candidate ->
      if File.exists?(candidate) do
        File.read(candidate)
      end
    end)
  end

  def update(%{body_params: %{file: file}} = conn, %{name: document_name}) do
    with {:ok, url} <- InstanceDocument.put(document_name, file.path) do
      json(conn, %{"url" => url})
    end
  end

  def delete(conn, %{name: document_name}) do
    with :ok <- InstanceDocument.delete(document_name) do
      json(conn, %{})
    end
  end
end
