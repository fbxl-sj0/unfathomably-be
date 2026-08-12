# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.PollOptionTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.ObjectValidators.AnswerValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.QuestionOptionsValidator

  test "Question options and Answer votes decode the same HTML entities" do
    option =
      QuestionOptionsValidator.changeset(%QuestionOptionsValidator{}, %{
        "name" => "Cats &amp; dogs",
        "type" => "Note"
      })

    answer =
      AnswerValidator.cast_and_validate(%{
        "id" => "https://remote.example/answers/1",
        "type" => "Answer",
        "actor" => "https://remote.example/users/voter",
        "name" => "Cats &amp; dogs",
        "inReplyTo" => "https://remote.example/polls/1",
        "to" => ["https://remote.example/users/author"]
      })

    assert Ecto.Changeset.get_change(option, :name) == "Cats & dogs"
    assert Ecto.Changeset.get_change(answer, :name) == "Cats & dogs"
  end

  test "accepts Unicode emoji but rejects HTML markup in poll labels" do
    option =
      QuestionOptionsValidator.changeset(%QuestionOptionsValidator{}, %{
        "name" => "No Android for me, I am using a real Linux phone \u{1F427}",
        "type" => "Note"
      })

    assert option.valid?

    markup =
      QuestionOptionsValidator.changeset(%QuestionOptionsValidator{}, %{
        "name" => "<strong>not plain text</strong>",
        "type" => "Note"
      })

    refute markup.valid?
    assert {"must be plain text", []} = Keyword.fetch!(markup.errors, :name)
  end
end

# end of poll_option_test.exs
