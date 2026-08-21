# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.AnswerHandlingTest do
  use Pleroma.DataCase

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  setup_all do
    clear_config([:instance, :federating], true)
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  test "incoming, rewrites Note to Answer and increments vote counters" do
    user = insert(:user)

    {:ok, activity} =
      CommonAPI.post(user, %{
        status: "suya...",
        poll: %{options: ["suya", "suya.", "suya.."], expires_in: 10}
      })

    object = Object.normalize(activity, fetch: false)
    assert object.data["repliesCount"] == nil

    data =
      File.read!("test/fixtures/mastodon-vote.json")
      |> Jason.decode!()
      |> Kernel.put_in(["to"], user.ap_id)
      |> Kernel.put_in(["object", "inReplyTo"], object.data["id"])
      |> Kernel.put_in(["object", "to"], user.ap_id)

    {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(data)
    answer_object = Object.normalize(activity, fetch: false)
    assert answer_object.data["type"] == "Answer"
    assert answer_object.data["inReplyTo"] == object.data["id"]

    new_object = Object.get_by_ap_id(object.data["id"])
    assert new_object.data["repliesCount"] == nil

    assert Enum.any?(
             new_object.data["oneOf"],
             fn
               %{"name" => "suya..", "replies" => %{"totalItems" => 1}} -> true
               _ -> false
             end
           )
  end

  test "incoming, rewrites PieFed PollVote to Answer" do
    user = insert(:user)
    voter = insert(:user, local: false, ap_id: "https://remote.example/users/voter")

    {:ok, poll_activity} =
      CommonAPI.post(user, %{
        status: "suya...",
        poll: %{options: ["suya", "suya.", "suya.."], expires_in: 10}
      })

    poll = Object.normalize(poll_activity, fetch: false)

    data = %{
      "id" => "https://remote.example/activities/poll-vote/1",
      "type" => "PollVote",
      "actor" => voter.ap_id,
      "object" => poll.data["id"],
      "choice_text" => "suya..",
      "audience" => user.ap_id
    }

    assert {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(data)

    answer = Object.normalize(activity, fetch: false)
    assert answer.data["type"] == "Answer"
    assert answer.data["name"] == "suya.."
    assert answer.data["inReplyTo"] == poll.data["id"]

    updated_poll = Object.get_by_ap_id(poll.data["id"])

    assert Enum.any?(updated_poll.data["oneOf"], fn
             %{"name" => "suya..", "replies" => %{"totalItems" => 1}} -> true
             _ -> false
           end)
  end

  test "outgoing, rewrites Answer to Note" do
    user = insert(:user)
    voter = insert(:user)

    {:ok, poll_activity} =
      CommonAPI.post(user, %{
        status: "suya...",
        poll: %{options: ["suya", "suya.", "suya.."], expires_in: 10}
      })

    poll_object = Object.normalize(poll_activity, fetch: false)

    {:ok, [%Activity{} = activity], _object} = CommonAPI.vote(voter, poll_object, [2])
    {:ok, data} = Transmogrifier.prepare_outgoing(activity.data)

    assert data["object"]["type"] == "Note"
  end
end
