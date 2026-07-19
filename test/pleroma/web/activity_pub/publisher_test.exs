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
  alias Pleroma.Instances.Instance
  alias Pleroma.Object
  alias Pleroma.User
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
    test "uses an object ID for Delete delivery to Ibis" do
      inbox = "https://ibis.example/inbox"
      parent = self()

      insert(:instance,
        host: "ibis.example",
        metadata: %Instance.Pleroma.Instances.Metadata{
          software_name: "ibis",
          software_version: "0.3.3"
        },
        metadata_updated_at: NaiveDateTime.utc_now()
      )

      mock(fn %{method: :post, url: ^inbox, body: body} ->
        send(parent, {:ibis_delete_body, Jason.decode!(body)})
        {:ok, %Tesla.Env{status: 200, body: "accepted"}}
      end)

      actor = insert(:user)
      object_id = "https://local.example/objects/deleted-note"

      json =
        Jason.encode!(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "actor" => actor.ap_id,
          "id" => "#{actor.ap_id}/activities/delete-note",
          "object" => %{
            "deleted" => "2026-07-18T00:00:00Z",
            "formerType" => "Note",
            "id" => object_id,
            "type" => "Tombstone"
          },
          "to" => ["https://ibis.example/"],
          "type" => "Delete"
        })

      assert {:ok, %{status: 200}} =
               Publisher.publish_one(%{inbox: inbox, json: json, actor: actor, id: 1})

      assert_receive {:ibis_delete_body, %{"object" => ^object_id, "type" => "Delete"}}
    end

    test "retries rejected legacy delivery with an RFC 9421 signature" do
      actor = insert(:user)
      inbox = "http://rfc9421.site/users/alice/inbox"
      parent = self()

      mock(fn %{method: :post, url: ^inbox, headers: headers} ->
        if Enum.any?(headers, fn {name, _value} ->
             String.downcase(to_string(name)) == "signature-input"
           end) do
          send(parent, {:rfc9421_headers, headers})
          {:ok, %Tesla.Env{status: 200, body: "accepted"}}
        else
          {:ok, %Tesla.Env{status: 401, body: "use RFC 9421"}}
        end
      end)

      assert {:ok, %{status: 200}} =
               Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: 1})

      assert_receive {:rfc9421_headers, headers}

      assert Enum.any?(headers, fn {name, value} ->
               String.downcase(to_string(name)) == "content-digest" and
                 String.starts_with?(value, "sha-256=:")
             end)
    end

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

    test_with_mock "records successful federation if `unreachable_since` is not specified",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://200.site/users/nick1/inbox"

      assert {:ok, _} = Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: 1})
      assert called(Instances.record_delivery_success(inbox, source: "publisher"))
    end

    test_with_mock "records successful federation if `unreachable_since` is set",
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

      assert called(Instances.record_delivery_success(inbox, source: "publisher"))
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

    test_with_mock "records a target inbox request error",
                   Instances,
                   [:passthrough],
                   [] do
      actor = insert(:user)
      inbox = "http://connrefused.site/users/nick1/inbox"

      assert capture_log(fn ->
               assert {:error, _} =
                        Publisher.publish_one(%{inbox: inbox, json: "{}", actor: actor, id: 1})
             end) =~ "connrefused"

      assert called(
               Instances.record_delivery_failure(
                 inbox,
                 {:error, :connrefused},
                 source: "publisher"
               )
             )
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
    test_with_mock "uses a prepared native resource audience for inbox selection",
                   Pleroma.Web.Federator.Publisher,
                   [:passthrough],
                   [] do
      resource_url = "https://manyfold.example/models/model-1"
      model_actor = "https://manyfold.example/federation/actors/model-1"
      creator_actor = "https://manyfold.example/federation/actors/creator-1"
      note_id = "https://manyfold.example/federation/published/comments/model-1"

      model =
        insert(:user,
          local: false,
          ap_id: model_actor,
          uri: resource_url,
          inbox: model_actor <> "/inbox",
          actor_type: "Service",
          actor_extensions: %{"f3di:concreteType" => "3DModel"}
        )

      creator =
        insert(:user,
          local: false,
          ap_id: creator_actor,
          inbox: creator_actor <> "/inbox"
        )

      insert(:note,
        user: creator,
        data: %{
          "id" => note_id,
          "actor" => creator_actor,
          "attributedTo" => creator_actor,
          "context" => resource_url,
          "url" => resource_url
        }
      )

      follower =
        insert(:user,
          local: false,
          inbox: "https://manyfold.example/federation/actors/follower/inbox"
        )

      actor = insert(:user)
      {:ok, _follower, actor} = User.follow(follower, actor)

      like = %Activity{
        actor: actor.ap_id,
        recipients: [creator_actor, actor.follower_address, @as_public],
        data: %{
          "id" => Pleroma.Web.ActivityPub.Utils.generate_activity_id(),
          "type" => "Like",
          "actor" => actor.ap_id,
          "object" => note_id,
          "to" => [creator_actor, actor.follower_address],
          "cc" => [@as_public]
        }
      }

      assert Publisher.publish(actor, like) == :ok

      assert called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{
                   inbox: model.inbox,
                   actor_id: actor.id,
                   id: like.data["id"]
                 },
                 :_
               )
             )

      refute called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{inbox: creator.inbox, actor_id: actor.id, id: like.data["id"]},
                 :_
               )
             )

      refute called(
               Pleroma.Web.Federator.Publisher.enqueue_one(
                 Publisher,
                 %{inbox: follower.inbox, actor_id: actor.id, id: like.data["id"]},
                 :_
               )
             )
    end

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
