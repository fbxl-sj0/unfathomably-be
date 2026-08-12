# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.AcceptedAnswerTest do
  use Pleroma.DataCase

  import Pleroma.Factory

  alias Pleroma.GroupMembership
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.AcceptedAnswer
  alias Pleroma.Web.ActivityPub.ObjectValidators.ChooseAnswerValidator

  require Pleroma.Constants

  setup do
    author = insert(:user)
    moderator = insert(:user)
    stranger = insert(:user)
    group = insert(:user, actor_type: "Group")

    root =
      insert(:note,
        data: %{
          "id" => "https://example.test/questions/1",
          "type" => "Page",
          "actor" => author.ap_id,
          "audience" => group.ap_id,
          "to" => [Pleroma.Constants.as_public()],
          "cc" => [group.ap_id]
        }
      )

    first_answer = answer(root, group, "first", stranger)
    second_answer = answer(root, group, "second", moderator)

    assert {:ok, _membership} =
             GroupMembership.sync_directory_member(group, moderator, "moderator")

    %{
      author: author,
      moderator: moderator,
      stranger: stranger,
      group: group,
      root: root,
      first_answer: first_answer,
      second_answer: second_answer
    }
  end

  test "only the thread author or a group manager can choose an answer", context do
    assert {:ok, _actor, _answer, _root} =
             AcceptedAnswer.validate_transition(
               context.author.ap_id,
               context.first_answer.data["id"]
             )

    assert {:ok, _actor, _answer, _root} =
             AcceptedAnswer.validate_transition(
               context.moderator.ap_id,
               context.first_answer.data["id"]
             )

    assert {:error, :not_authorized} =
             AcceptedAnswer.validate_transition(
               context.stranger.ap_id,
               context.first_answer.data["id"]
             )
  end

  test "a later answer atomically replaces the previous thread selection", context do
    assert {:ok, _answer} =
             AcceptedAnswer.apply(
               choice(context.author, context.first_answer, context.group, "one"),
               true
             )

    assert Object.get_by_ap_id(context.first_answer.data["id"]).data["answer"] == true

    assert {:ok, _answer} =
             AcceptedAnswer.apply(
               choice(context.moderator, context.second_answer, context.group, "two"),
               true
             )

    assert Object.get_by_ap_id(context.first_answer.data["id"]).data["answer"] == false
    assert Object.get_by_ap_id(context.second_answer.data["id"]).data["answer"] == true
  end

  test "embedded Undo uses the same authority checks and clears the selection", context do
    choice = choice(context.author, context.first_answer, context.group, "undo")

    assert {:ok, normalized_choice} = ChooseAnswerValidator.validate(choice)
    assert {:ok, _answer} = AcceptedAnswer.apply(normalized_choice, true)

    undo = %{
      "id" => context.author.ap_id <> "/activities/undo-answer",
      "type" => "Undo",
      "actor" => context.author.ap_id,
      "object" => normalized_choice,
      "to" => normalized_choice["to"],
      "cc" => normalized_choice["cc"]
    }

    assert {:ok, normalized_undo} = ChooseAnswerValidator.validate_undo(undo)
    assert {:ok, _answer} = AcceptedAnswer.apply(normalized_undo["object"], false)
    assert Object.get_by_ap_id(context.first_answer.data["id"]).data["answer"] == false
  end

  defp answer(root, group, suffix, actor) do
    insert(:note,
      data: %{
        "id" => "https://example.test/comments/#{suffix}",
        "type" => "Note",
        "actor" => actor.ap_id,
        "inReplyTo" => root.data["id"],
        "audience" => group.ap_id,
        "to" => [Pleroma.Constants.as_public()],
        "cc" => [group.ap_id]
      }
    )
  end

  defp choice(actor, answer, group, suffix) do
    %{
      "id" => actor.ap_id <> "/activities/choose-answer-#{suffix}",
      "type" => "ChooseAnswer",
      "actor" => actor.ap_id,
      "object" => answer.data["id"],
      "audience" => group.ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.ap_id]
    }
  end
end

# end of accepted_answer_test.exs
