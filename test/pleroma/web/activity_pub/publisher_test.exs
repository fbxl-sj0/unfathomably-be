# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.PublisherTest do
  use Pleroma.Web.ConnCase

  import ExUnit.CaptureLog
  import Pleroma.Factory
  import Tesla.Mock
  import Mock

  alias Pleroma.Activity
  alias Pleroma.Instances
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Publisher
  alias Pleroma.Web.CommonAPI

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    mock(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  setup_all do: clear_config([:instance, :federating], true)

  describe "should_federate?/2" do
    test "returns false when the inbox is nil" do
      refute Publisher.should_federate?(nil, false)
      refute Publisher.should_federate?(nil, true)
    end

    test "returns true when the activity is public" do
      assert Publisher.should_federate?(false, true)
    end

    test "returns false for malformed non-public inboxes" do
      refute Publisher.should_federate?(false, false)
      refute Publisher.should_federate?("https://%", false)
    end
  end

  describe "gather_webfinger_links/1" do
    test "it returns links" do
      user = insert(:user)

      expected_links = [
        %{"href" => user.ap_id, "rel" => "self", "type" => "application/activity+json"},
        %{
          "href" => user.ap_id,
          "rel" => "self",
          "type" => "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
        },
        %{
          "rel" => "http://ostatus.org/schema/1.0/subscribe",
          "template" => "#{Pleroma.Web.Endpoint.url()}/ostatus_subscribe?acct={uri}"
        }
      ]

      assert expected_links == Publisher.gather_webfinger_links(user)
    end
  end

  describe "determine_inbox/2" do
    test "it returns sharedInbox for messages involving as:Public in to" do
      user = insert(:user, %{shared_inbox: "http://example.com/inbox"})

      activity = %Activity{
        data: %{"to" => [@as_public], "cc" => [user.follower_address]}
      }

      assert Publisher.determine_inbox(activity, user) == "http://example.com/inbox"
    end

    test "it returns sharedInbox for messages involving as:Public in cc" do
      user = insert(:user, %{shared_inbox: "http://example.com/inbox"})

      activity = %Activity{
        data: %{"cc" => [@as_public], "to" => [user.follower_address]}
      }

      assert Publisher.determine_inbox(activity, user) == "http://example.com/inbox"
    end

    test "it returns sharedInbox for messages involving multiple recipients in to" do
      user = insert(:user, %{shared_inbox: "http://example.com/inbox"})
      user_two = insert(:user)
      user_three = insert(:user)

      activity = %Activity{
        data: %{"cc" => [], "to" => [user.ap_id, user_two.ap_id, user_three.ap_id]}
      }

      assert Publisher.determine_inbox(activity, user) == "http://example.com/inbox"
    end

    test "it returns sharedInbox for messages involving multiple recipients in cc" do
      user = insert(:user, %{shared_inbox: "http://example.com/inbox"})
      user_two = insert(:user)
      user_three = insert(:user)

      activity = %Activity{
        data: %{"to" => [], "cc" => [user.ap_id, user_two.ap_id, user_three.ap_id]}
      }

      assert Publisher.determine_inbox(activity, user) == "http://example.com/inbox"
    end

    test "it returns sharedInbox for messages involving multiple recipients in total" do
      user =
        insert(:user, %{
          shared_inbox: "http://example.com/inbox",
          inbox: "http://example.com/personal-inbox"
        })

      user_two = insert(:user)

      activity = %Activity{
        data: %{"to" => [user_two.ap_id], "cc" => [user.ap_id]}
      }

      assert Publisher.determine_inbox(activity, user) == "http://example.com/inbox"
    end

    test "it returns inbox for messages involving single recipients in total" do
      user =
        insert(:user, %{
          shared_inbox: "http://example.com/inbox",
          inbox: "http://example.com/personal-inbox"
        })

      activity = %Activity{
        data: %{"to" => [user.ap_id], "cc" => []}
      }

      assert Publisher.determine_inbox(activity, user) == "http://example.com/personal-inbox"
    end
  end

  describe "publish_one/1" do
    test "publish to url with with different ports" do
      inbox80 = "http://42.site/users/nick1/inbox"
      inbox42 = "http://42.site:42/users/nick1/inbox"

      mock(fn
        %{method: :post, url: "http://42.site:42/users/nick1/inbox"} ->
          {:ok, %Tesla.Env{status: 200, body: "port 42"}}

        %{method: :post, url: "http://42.site/users/nick1/inbox"} ->
          {:ok, %Tesla.Env{status: 200, body: "port 80"}}
      end)

      actor = insert(:user)

      assert {:ok, %{body: "port 42"}} =
               Publisher.publish_one(%{
                 inbox: inbox42,
                 json: "{}",
                 actor: actor,
                 id: 1,
                 unreachable_since: true
               })

      assert {:ok, %{body: "port 80"}} =
               Publisher.publish_one(%{
                 inbox: inbox80,
                 json: "{}",
                 actor: actor,
                 id: 1,
                 unreachable_since: true
               })
    end

    test_with_mock "calls `Instances.set_reachable` on successful federation if `unreachable_since` is not specified",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://200.site/users/nick1/inbox"

      assert {:ok, _} = Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: 1})
      assert called(Instances.set_reachable(inbox))
    end

    test_with_mock "calls `Instances.set_reachable` on successful federation if `unreachable_since` is set",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://200.site/users/nick1/inbox"

      assert {:ok, _} =
               Publisher.publish_one(%{
                 inbox: inbox,
                 json: "{}",
                 actor: actor,
                 id: 1,
                 unreachable_since: NaiveDateTime.utc_now()
               })

      assert called(Instances.set_reachable(inbox))
    end

    test_with_mock "does NOT call `Instances.set_reachable` on successful federation if `unreachable_since` is nil",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://200.site/users/nick1/inbox"

      assert {:ok, _} =
               Publisher.publish_one(%{
                 inbox: inbox,
                 json: "{}",
                 actor: actor,
                 id: 1,
                 unreachable_since: nil
               })

      refute called(Instances.set_reachable(inbox))
    end

    test_with_mock "does NOT call `Instances.set_unreachable` on terminal delivery response codes",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://terminal-400.site/users/nick1/inbox"

      mock(fn
        %{method: :post, url: ^inbox} ->
          {:ok, %Tesla.Env{status: 400, body: "terminal"}}
      end)

      assert capture_log(fn ->
               assert {:cancel, :bad_request} =
                        Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: 1})
             end) =~ "400"

      refute called(Instances.set_unreachable(inbox))
    end

    test "cancels terminal delivery responses instead of retrying them" do
      actor = insert(:user)

      terminal_responses = [
        {400, :bad_request},
        {403, :forbidden},
        {404, :not_found},
        {405, :method_not_allowed},
        {406, :not_acceptable},
        {410, :gone},
        {501, :not_implemented}
      ]

      Enum.each(terminal_responses, fn {status, reason} ->
        inbox = "http://terminal-#{status}.site/users/nick1/inbox"

        mock(fn
          %{method: :post, url: ^inbox} ->
            {:ok, %Tesla.Env{status: status, body: "terminal"}}
        end)

        assert {:cancel, ^reason} =
                 Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: status})
      end)
    end

    test "cancels malformed inboxes instead of retrying them" do
      actor = insert(:user)

      assert {:cancel, :bad_request} =
               Publisher.publish_one(%{
                 inbox: "https://%",
                 json: "{}",
                 actor: actor,
                 id: "https://local.example/activities/malformed-inbox"
               })
    end

    test "cancels malformed delivery params instead of retrying them" do
      actor = insert(:user)

      assert {:cancel, :bad_request} =
               Publisher.publish_one(%{
                 inbox: "https://remote.example/inbox",
                 json: %{"not" => "encoded"},
                 actor: actor,
                 id: "https://local.example/activities/malformed-json"
               })

      assert {:cancel, :bad_request} =
               Publisher.publish_one(%{
                 inbox: "https://remote.example/inbox",
                 json: "{}",
                 actor: nil,
                 id: "https://local.example/activities/missing-actor"
               })

      assert {:cancel, :bad_request} =
               Publisher.publish_one(%{
                 inbox: "https://remote.example/inbox",
                 json: "{}"
               })
    end

    test "keeps retrying non-terminal delivery responses" do
      actor = insert(:user)
      inbox = "http://temporary-failure.site/users/nick1/inbox"

      mock(fn
        %{method: :post, url: ^inbox} ->
          {:ok, %Tesla.Env{status: 502, body: "temporary"}}
      end)

      assert {:error, %Tesla.Env{status: 502}} =
               Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: 502})
    end

    test_with_mock "marks the target unreachable on non-terminal delivery response codes",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://temporary-failure.site/users/nick1/inbox"

      mock(fn
        %{method: :post, url: ^inbox} ->
          {:ok, %Tesla.Env{status: 502, body: "temporary"}}
      end)

      assert {:error, %Tesla.Env{status: 502}} =
               Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: 502})

      assert called(Instances.set_unreachable(inbox))
    end

    test_with_mock "it calls `Instances.set_unreachable` on target inbox on request error of any kind",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://connrefused.site/users/nick1/inbox"

      assert capture_log(fn ->
               assert {:error, _} =
                        Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: 1})
             end) =~ "connrefused"

      assert called(Instances.set_unreachable(inbox))
    end

    test_with_mock "does NOT call `Instances.set_unreachable` if target is reachable",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://200.site/users/nick1/inbox"

      assert {:ok, _} = Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: 1})

      refute called(Instances.set_unreachable(inbox))
    end

    test_with_mock "cancels request errors for already unreachable target instances",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://connrefused.site/users/nick1/inbox"

      assert capture_log(fn ->
               assert {:cancel, :unreachable_host} =
                        Publisher.publish_one(%{
                          inbox: inbox,
                          json: "{}",
                          actor: actor,
                          id: 1,
                          unreachable_since: NaiveDateTime.utc_now()
                        })
             end) =~ "connrefused"

      refute called(Instances.set_unreachable(inbox))
    end
  end

  describe "publish/2" do
    test_with_mock "doesn't publish a non-public activity to quarantined instances.",
                   Pleroma.Web.Federator.Publisher,
                   [:passthrough],
                   [] do
      Config.put([:instance, :quarantined_instances], [{"domain.com", "some reason"}])

      follower =
        insert(:user, %{
          local: false,
          inbox: "https://domain.com/users/nick1/inbox"
        })

      actor = insert(:user, follower_address: follower.ap_id)

      {:ok, follower, actor} = Pleroma.User.follow(follower, actor)
      actor = refresh_record(actor)

      note_activity =
        insert(:followers_only_note_activity,
          user: actor,
          recipients: [follower.ap_id]
        )

      res = Publisher.publish(actor, note_activity)

      assert res == :ok

      assert not called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{
                   inbox: "https://domain.com/users/nick1/inbox",
                   actor_id: actor.id,
                   id: note_activity.data["id"]
                 },
                 :_
               )
             )
    end

    test_with_mock "Publishes a non-public activity to non-quarantined instances.",
                   Pleroma.Web.Federator.Publisher,
                   [:passthrough],
                   [] do
      Config.put([:instance, :quarantined_instances], [{"somedomain.com", "some reason"}])

      follower =
        insert(:user, %{
          local: false,
          inbox: "https://domain.com/users/nick1/inbox"
        })

      actor = insert(:user, follower_address: follower.ap_id)

      {:ok, follower, actor} = Pleroma.User.follow(follower, actor)
      actor = refresh_record(actor)

      note_activity =
        insert(:followers_only_note_activity,
          user: actor,
          recipients: [follower.ap_id]
        )

      res = Publisher.publish(actor, note_activity)

      assert res == :ok

      assert called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{
                   inbox: "https://domain.com/users/nick1/inbox",
                   actor_id: actor.id,
                   id: note_activity.data["id"]
                 },
                 :_
               )
             )
    end

    test_with_mock "publishes an activity with BCC to all relevant peers.",
                   Pleroma.Web.Federator.Publisher,
                   [:passthrough],
                   [] do
      follower =
        insert(:user, %{
          local: false,
          inbox: "https://domain.com/users/nick1/inbox"
        })

      actor = insert(:user, follower_address: follower.ap_id)
      user = insert(:user)

      {:ok, follower, actor} = Pleroma.User.follow(follower, actor)

      note_activity =
        insert(:note_activity,
          user: actor,
          recipients: [follower.ap_id],
          data_attrs: %{"bcc" => [user.ap_id]}
        )

      res = Publisher.publish(actor, note_activity)
      assert res == :ok

      assert called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{
                   inbox: "https://domain.com/users/nick1/inbox",
                   actor_id: actor.id,
                   id: note_activity.data["id"]
                 },
                 :_
               )
             )
    end

    test_with_mock "does not publish group announces back to the announced object's origin host",
                   Pleroma.Web.Federator.Publisher,
                   [:passthrough],
                   [] do
      origin_author =
        insert(:user,
          local: false,
          domain: "lemmy.example",
          inbox: "https://lemmy.example/u/poster/inbox",
          shared_inbox: "https://lemmy.example/inbox"
        )

      same_origin_follower =
        insert(:user,
          local: false,
          domain: "lemmy.example",
          inbox: "https://lemmy.example/u/reader/inbox",
          shared_inbox: "https://lemmy.example/inbox"
        )

      other_follower =
        insert(:user,
          local: false,
          domain: "other.example",
          inbox: "https://other.example/u/reader/inbox",
          shared_inbox: "https://other.example/inbox"
        )

      group = insert(:user, actor_type: "Group")
      caller = insert(:user)

      {:ok, _, group} = Pleroma.User.follow(origin_author, group)
      {:ok, _, group} = Pleroma.User.follow(same_origin_follower, group)
      {:ok, _, group} = Pleroma.User.follow(other_follower, group)

      note =
        insert(:note,
          user: origin_author,
          data: %{"id" => "https://lemmy.example/post/1"}
        )

      announce = %Activity{
        actor: group.ap_id,
        recipients: [@as_public, group.follower_address],
        data: %{
          "id" => Pleroma.Web.ActivityPub.Utils.generate_activity_id(),
          "type" => "Announce",
          "actor" => group.ap_id,
          "object" => note.data["id"],
          "to" => [@as_public],
          "cc" => [group.follower_address],
          "context" => note.data["context"]
        }
      }

      assert Publisher.publish(caller, announce) == :ok

      assert called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{
                   inbox: "https://other.example/inbox",
                   actor_id: group.id,
                   id: announce.data["id"]
                 },
                 :_
               )
             )

      refute called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{
                   inbox: "https://lemmy.example/inbox",
                   actor_id: group.id,
                   id: announce.data["id"]
                 },
                 :_
               )
             )
    end

    test_with_mock "publishes a delete activity to peers who signed fetch requests to the create acitvity/object.",
                   Pleroma.Web.Federator.Publisher,
                   [:passthrough],
                   [] do
      fetcher =
        insert(:user,
          local: false,
          inbox: "https://domain.com/users/nick1/inbox"
        )

      another_fetcher =
        insert(:user,
          local: false,
          inbox: "https://domain2.com/users/nick1/inbox"
        )

      actor = insert(:user)

      note_activity = insert(:note_activity, user: actor)
      object = Object.normalize(note_activity, fetch: false)

      activity_path = String.trim_leading(note_activity.data["id"], Pleroma.Web.Endpoint.url())
      object_path = String.trim_leading(object.data["id"], Pleroma.Web.Endpoint.url())

      build_conn()
      |> put_req_header("accept", "application/activity+json")
      |> assign(:user, fetcher)
      |> get(object_path)
      |> json_response(200)

      build_conn()
      |> put_req_header("accept", "application/activity+json")
      |> assign(:user, another_fetcher)
      |> get(activity_path)
      |> json_response(200)

      {:ok, delete} = CommonAPI.delete(note_activity.id, actor)

      res = Publisher.publish(actor, delete)
      assert res == :ok

      assert called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{
                   inbox: "https://domain.com/users/nick1/inbox",
                   actor_id: actor.id,
                   id: delete.data["id"]
                 },
                 :_
               )
             )

      assert called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{
                   inbox: "https://domain2.com/users/nick1/inbox",
                   actor_id: actor.id,
                   id: delete.data["id"]
                 },
                 :_
               )
             )
    end
  end
end
