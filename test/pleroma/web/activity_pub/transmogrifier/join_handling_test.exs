# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.JoinHandlingTest do
  use Pleroma.DataCase

  alias Pleroma.Activity
  alias Pleroma.FollowingRelationship
  alias Pleroma.GroupMembership
  alias Pleroma.Notification
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.FederatedTarget

  import Pleroma.Factory
  import Ecto.Query

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "handle_incoming" do
    test "it works for incoming Mobilizon joins" do
      user = insert(:user)

      event = insert(:event)

      join_data =
        File.read!("test/fixtures/tesla_mock/mobilizon-event-join.json")
        |> Jason.decode!()
        |> Map.put("actor", user.ap_id)
        |> Map.put("object", event.data["id"])

      {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(join_data)

      event = Object.get_by_id(event.id)

      assert event.data["participations"] == [join_data["actor"]]

      activity = Repo.get(Activity, activity.id)
      assert activity.data["state"] == "accept"
    end

    test "with restricted events, it does create a Join, but not an Accept" do
      [participant, event_author] = insert_pair(:user)

      event = insert(:event, %{user: event_author, data: %{"joinMode" => "restricted"}})

      join_data =
        File.read!("test/fixtures/tesla_mock/mobilizon-event-join.json")
        |> Jason.decode!()
        |> Map.put("actor", participant.ap_id)
        |> Map.put("object", event.data["id"])

      {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(join_data)

      event = Object.get_by_id(event.id)

      assert event.data["participations"] == nil

      assert data["state"] == "pending"

      accepts =
        from(
          a in Activity,
          where: fragment("?->>'type' = ?", a.data, "Accept")
        )
        |> Repo.all()

      assert Enum.empty?(accepts)

      [notification] = Notification.for_user(event_author)
      assert notification.type == "pleroma:participation_request"
    end

    test "it accepts incoming joins for open local groups" do
      clear_config([:instance, :external_user_synchronization], true)

      owner = insert(:user)

      remote_user =
        insert(:user,
          local: false,
          ap_id: "https://narwhal.city/users/71",
          following_address: "https://narwhal.city/users/71/following",
          following_count: 9
        )

      {:ok, group} =
        FederatedTarget.create_local_group(owner, %{
          "display_name" => "Federation Audit",
          "name" => "federation_audit",
          "group_visibility" => "everyone"
        })

      join_data = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://narwhal.city/communities/4917/followers/71/join",
        "type" => "Join",
        "actor" => remote_user.ap_id,
        "object" => group.ap_id,
        "to" => [group.ap_id],
        "cc" => []
      }

      {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(join_data)
      activity = Repo.get(Activity, activity.id)

      assert activity.data["state"] == "accept"
      assert %GroupMembership{state: "active"} = GroupMembership.get(group, remote_user)
      assert FollowingRelationship.following?(remote_user, group)
      assert Pleroma.User.get_cached_by_id(remote_user.id).following_count == 9

      assert Repo.exists?(
               from(a in Activity,
                 where: fragment("?->>'type' = ?", a.data, "Accept"),
                 where: fragment("?->>'object' = ?", a.data, ^activity.data["id"])
               )
             )
    end

    test "it leaves incoming joins for closed local groups pending" do
      owner = insert(:user)
      remote_user = insert(:user, local: false, ap_id: "https://narwhal.city/users/72")

      {:ok, group} =
        FederatedTarget.create_local_group(owner, %{
          "display_name" => "Closed Federation Audit",
          "name" => "closed_federation_audit",
          "group_visibility" => "members_only"
        })

      join_data = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://narwhal.city/communities/4917/followers/72/join",
        "type" => "Join",
        "actor" => remote_user.ap_id,
        "object" => group.ap_id,
        "to" => [group.ap_id],
        "cc" => []
      }

      {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(join_data)
      activity = Repo.get(Activity, activity.id)

      assert activity.data["state"] == "pending"
      assert %GroupMembership{state: "pending"} = GroupMembership.get(group, remote_user)
      refute FollowingRelationship.following?(remote_user, group)

      assert [notification] = Notification.for_user(owner)
      assert notification.type == "group_follow_request"
    end
  end
end
