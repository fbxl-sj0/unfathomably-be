# Unfathomably BE
# ----------------
#
# File: native_object_controller.ex
#
# Purpose:
#   Expose authenticated Worlds object authoring through the Mastodon API.
#
# Responsibilities:
#   - require the normal write:statuses OAuth scope
#   - share the ordinary status-post rate limit
#   - expose bounded metadata candidates through the normal search controls
#   - render successful objects with the existing status view
#
# This file intentionally does not define ActivityPub vocabularies or accept
# arbitrary object maps.

defmodule Pleroma.Web.MastodonAPI.NativeObjectController do
  use Pleroma.Web, :controller

  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.ActivityPub.NativeCatalog
  alias Pleroma.Web.ActivityPub.NativeObject
  alias Pleroma.Web.ActivityPub.NativeObjectLifecycle
  alias Pleroma.Web.ActivityPub.NativeObjectResolver
  alias Pleroma.Web.MastodonAPI.StatusView
  alias Pleroma.Web.Plugs.OAuthScopesPlug
  alias Pleroma.Web.Plugs.RateLimiter
  alias Pleroma.User
  alias Pleroma.WorldObjectState

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:search"]} when action in [:catalog, :connectors, :resolve]
  )

  plug(OAuthScopesPlug, %{scopes: ["write:statuses"]} when action in [:create, :transition])
  plug(
    OAuthScopesPlug,
    %{scopes: ["read:statuses"]} when action in [:workspace_state, :workspace_states]
  )

  plug(
    OAuthScopesPlug,
    %{scopes: ["write:statuses"]} when action in [:put_workspace_state, :delete_workspace_state]
  )
  plug(RateLimiter, [name: :search] when action in [:catalog, :connectors, :resolve])
  plug(RateLimiter, [name: :statuses_post] when action in [:create, :transition])

  @doc "GET /api/v1/discovery/native-objects/catalog"
  def catalog(conn, params) do
    case NativeCatalog.search(params["template"], params["q"], params["category"]) do
      {:ok, results} ->
        json(conn, %{results: results})

      {:error, :invalid_query} ->
        catalog_error(conn, :unprocessable_entity, "Enter between 2 and 100 characters")

      {:error, :invalid_category} ->
        catalog_error(conn, :unprocessable_entity, "Choose a supported catalog category")

      {:error, :unsupported_template} ->
        catalog_error(
          conn,
          :unprocessable_entity,
          "No metadata catalog is available for this type"
        )

      {:error, :provider_unavailable} ->
        catalog_error(
          conn,
          :service_unavailable,
          "The metadata catalog is temporarily unavailable"
        )
    end
  end

  @doc "GET /api/v1/discovery/native-objects/connectors"
  def connectors(conn, _params), do: json(conn, Marketplace.connector_status())

  @doc "GET /api/v1/discovery/native-objects/resolve"
  def resolve(%{assigns: %{user: user}} = conn, %{"q" => query}) do
    case NativeObjectResolver.resolve(user, query) do
      {:ok, {:status, activity}} ->
        status =
          StatusView.render("show.json",
            activity: activity,
            for: user,
            as: :activity,
            with_direct_conversation_id: true
          )

        json(conn, %{result_type: "status", status: status})

      {:ok, {:resource, resource}} ->
        json(conn, %{result_type: "resource", resource: resource})

      {:error, :invalid_url} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Enter a complete HTTP(S) object URL"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No public native object was found at that URL"})
    end
  end

  def resolve(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Enter a complete HTTP(S) object URL"})
  end

  @doc "POST /api/v1/discovery/native-objects"
  def create(%{assigns: %{user: user}} = conn, params) do
    with {:ok, activity} <- NativeObject.create(user, params) do
      conn
      |> put_view(StatusView)
      |> render("show.json",
        activity: activity,
        for: user,
        as: :activity,
        with_direct_conversation_id: true
      )
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: public_error(reason)})
    end
  end

  @doc "PATCH /api/v1/discovery/native-objects/:id/state"
  def transition(%{assigns: %{user: user}} = conn, %{"id" => id, "state" => state}) do
    case NativeObjectLifecycle.transition(user, id, state) do
      {:ok, activity} ->
        conn
        |> put_view(StatusView)
        |> render("show.json",
          activity: activity,
          for: user,
          as: :activity,
          with_direct_conversation_id: true
        )

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Native object not found"})

      {:error, :unsupported_family} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "This object has no lifecycle states"})

      {:error, :invalid_state} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid lifecycle state"})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "The lifecycle state could not be changed"})
    end
  end

  def transition(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "A lifecycle state is required"})
  end

  @doc "GET /api/v1/discovery/native-objects/state"
  def workspace_state(%{assigns: %{user: user}} = conn, params) do
    object_uri = params["object_uri"]
    entry = WorldObjectState.get(user, object_uri)
    family = params["family"] || if(entry, do: entry.family)

    json(conn, %{
      state: render_workspace_state(entry),
      allowed_states: WorldObjectState.allowed_states(family)
    })
  end

  @doc "GET /api/v1/discovery/native-objects/states"
  def workspace_states(%{assigns: %{user: user}} = conn, params) do
    json(conn, %{states: Enum.map(WorldObjectState.list(user, params), &render_workspace_state/1)})
  end

  @doc "GET /api/v1/discovery/native-objects/states/account/:id"
  def account_workspace_states(conn, %{"id" => id} = params) do
    reading_user = conn.assigns[:user]

    with %User{} = user <- User.get_cached_by_nickname_or_id(id, for: reading_user),
         :visible <- User.visible_for(user, reading_user) do
      json(conn, %{
        states: Enum.map(WorldObjectState.list_public(user, params), &render_public_workspace_state/1)
      })
    else
      _error -> conn |> put_status(:not_found) |> json(%{error: "Account not found"})
    end
  end

  @doc "PUT /api/v1/discovery/native-objects/state"
  def put_workspace_state(%{assigns: %{user: user}, body_params: params} = conn, _route_params) do
    case WorldObjectState.put(user, params) do
      {:ok, entry} ->
        json(conn, %{
          state: render_workspace_state(entry),
          allowed_states: WorldObjectState.allowed_states(entry.family)
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: changeset_error(changeset)})
    end
  end

  @doc "DELETE /api/v1/discovery/native-objects/state"
  def delete_workspace_state(%{assigns: %{user: user}} = conn, params) do
    object_uri = params["object_uri"] || conn.body_params["object_uri"]

    case WorldObjectState.remove(user, object_uri) do
      {:ok, _entry} -> json(conn, %{})
      {:error, _reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid object URI"})
    end
  end

  defp public_error(reason) when is_binary(reason), do: reason
  defp public_error(_reason), do: "The native object could not be created"

  defp render_workspace_state(nil), do: nil

  defp render_workspace_state(entry) do
    %{
      id: to_string(entry.id),
      object_uri: entry.object_uri,
      family: entry.family,
      state: entry.state,
      progress: entry.progress,
      progress_total: entry.progress_total,
      progress_unit: entry.progress_unit,
      rating: entry.rating,
      note: entry.note,
      public: entry.public,
      presentation: entry.presentation,
      started_at: entry.started_at,
      finished_at: entry.finished_at,
      updated_at: entry.updated_at
    }
  end

  # A public participation entry exposes the workflow state, not the private
  # notebook attached to it. Sharing a shelf or completion state must never
  # turn a personal note into profile content.
  defp render_public_workspace_state(entry) do
    entry
    |> render_workspace_state()
    |> Map.put(:note, nil)
  end

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> List.first()
    |> Kernel.||("The workspace state is invalid")
  end

  defp changeset_error(_error), do: "The workspace state could not be saved"

  defp catalog_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end

# end of lib/pleroma/web/mastodon_api/controllers/native_object_controller.ex
