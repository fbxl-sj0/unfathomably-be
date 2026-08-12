# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.FeatureAuthorization do
  @moduledoc """
  Stores FEP-7aa9 consent for featuring a local actor in a remote collection.

  Consent follows the actor's discoverability setting. Stored authorizations
  become unavailable immediately when that setting is disabled, so an old
  authorization URL cannot outlive the policy that granted it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.Activity
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.Endpoint

  schema "feature_authorizations" do
    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)
    field(:requester_actor, :string)
    field(:collection_uri, :string)
    field(:request_ap_id, :string)

    timestamps(updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:user_id, :requester_actor, :collection_uri, :request_ap_id])
    |> validate_required([:user_id, :requester_actor, :collection_uri, :request_ap_id])
    |> unique_constraint([:user_id, :collection_uri])
    |> unique_constraint(:request_ap_id)
  end

  def handle_request(
        %Activity{
          data: %{
            "actor" => requester_actor,
            "object" => featured_actor,
            "instrument" => collection_uri
          }
        } = request
      ) do
    with %User{local: true, is_active: true} = user <-
           User.get_cached_by_ap_id(featured_actor),
         %User{is_active: true} <- User.get_cached_by_ap_id(requester_actor) do
      if user.is_discoverable do
        accept_request(request, user, requester_actor, collection_uri)
      else
        reject_request(request, user)
      end
    else
      _other -> {:error, :invalid_feature_request}
    end
  end

  def handle_request(_request), do: {:error, :invalid_feature_request}

  def authorization_document(id) do
    with %__MODULE__{} = authorization <- Repo.get(__MODULE__, id),
         %User{local: true, is_active: true, is_discoverable: true} = user <-
           Repo.preload(authorization, :user).user do
      {:ok,
       %{
         "id" => authorization_uri(authorization),
         "type" => "FeatureAuthorization",
         "interactingObject" => authorization.collection_uri,
         "interactionTarget" => user.ap_id
       }}
    else
      _other -> {:error, :not_found}
    end
  end

  def authorization_uri(%__MODULE__{id: id}) when not is_nil(id),
    do: String.trim_trailing(Endpoint.url(), "/") <> "/feature_authorizations/" <> to_string(id)

  def cacheable_document?(id), do: match?({:ok, _document}, authorization_document(id))

  defp accept_request(request, user, requester_actor, collection_uri) do
    attrs = %{
      user_id: user.id,
      requester_actor: requester_actor,
      collection_uri: collection_uri,
      request_ap_id: request.data["id"]
    }

    with {:ok, authorization} <- get_or_create(attrs),
         {:ok, data, meta} <- Builder.accept(user, request),
         data = Map.put(data, "result", authorization_uri(authorization)),
         {:ok, _activity, _meta} <- Pipeline.common_pipeline(data, [local: true] ++ meta) do
      {:ok, authorization}
    end
  end

  defp reject_request(request, user) do
    with {:ok, data, meta} <- Builder.reject(user, request),
         {:ok, activity, _meta} <- Pipeline.common_pipeline(data, [local: true] ++ meta) do
      {:ok, activity}
    end
  end

  defp get_or_create(attrs) do
    case Repo.insert(changeset(%__MODULE__{}, attrs), on_conflict: :nothing, returning: true) do
      {:ok, %__MODULE__{id: nil}} -> find_matching(attrs)
      {:ok, %__MODULE__{} = authorization} -> {:ok, authorization}
      {:error, _changeset} -> find_matching(attrs)
    end
  end

  defp find_matching(attrs) do
    authorization =
      Repo.get_by(__MODULE__, user_id: attrs.user_id, collection_uri: attrs.collection_uri) ||
        Repo.get_by(__MODULE__, request_ap_id: attrs.request_ap_id)

    case authorization do
      %__MODULE__{user_id: user_id, collection_uri: collection_uri}
      when user_id == attrs.user_id and collection_uri == attrs.collection_uri ->
        {:ok, authorization}

      _other ->
        {:error, :feature_authorization_conflict}
    end
  end
end

# end of feature_authorization.ex
