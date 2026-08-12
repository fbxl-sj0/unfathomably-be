# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.AcceptedAnswerPublisher do
  @moduledoc """
  Builds local accepted-answer transitions and returns the refreshed reply.

  Selection is a `ChooseAnswer` activity. Deselection uses PieFed's embedded
  Undo form so any currently authorized thread owner or moderator can clear a
  stale selection without impersonating the actor that originally chose it.
  """

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.AcceptedAnswer
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Utils

  @spec set(User.t(), Activity.t(), boolean()) :: {:ok, Activity.t()} | {:error, term()}
  def set(%User{} = actor, %Activity{object: %Object{} = answer} = status, selected)
      when is_boolean(selected) do
    with {:ok, _authorized_actor, _authorized_answer, root} <-
           AcceptedAnswer.validate_transition(actor.ap_id, answer.data["id"]),
         {:ok, _transition, _meta} <-
           transition(actor, answer, root, selected)
           |> Pipeline.common_pipeline(local: true),
         %Activity{} = refreshed <- Activity.get_by_id_with_object(status.id) do
      {:ok, refreshed}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
      error -> {:error, error}
    end
  end

  def set(_actor, _status, _selected), do: {:error, :invalid_status}

  defp transition(actor, answer, root, true), do: choose_answer(actor, answer, root)

  defp transition(actor, answer, root, false) do
    choice = choose_answer(actor, answer, root)

    %{
      "id" => Utils.generate_activity_id(),
      "type" => "Undo",
      "actor" => actor.ap_id,
      "object" => Map.delete(choice, "@context"),
      "context" => choice["context"],
      "to" => choice["to"],
      "cc" => choice["cc"]
    }
  end

  defp choose_answer(actor, answer, root) do
    to = recipients(answer.data["to"] || root.data["to"])
    cc = recipients(answer.data["cc"] || root.data["cc"])
    audience = reference_id(answer.data["audience"] || root.data["audience"])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => Utils.generate_activity_id(),
      "type" => "ChooseAnswer",
      "actor" => actor.ap_id,
      "object" => answer.data["id"],
      "audience" => audience,
      "context" => answer.data["context"] || root.data["context"] || root.data["id"],
      "to" => to,
      "cc" => cc
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp recipients(value) do
    value
    |> List.wrap()
    |> Enum.map(&reference_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp reference_id(value) when is_binary(value), do: value
  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(_value), do: nil
end

# end of accepted_answer_publisher.ex
