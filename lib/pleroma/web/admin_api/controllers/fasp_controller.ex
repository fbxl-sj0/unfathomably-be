# Unfathomably FASP administration
# ---------------------------------
#
# File: fasp_controller.ex
#
# Purpose:
#   Let administrators review FASP registration fingerprints and trust state.
#
# Responsibilities:
#   - list pending, accepted, and rejected registrations
#   - expose provider and local public-key fingerprints
#   - accept a pending relationship without activating capabilities
#   - reject or revoke a relationship and clear active capabilities
#
# This file intentionally does not reveal local private keys, activate
# capabilities, or perform provider network requests.

defmodule Pleroma.Web.AdminAPI.FASPController do
  use Pleroma.Web, :controller

  alias Pleroma.FASP.Client
  alias Pleroma.FASP.Registration
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(OAuthScopesPlug, %{scopes: ["admin:read"]} when action in [:index, :show])

  plug(
    OAuthScopesPlug,
    %{scopes: ["admin:write"]}
    when action in [:approve, :reject, :delete, :refresh, :activate, :deactivate]
  )

  def index(conn, _params) do
    json(conn, %{registrations: Enum.map(Registration.list(), &Registration.public_json/1)})
  end

  def show(conn, %{"id" => id}) do
    case Registration.get(id) do
      %Registration{} = registration -> json(conn, Registration.public_json(registration))
      nil -> not_found(conn)
    end
  end

  def approve(conn, %{"id" => id}) do
    with %Registration{} = registration <- Registration.get(id),
         {:ok, registration} <- Registration.approve(registration) do
      json(conn, Registration.public_json(registration))
    else
      nil -> not_found(conn)
      {:error, :rejected} -> conflict(conn, "A rejected registration must be initiated again")
      {:error, _reason} -> update_failed(conn)
    end
  end

  def reject(conn, %{"id" => id}) do
    with %Registration{} = registration <- Registration.get(id),
         {:ok, registration} <- Registration.reject(registration) do
      json(conn, Registration.public_json(registration))
    else
      nil -> not_found(conn)
      {:error, _reason} -> update_failed(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    with %Registration{} = registration <- Registration.get(id),
         {:ok, _registration} <- Registration.delete_rejected(registration) do
      json(conn, %{ok: true})
    else
      nil -> not_found(conn)
      {:error, :not_rejected} -> conflict(conn, "Only rejected FASP requests can be forgotten")
      {:error, _reason} -> update_failed(conn)
    end
  end

  def refresh(conn, %{"id" => id}) do
    with %Registration{} = registration <- Registration.get(id),
         {:ok, registration} <- Client.refresh_provider_info(registration) do
      json(conn, Registration.public_json(registration))
    else
      nil -> not_found(conn)
      {:error, reason} -> provider_error(conn, reason)
    end
  end

  def activate(conn, %{"id" => id, "capability" => capability, "version" => version}) do
    with %Registration{} = registration <- Registration.get(id),
         {:ok, registration} <- Client.activate(registration, capability, version) do
      json(conn, Registration.public_json(registration))
    else
      nil -> not_found(conn)
      {:error, reason} -> provider_error(conn, reason)
    end
  end

  def deactivate(conn, %{"id" => id, "capability" => capability, "version" => version}) do
    with %Registration{} = registration <- Registration.get(id),
         {:ok, registration} <- Client.deactivate(registration, capability, version) do
      json(conn, Registration.public_json(registration))
    else
      nil -> not_found(conn)
      {:error, reason} -> provider_error(conn, reason)
    end
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: "FASP registration was not found"})
  end

  defp conflict(conn, message) do
    conn |> put_status(:conflict) |> json(%{error: message})
  end

  defp update_failed(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "The FASP registration state could not be changed"})
  end

  defp provider_error(conn, :not_accepted) do
    conflict(conn, "Approve the FASP registration before contacting the provider")
  end

  defp provider_error(conn, :unsupported_capability) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "This FASP capability version is not supported by Unfathomably"})
  end

  defp provider_error(conn, :capability_not_advertised) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "The FASP did not advertise this capability version"})
  end

  defp provider_error(conn, _reason) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "The signed FASP request or response could not be verified"})
  end
end

# end of fasp_controller.ex
