# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.FederatorTest do
  alias Pleroma.Instances
  alias Pleroma.Object
  alias Pleroma.Tests.ObanHelpers
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.PublisherWorker

  use Pleroma.DataCase
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory
  import Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)

    :ok
  end

  setup_all do: clear_config([:instance, :federating], true)
  setup do: clear_config([:instance, :allow_relay])
  setup do: clear_config([:mrf, :policies])
  setup do: clear_config([:mrf_keyword])

  describe "Publish an activity" do
    setup do
      user = insert(:user)
      {:ok, activity} = CommonAPI.post(user, %{status: "HI"})

      relay_mock = {
        Pleroma.Web.ActivityPub.Relay,
        [],
        [publish: fn _activity -> send(self(), :relay_publish) end]
      }

      %{activity: activity, relay_mock: relay_mock}
    end

    test "with relays active, it publishes to the relay", %{
      activity: activity,
      relay_mock: relay_mock
    } do
      with_mocks([relay_mock]) do
        Federator.publish(activity)
        ObanHelpers.perform(all_enqueued(worker: PublisherWorker))
      end

      assert_received :relay_publish
    end

    test "with relays deactivated, it does not publish to the relay", %{
      activity: activity,
      relay_mock: relay_mock
    } do
      clear_config([:instance, :allow_relay], false)

      with_mocks([relay_mock]) do
        Federator.publish(activity)
        ObanHelpers.perform(all_enqueued(worker: PublisherWorker))
      end

      refute_received :relay_publish
    end
  end

  describe "Targets reachability filtering in `publish`" do
    test "it federates only to reachable instances via AP" do
      user = insert(:user)

      {inbox1, inbox2} =
        {"https://domain.com/users/nick1/inbox", "https://domain2.com/users/nick2/inbox"}

      insert(:user, %{
        local: false,
        nickname: "nick1@domain.com",
        ap_id: "https://domain.com/users/nick1",
        inbox: inbox1
      })

      insert(:user, %{
        local: false,
        nickname: "nick2@domain2.com",
        ap_id: "https://domain2.com/users/nick2",
        inbox: inbox2
      })

      dt = NaiveDateTime.utc_now()
      Instances.set_unreachable(inbox1, dt)

      Instances.set_consistently_unreachable(URI.parse(inbox2).host)

      {:ok, _activity} =
        CommonAPI.post(user, %{status: "HI @nick1@domain.com, @nick2@domain2.com!"})

      expected_dt = NaiveDateTime.to_iso8601(dt)

      ObanHelpers.perform(all_enqueued(worker: PublisherWorker))

      assert ObanHelpers.member?(
               %{
                 "op" => "publish_one",
                 "params" => %{"inbox" => inbox1, "unreachable_since" => expected_dt}
               },
               all_enqueued(worker: PublisherWorker)
             )
    end
  end

  describe "Receive an activity" do
    test "successfully processes incoming AP docs with correct origin" do
      params = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "actor" => "http://mastodon.example.org/users/admin",
        "type" => "Create",
        "id" => "http://mastodon.example.org/users/admin/activities/1",
        "object" => %{
          "type" => "Note",
          "content" => "hi world!",
          "id" => "http://mastodon.example.org/users/admin/objects/1",
          "attributedTo" => "http://mastodon.example.org/users/admin",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        },
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:ok, job} = Federator.incoming_ap_doc(params)
      assert {:ok, _activity} = ObanHelpers.perform(job)

      assert {:ok, job} = Federator.incoming_ap_doc(params)
      assert {:cancel, :already_present} = ObanHelpers.perform(job)
    end

    test "reprocesses a native Create that shares its fallback activity ID" do
      actor = "http://mastodon.example.org/users/admin"
      object_id = "http://mastodon.example.org/users/admin/reviews/1"

      fallback = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "actor" => actor,
        "type" => "Create",
        "id" => "http://mastodon.example.org/users/admin/activities/review-1",
        "object" => %{
          "type" => "Article",
          "content" => "A compatibility review",
          "id" => object_id,
          "attributedTo" => actor,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["#{actor}/followers"]
        },
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => ["#{actor}/followers"]
      }

      assert {:ok, job} = Federator.incoming_ap_doc(fallback)
      assert {:ok, _activity} = ObanHelpers.perform(job)
      assert Object.get_by_ap_id(object_id).data["type"] == "Article"

      native =
        put_in(fallback, ["object"], %{
          "type" => "Review",
          "content" => "The native review",
          "id" => object_id,
          "attributedTo" => actor,
          "rating" => 4.5,
          "inReplyToBook" => "http://mastodon.example.org/books/1",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["#{actor}/followers"]
        })

      stored = Object.get_by_ap_id(object_id)

      assert CustomObject.compatibility_upgrade?(stored.data, native["object"], actor),
             inspect(stored: stored.data, incoming: native["object"])

      assert {:ok, job} = Federator.incoming_ap_doc(native)
      assert {:ok, _activity} = ObanHelpers.perform(job)

      upgraded = Object.get_by_ap_id(object_id)
      assert upgraded.data["type"] == "Review"
      assert upgraded.data["rating"] == 4.5
    end

    test "processes a BookWyrm Delete that reuses its Create activity ID" do
      actor = "http://mastodon.example.org/users/admin"
      activity_id = "http://mastodon.example.org/users/admin/comments/1/activity"
      object_id = "http://mastodon.example.org/users/admin/comments/1"

      create = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "actor" => actor,
        "type" => "Create",
        "id" => activity_id,
        "object" => %{
          "type" => "Comment",
          "content" => "A native BookWyrm comment",
          "id" => object_id,
          "attributedTo" => actor,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => ["#{actor}/followers"]
        },
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => ["#{actor}/followers"]
      }

      assert {:ok, job} = Federator.incoming_ap_doc(create)
      assert {:ok, _activity} = ObanHelpers.perform(job)
      assert Object.get_by_ap_id(object_id).data["type"] == "Comment"

      delete = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "actor" => actor,
        "type" => "Delete",
        "id" => activity_id,
        "object" => %{"type" => "Tombstone", "id" => object_id},
        "to" => ["#{actor}/followers"],
        "cc" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:ok, job} = Federator.incoming_ap_doc(delete)
      assert {:ok, delete_activity} = ObanHelpers.perform(job)

      assert delete_activity.data["id"] == activity_id <> "#unfathomably-delete"
      assert delete_activity.data["type"] == "Delete"

      tombstone = Object.get_by_ap_id(object_id)
      assert tombstone.data["type"] == "Tombstone"
      assert tombstone.data["formerType"] == "Comment"
    end

    test "rejects incoming AP docs with incorrect origin" do
      params = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "actor" => "https://niu.moe/users/rye",
        "type" => "Create",
        "id" => "http://mastodon.example.org/users/admin/activities/1",
        "object" => %{
          "type" => "Note",
          "content" => "hi world!",
          "id" => "http://mastodon.example.org/users/admin/objects/1",
          "attributedTo" => "http://mastodon.example.org/users/admin",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        },
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:ok, job} = Federator.incoming_ap_doc(params)
      assert {:cancel, :origin_containment_failed} = ObanHelpers.perform(job)
    end

    test "it does not crash if MRF rejects the post" do
      clear_config([:mrf_keyword, :reject], ["lain"])

      clear_config(
        [:mrf, :policies],
        Pleroma.Web.ActivityPub.MRF.KeywordPolicy
      )

      params =
        File.read!("test/fixtures/mastodon-post-activity.json")
        |> Jason.decode!()

      assert {:ok, job} = Federator.incoming_ap_doc(params)
      assert {:cancel, _} = ObanHelpers.perform(job)
    end
  end
end
