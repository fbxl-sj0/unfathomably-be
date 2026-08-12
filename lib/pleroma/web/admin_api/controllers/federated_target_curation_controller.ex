# Unfathomably Backend
#
# File: federated_target_curation_controller.ex
#
# Purpose:
#   Provide an authorized administration workflow for featured remote Groups.
#
# Responsibilities:
#   - resolve identifiers through the existing safe target resolver
#   - reject local accounts and non-Group actors
#   - add, enable, disable, reorder, and remove curation rows
#
# This file intentionally does not follow actors or mutate remote state.

defmodule Pleroma.Web.AdminAPI.FederatedTargetCurationController do
  use Pleroma.Web, :controller

  alias Pleroma.FederatedTargetCuration
  alias Pleroma.Web.AdminAPI.FederatedTargetCurationView
  alias Pleroma.Web.FederatedTarget

  @maximum_identifier_bytes 2048

  def index(%{assigns: %{user: user}} = conn, _params) do
    conn
    |> put_view(FederatedTargetCurationView)
    |> render("index.json", curations: FederatedTargetCuration.list(), for: user)
  end

  def create(%{assigns: %{user: user}} = conn, %{"identifier" => identifier})
      when is_binary(identifier) and byte_size(identifier) <= @maximum_identifier_bytes do
    identifier = String.trim(identifier)

    with false <- identifier == "",
         {:ok, group} <- FederatedTarget.resolve_group(identifier),
         false <- group.local,
         true <- FederatedTarget.group?(group),
         {:ok, curation} <- FederatedTargetCuration.put(group) do
      conn
      |> put_status(:created)
      |> put_view(FederatedTargetCurationView)
      |> render("show.json", curation: curation, for: user)
    else
      true ->
        error(conn, :unprocessable_entity, "Only remote Group actors can be featured.")

      {:error, :curation_limit_reached} ->
        error(conn, :conflict, "The featured Group limit has been reached.")

      {:error, _reason} ->
        error(conn, :unprocessable_entity, "That remote Group could not be resolved.")

      _ ->
        error(conn, :unprocessable_entity, "That identifier is not a remote Group actor.")
    end
  end

  def create(conn, _params) do
    error(conn, :bad_request, "A remote Group handle or URL is required.")
  end

  def update(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    attrs = Map.take(params, ["enabled", "position"])

    with false <- map_size(attrs) == 0,
         {:ok, curation_id} <- Ecto.UUID.cast(id),
         %FederatedTargetCuration{} = curation <- FederatedTargetCuration.get(curation_id),
         {:ok, curation} <- FederatedTargetCuration.update(curation, attrs) do
      conn
      |> put_view(FederatedTargetCurationView)
      |> render("show.json", curation: curation, for: user)
    else
      true ->
        error(conn, :bad_request, "An enabled state or catalog position is required.")

      nil ->
        error(conn, :not_found, "Featured Group not found.")

      :error ->
        error(conn, :not_found, "Featured Group not found.")

      {:error, _reason} ->
        error(conn, :unprocessable_entity, "The featured Group could not be updated.")
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, curation_id} <- Ecto.UUID.cast(id),
         %FederatedTargetCuration{} = curation <- FederatedTargetCuration.get(curation_id),
         {:ok, _curation} <- FederatedTargetCuration.delete(curation) do
      send_resp(conn, :no_content, "")
    else
      nil ->
        error(conn, :not_found, "Featured Group not found.")

      :error ->
        error(conn, :not_found, "Featured Group not found.")

      {:error, _reason} ->
        error(conn, :unprocessable_entity, "The featured Group could not be removed.")
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end

# end of lib/pleroma/web/admin_api/controllers/federated_target_curation_controller.ex
