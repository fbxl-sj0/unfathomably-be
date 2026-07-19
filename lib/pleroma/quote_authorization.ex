# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.QuoteAuthorization do
  @moduledoc """
  Stores and advances the lifecycle of a quote authorization.

  Quote state is also mirrored into the quote object. Status rendering can
  therefore expose policy decisions without issuing one query per timeline
  row, while this table remains the authoritative transition ledger.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.QuotePolicy
  alias Pleroma.Workers.QuoteAuthorizationWorker

  @states ~w[pending accepted rejected revoked]

  schema "quote_authorizations" do
    belongs_to(:quote_object, Object)
    belongs_to(:quoted_object, Object)
    field(:quote_actor, :string)
    field(:quoted_actor, :string)
    field(:request_ap_id, :string)
    field(:authorization_ap_id, :string)
    field(:state, :string)
    field(:policy, :string)
    field(:local, :boolean, default: false)

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :quote_object_id,
      :quoted_object_id,
      :quote_actor,
      :quoted_actor,
      :request_ap_id,
      :authorization_ap_id,
      :state,
      :policy,
      :local
    ])
    |> validate_required([
      :quote_object_id,
      :quoted_object_id,
      :quote_actor,
      :quoted_actor,
      :state,
      :policy,
      :local
    ])
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:quote_object_id)
    |> unique_constraint(:request_ap_id)
  end

  def get_by_quote_object(%Object{id: id}), do: Repo.get_by(__MODULE__, quote_object_id: id)
  def get_by_quote_object(id), do: Repo.get_by(__MODULE__, quote_object_id: id)

  def get_by_request(ap_id) when is_binary(ap_id),
    do: Repo.get_by(__MODULE__, request_ap_id: ap_id)

  @spec register(Object.t(), boolean()) :: {:ok, Object.t(), boolean()} | {:error, term()}
  def register(%Object{data: %{"quoteUrl" => quote_url}} = quote_object, local)
      when is_binary(quote_url) do
    with %Object{} = quoted_object <- Object.get_by_ap_id(quote_url),
         %User{} = actor <- User.get_cached_by_ap_id(quote_object.data["actor"]),
         %User{} = quoted_actor <- User.get_cached_by_ap_id(quoted_object.data["actor"]) do
      state = initial_state(quote_object, quoted_object, actor)
      authorization = if state == "accepted", do: authorization_uri(quote_object)

      attrs = %{
        quote_object_id: quote_object.id,
        quoted_object_id: quoted_object.id,
        quote_actor: actor.ap_id,
        quoted_actor: quoted_actor.ap_id,
        authorization_ap_id: authorization,
        state: state,
        policy: QuotePolicy.name(quoted_object.data["interactionPolicy"], quoted_object),
        local: local
      }

      case Repo.insert(changeset(%__MODULE__{}, attrs),
             on_conflict: :nothing,
             conflict_target: :quote_object_id,
             returning: true
           ) do
        {:ok, %{id: nil}} ->
          record = get_by_quote_object(quote_object)
          {:ok, put_object_state(quote_object, record), false}

        {:ok, record} ->
          quote_object = put_object_state(quote_object, record)
          {:ok, quote_object, state == "accepted"}

        error ->
          error
      end
    else
      _ -> {:error, :invalid_quote_target}
    end
  end

  def register(%Object{} = object, _local), do: {:ok, object, false}

  def maybe_request(%Object{} = quote_object, false), do: {:ok, quote_object}

  def maybe_request(%Object{} = quote_object, true) do
    with %__MODULE__{state: "pending", request_ap_id: nil} = record <-
           get_by_quote_object(quote_object),
         %Object{} = quoted_object <- Repo.get(Object, record.quoted_object_id),
         %User{} = actor <- User.get_cached_by_ap_id(record.quote_actor),
         {:ok, data, meta} <- Builder.quote_request(actor, quote_object, quoted_object),
         {:ok, %Activity{} = request, _meta} <-
           Pipeline.common_pipeline(data, [local: true] ++ meta),
         {:ok, record} <- update_request(record, request.data["id"]) do
      {:ok, put_object_state(quote_object, record)}
    else
      %__MODULE__{} -> {:ok, quote_object}
      nil -> {:ok, quote_object}
      error -> error
    end
  end

  def handle_request(%Activity{data: data} = request) do
    with %Object{} = quote_object <- Object.get_by_ap_id(data["instrument"]),
         %Object{} = quoted_object <- Object.get_by_ap_id(data["object"]),
         {:ok, quote_object, counted?} <- register(quote_object, false),
         :ok <- maybe_increment(quoted_object.data["id"], counted?),
         %__MODULE__{} = record <- get_by_quote_object(quote_object),
         {:ok, record} <- update_request(record, data["id"]) do
      case QuotePolicy.decision(quoted_object, data["actor"]) do
        :automatic -> accept_request(request, record)
        :manual -> {:ok, put_object_state(quote_object, record)}
        :denied -> reject_request(request, record)
      end
    else
      error -> error
    end
  end

  def accept_from_activity(%Activity{data: request}, actor, authorization)
      when is_binary(authorization) do
    with %__MODULE__{} = record <- get_by_request(request["id"]),
         true <- record.quoted_actor == actor,
         %Object{} = quote_object <- Repo.get(Object, record.quote_object_id) do
      if local_authorization?(authorization, quote_object) do
        transition(record, "accepted", authorization)
      else
        QuoteAuthorizationWorker.enqueue(quote_object.id, authorization)
        {:ok, quote_object}
      end
    else
      _ -> {:error, :invalid_quote_accept}
    end
  end

  def reject_from_activity(%Activity{data: request}, actor) do
    with %__MODULE__{} = record <- get_by_request(request["id"]),
         true <- record.quoted_actor == actor do
      transition(record, "rejected")
    else
      _ -> {:error, :invalid_quote_reject}
    end
  end

  def revoke_from_document(%{
        "attributedTo" => actor,
        "interactingObject" => quote_ap_id,
        "interactionTarget" => target_ap_id
      }) do
    with %Object{} = quote_object <- Object.get_by_ap_id(quote_ap_id),
         %__MODULE__{} = record <- get_by_quote_object(quote_object),
         %Object{data: %{"id" => ^target_ap_id}} <- Repo.get(Object, record.quoted_object_id),
         true <- record.quoted_actor == actor do
      transition(record, "revoked")
    else
      _ -> {:error, :invalid_quote_revocation}
    end
  end

  def approve(%Activity{} = quote_activity, %User{} = user) do
    with %Object{} = quote_object <- Object.normalize(quote_activity, fetch: false),
         %__MODULE__{state: "pending", quoted_actor: actor} = record <-
           get_by_quote_object(quote_object),
         true <- actor == user.ap_id,
         %Activity{} = request <- Activity.get_by_ap_id(record.request_ap_id),
         authorization = authorization_uri(quote_object),
         {:ok, data, meta} <- Builder.accept_quote_request(user, request, authorization),
         {:ok, _activity, _meta} <- Pipeline.common_pipeline(data, [local: true] ++ meta),
         {:ok, _object} <- transition(record, "accepted", authorization) do
      {:ok, Activity.get_by_id_with_object(quote_activity.id)}
    else
      _ -> {:error, :not_found}
    end
  end

  def reject(%Activity{} = quote_activity, %User{} = user) do
    with %Object{} = quote_object <- Object.normalize(quote_activity, fetch: false),
         %__MODULE__{quoted_actor: actor} = record <- get_by_quote_object(quote_object),
         true <- actor == user.ap_id do
      case record.state do
        "pending" -> reject_pending(quote_activity, quote_object, record, user)
        "accepted" -> revoke_accepted(quote_activity, quote_object, record, user)
        _ -> {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def transition(%__MODULE__{} = record, state, authorization \\ nil) when state in @states do
    Repo.transaction(fn ->
      record = Repo.one!(from(q in __MODULE__, where: q.id == ^record.id, lock: "FOR UPDATE"))
      quote_object = Repo.get!(Object, record.quote_object_id)
      quoted_object = Repo.get!(Object, record.quoted_object_id)

      adjust_count(quoted_object.data["id"], record.state, state)

      attrs =
        %{state: state}
        |> maybe_put(:authorization_ap_id, authorization)

      record = record |> changeset(attrs) |> Repo.update!()
      put_object_state(quote_object, record)
    end)
    |> case do
      {:ok, object} -> {:ok, object}
      {:error, error} -> {:error, error}
    end
  end

  def authorization_document(%Object{} = quote_object) do
    with %__MODULE__{state: "accepted"} = record <- get_by_quote_object(quote_object),
         %Object{} = quoted_object <- Repo.get(Object, record.quoted_object_id) do
      {:ok,
       %{
         "id" => authorization_uri(quote_object),
         "type" => "QuoteAuthorization",
         "attributedTo" => record.quoted_actor,
         "interactingObject" => quote_object.data["id"],
         "interactionTarget" => quoted_object.data["id"]
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def authorization_uri(%Object{id: id}) do
    Pleroma.Web.Endpoint.url() <> "/quote_authorizations/" <> to_string(id)
  end

  def visible_state?(%{"quoteState" => state}), do: state == "accepted"
  def visible_state?(_), do: true

  def manageable?(%Object{data: data}, %User{} = user) do
    data["quoteTargetActor"] == user.ap_id and data["quoteState"] in ~w[pending accepted]
  end

  def manageable?(_, _), do: false

  defp initial_state(%Object{data: data}, quoted_object, actor) do
    cond do
      is_binary(data["quoteAuthorization"]) -> "pending"
      QuotePolicy.decision(quoted_object, actor) == :automatic -> "accepted"
      QuotePolicy.decision(quoted_object, actor) == :manual -> "pending"
      true -> "rejected"
    end
  end

  defp accept_request(request, record) do
    quoted_actor = User.get_cached_by_ap_id(record.quoted_actor)
    quote_object = Repo.get!(Object, record.quote_object_id)
    authorization = authorization_uri(quote_object)

    with {:ok, data, meta} <- Builder.accept_quote_request(quoted_actor, request, authorization),
         {:ok, _activity, _meta} <- Pipeline.common_pipeline(data, [local: true] ++ meta) do
      transition(record, "accepted", authorization)
    end
  end

  defp reject_request(request, record) do
    quoted_actor = User.get_cached_by_ap_id(record.quoted_actor)

    with {:ok, data, meta} <- Builder.reject_quote_request(quoted_actor, request),
         {:ok, _activity, _meta} <- Pipeline.common_pipeline(data, [local: true] ++ meta) do
      transition(record, "rejected")
    end
  end

  defp reject_pending(quote_activity, _quote_object, record, user) do
    with %Activity{} = request <- Activity.get_by_ap_id(record.request_ap_id),
         {:ok, data, meta} <- Builder.reject_quote_request(user, request),
         {:ok, _activity, _meta} <- Pipeline.common_pipeline(data, [local: true] ++ meta),
         {:ok, _object} <- transition(record, "rejected") do
      {:ok, Activity.get_by_id_with_object(quote_activity.id)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp revoke_accepted(quote_activity, quote_object, record, user) do
    with {:ok, authorization} <- authorization_document(quote_object),
         {:ok, data, meta} <-
           Builder.delete_quote_authorization(user, authorization, record.quote_actor),
         {:ok, _activity, _meta} <- Pipeline.common_pipeline(data, [local: true] ++ meta),
         {:ok, _object} <- transition(record, "revoked") do
      {:ok, Activity.get_by_id_with_object(quote_activity.id)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp update_request(record, ap_id) do
    record
    |> changeset(%{request_ap_id: ap_id})
    |> Repo.update()
  end

  defp put_object_state(%Object{} = object, %__MODULE__{} = record) do
    data =
      object.data
      |> Map.put("quoteState", record.state)
      |> Map.put("quoteTargetActor", record.quoted_actor)
      |> maybe_put("quoteRequest", record.request_ap_id)
      |> maybe_put("quoteAuthorization", record.authorization_ap_id)

    object
    |> Object.change(%{data: data})
    |> Object.update_and_set_cache()
    |> case do
      {:ok, object} -> object
      _ -> object
    end
  end

  defp maybe_increment(_quote_url, false), do: :ok

  defp maybe_increment(quote_url, true),
    do: Object.increase_quotes_count(quote_url) |> ok_result()

  defp adjust_count(_quote_url, state, state), do: :ok
  defp adjust_count(quote_url, _from, "accepted"), do: Object.increase_quotes_count(quote_url)
  defp adjust_count(quote_url, "accepted", _to), do: Object.decrease_quotes_count(quote_url)
  defp adjust_count(_quote_url, _from, _to), do: :ok

  defp ok_result({:ok, _}), do: :ok
  defp ok_result(_), do: :ok

  defp local_authorization?(authorization, quote_object),
    do: authorization == authorization_uri(quote_object)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of quote_authorization.ex
