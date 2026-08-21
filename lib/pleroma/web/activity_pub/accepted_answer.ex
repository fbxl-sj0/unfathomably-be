# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.AcceptedAnswer do
  @moduledoc """
  Stores and applies authority-checked accepted-answer selections.

  PieFed represents this transition with a `ChooseAnswer` activity and also
  mirrors the resulting state as `answer: true` on the selected reply.  The
  normalized row makes the one-answer-per-thread invariant explicit while the
  object field keeps fetched replies and Mastodon-compatible status responses
  useful to clients that do not know about the transition activity.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.GroupMembership
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Utils

  @max_reply_depth 64

  schema "accepted_answer_selections" do
    belongs_to(:root_object, Object)
    belongs_to(:answer_object, Object)
    field(:actor, :string)
    field(:activity_id, :string)

    timestamps()
  end

  def changeset(selection, attrs) do
    selection
    |> cast(attrs, [:root_object_id, :answer_object_id, :actor, :activity_id])
    |> validate_required([:root_object_id, :answer_object_id, :actor, :activity_id])
    |> unique_constraint(:root_object_id)
    |> foreign_key_constraint(:root_object_id)
    |> foreign_key_constraint(:answer_object_id)
  end

  @spec validate_transition(String.t(), String.t()) ::
          {:ok, User.t(), Object.t(), Object.t()} | {:error, atom()}
  def validate_transition(actor_id, answer_id)
      when is_binary(actor_id) and is_binary(answer_id) do
    with %User{} = actor <- User.get_cached_by_ap_id(actor_id),
         %Object{} = answer <- Object.get_cached_by_ap_id(answer_id),
         {:ok, root} <- thread_root(answer),
         true <- authorized?(actor, answer, root) do
      {:ok, actor, answer, root}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_authorized}
      {:error, _reason} = error -> error
    end
  end

  def validate_transition(_actor_id, _answer_id), do: {:error, :invalid_reference}

  @spec apply(map(), boolean()) :: {:ok, Object.t()} | {:error, term()}
  def apply(%{"actor" => actor_id, "object" => answer_ref, "id" => activity_id}, selected)
      when is_boolean(selected) and is_binary(activity_id) do
    answer_id = reference_id(answer_ref)

    with {:ok, _actor, answer, root} <- validate_transition(actor_id, answer_id),
         :ok <- lock_root(root),
         {:ok, answer} <- persist_selection(root, answer, actor_id, activity_id, selected) do
      {:ok, answer}
    end
  end

  def apply(_activity, _selected), do: {:error, :invalid_choose_answer}

  defp persist_selection(root, answer, actor_id, activity_id, true) do
    previous = Repo.get_by(__MODULE__, root_object_id: root.id)

    with :ok <- clear_previous_answer(previous, answer),
         {:ok, _selection} <- upsert_selection(root, answer, actor_id, activity_id),
         {:ok, answer} <- Object.update_data(answer, %{"answer" => true}) do
      {:ok, answer}
    end
  end

  defp persist_selection(root, answer, _actor_id, _activity_id, false) do
    case Repo.get_by(__MODULE__, root_object_id: root.id) do
      %__MODULE__{answer_object_id: answer_id} = selection when answer_id == answer.id ->
        Repo.delete(selection)

      _selection ->
        :ok
    end

    Object.update_data(answer, %{"answer" => false})
  end

  defp clear_previous_answer(
         %__MODULE__{answer_object_id: previous_id},
         %Object{id: current_id}
       )
       when previous_id != current_id do
    case Repo.get(Object, previous_id) do
      %Object{} = previous ->
        case Object.update_data(previous, %{"answer" => false}) do
          {:ok, _object} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        :ok
    end
  end

  defp clear_previous_answer(_selection, _answer), do: :ok

  defp upsert_selection(root, answer, actor_id, activity_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %__MODULE__{}
    |> changeset(%{
      root_object_id: root.id,
      answer_object_id: answer.id,
      actor: actor_id,
      activity_id: activity_id
    })
    |> Repo.insert(
      conflict_target: :root_object_id,
      on_conflict: [
        set: [
          answer_object_id: answer.id,
          actor: actor_id,
          activity_id: activity_id,
          updated_at: now
        ]
      ],
      returning: true
    )
  end

  defp authorized?(actor, answer, root) do
    actor.ap_id == object_actor(root) or
      Enum.any?(thread_groups(answer, root), fn group ->
        actor.ap_id == group.ap_id or GroupMembership.manager?(actor, group)
      end)
  end

  defp thread_groups(answer, root) do
    [answer.data, root.data]
    |> Enum.flat_map(&group_references/1)
    |> Enum.uniq()
    |> Enum.map(&User.get_cached_by_ap_id/1)
    |> Enum.filter(&match?(%User{actor_type: "Group"}, &1))
  end

  defp group_references(data) do
    [data["audience"], data["to"], data["cc"]]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&reference_id/1)
    |> Enum.reject(&is_nil/1)
  end

  defp object_actor(%Object{data: data}) do
    reference_id(data["actor"]) || reference_id(data["attributedTo"])
  end

  defp thread_root(%Object{} = answer) do
    case reference_id(answer.data["inReplyTo"]) do
      parent_id when is_binary(parent_id) ->
        walk_to_root(parent_id, MapSet.new([answer.data["id"]]), 1)

      _missing_parent ->
        {:error, :not_a_reply}
    end
  end

  defp walk_to_root(_object_id, _seen, depth) when depth > @max_reply_depth,
    do: {:error, :reply_depth_exceeded}

  defp walk_to_root(object_id, seen, depth) do
    cond do
      MapSet.member?(seen, object_id) ->
        {:error, :reply_cycle}

      true ->
        case Object.get_cached_by_ap_id(object_id) do
          %Object{} = object ->
            case reference_id(object.data["inReplyTo"]) do
              parent_id when is_binary(parent_id) ->
                walk_to_root(parent_id, MapSet.put(seen, object_id), depth + 1)

              _root ->
                {:ok, object}
            end

          nil ->
            {:error, :unknown_thread_root}
        end
    end
  end

  defp lock_root(%Object{data: %{"id" => object_id}}) when is_binary(object_id) do
    case Repo.query(
           "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
           [object_id],
           Utils.query_timeout()
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_root(_root), do: {:error, :invalid_thread_root}

  defp reference_id(value) when is_binary(value), do: value
  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id([value | _rest]), do: reference_id(value)
  defp reference_id(_value), do: nil
end

# end of accepted_answer.ex
