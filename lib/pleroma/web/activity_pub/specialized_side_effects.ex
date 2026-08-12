# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.SpecializedSideEffects do
  @moduledoc """
  Applies validated state transitions that are not part of core ActivityPub.

  Keeping these transitions outside the generic side-effect module prevents a
  specialized activity from accidentally inheriting Like, Announce, or Undo
  behavior merely because its wire shape resembles one of those activities.
  """

  alias Pleroma.Activity
  alias Pleroma.Web.ActivityPub.AcceptedAnswer

  def handle(%Activity{data: %{"type" => "ChooseAnswer"} = data} = activity, meta) do
    with {:ok, _answer} <- AcceptedAnswer.apply(data, true) do
      {:ok, activity, meta}
    end
  end

  def handle(%Activity{data: %{"type" => "Undo"} = data} = activity, meta) do
    case choose_answer_data(data["object"]) do
      %{"type" => "ChooseAnswer"} = choice ->
        with {:ok, _answer} <- AcceptedAnswer.apply(choice, false) do
          {:ok, activity, meta}
        end

      _other_activity ->
        {:ok, activity, meta}
    end
  end

  def handle(activity, meta), do: {:ok, activity, meta}

  def specialized?(%Activity{data: %{"type" => "ChooseAnswer"}}), do: true

  def specialized?(%Activity{data: %{"type" => "Undo", "object" => object}}) do
    match?(%{"type" => "ChooseAnswer"}, choose_answer_data(object))
  end

  def specialized?(_activity), do: false

  defp choose_answer_data(%{"type" => "ChooseAnswer"} = choice), do: choice

  defp choose_answer_data(activity_id) when is_binary(activity_id) do
    case Activity.get_by_ap_id(activity_id) do
      %Activity{data: %{"type" => "ChooseAnswer"} = choice} -> choice
      _activity -> nil
    end
  end

  defp choose_answer_data(_object), do: nil
end

# end of specialized_side_effects.ex
