# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.ChooseAnswerValidator do
  @moduledoc """
  Validates PieFed accepted-answer transitions.

  A reply's own `answer` field is not authority. The transition actor must be
  the thread author or a known manager of an addressed group, and an embedded
  Undo must carry the same actor on both activity layers.
  """

  alias Pleroma.Object.Containment
  alias Pleroma.Web.ActivityPub.AcceptedAnswer

  require Pleroma.Constants

  @max_recipients 128
  @max_reference_bytes 4096

  @spec validate(map()) :: {:ok, map()} | {:error, term()}
  def validate(%{"type" => "ChooseAnswer"} = activity) do
    activity = normalize(activity)

    with :ok <- validate_common(activity),
         {:ok, _actor, _answer, _root} <-
           AcceptedAnswer.validate_transition(activity["actor"], activity["object"]) do
      {:ok, activity}
    else
      {:error, reason} -> error(reason)
    end
  end

  def validate(_activity), do: error(:invalid_activity)

  @spec validate_undo(map()) :: {:ok, map()} | {:error, term()}
  def validate_undo(
        %{
          "type" => "Undo",
          "actor" => actor,
          "object" => %{"type" => "ChooseAnswer", "actor" => actor} = choice
        } = undo
      ) do
    undo = normalize(undo)

    with :ok <- validate_common(undo),
         {:ok, choice} <- validate(choice) do
      {:ok, Map.put(undo, "object", choice)}
    else
      {:error, reason} -> error(reason)
    end
  end

  def validate_undo(_undo), do: error(:invalid_undo)

  defp validate_common(activity) do
    with id when is_binary(id) and byte_size(id) <= @max_reference_bytes <- activity["id"],
         actor when is_binary(actor) and byte_size(actor) <= @max_reference_bytes <-
           activity["actor"],
         object when is_binary(object) and byte_size(object) <= @max_reference_bytes <-
           reference_id(activity["object"]),
         recipients when recipients != [] <- activity["to"] ++ activity["cc"],
         true <- length(recipients) <= @max_recipients,
         :ok <- Containment.contain_origin(id, %{"actor" => actor}) do
      :ok
    else
      _reason -> {:error, :invalid_shape}
    end
  end

  defp normalize(activity) do
    activity
    |> Map.put("object", normalize_object(activity["object"]))
    |> Map.put("to", normalize_recipients(activity["to"]))
    |> Map.put("cc", normalize_recipients(activity["cc"]))
  end

  defp normalize_object(%{"type" => "ChooseAnswer"} = object), do: normalize(object)
  defp normalize_object(value), do: reference_id(value)

  defp normalize_recipients(value) do
    value
    |> List.wrap()
    |> Enum.map(&reference_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_public/1)
    |> Enum.uniq()
  end

  defp normalize_public(value) when value in ["Public", "as:Public"],
    do: Pleroma.Constants.as_public()

  defp normalize_public(value), do: value

  defp reference_id(value) when is_binary(value), do: value
  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(_value), do: nil

  defp error(reason), do: {:error, {:choose_answer, reason}}
end

# end of choose_answer_validator.ex
