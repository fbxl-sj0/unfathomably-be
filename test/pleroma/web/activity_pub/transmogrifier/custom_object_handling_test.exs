# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.CustomObjectHandlingTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.MastodonAPI.StatusView

  import Pleroma.Factory

  require Pleroma.Constants

  setup do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://bookwyrm.example/user/alice",
        follower_address: "https://bookwyrm.example/user/alice/followers"
      )

    %{actor: actor}
  end

  test "ingests, stores, and exports a native Review without losing vocabulary", %{actor: actor} do
    activity = create_review(actor)

    assert {:ok, %Activity{} = stored_activity} = Transmogrifier.handle_incoming(activity)
    assert %Object{} = object = Object.get_by_ap_id(activity["object"]["id"])

    assert object.data["type"] == "Review"
    assert object.data["rating"] == 4.5
    assert object.data["inReplyToBook"] == "https://bookwyrm.example/book/1"
    assert object.data["bookwyrm:edition"]["isbn13"] == "9780123456789"
    assert object.data[CustomObject.internal_field()]["class"] == "status"

    exported = Transmogrifier.prepare_object(object.data)

    assert exported["type"] == "Review"
    assert exported["rating"] == 4.5
    assert exported["bookwyrm:edition"] == object.data["bookwyrm:edition"]
    refute Map.has_key?(exported, CustomObject.internal_field())

    rendered = StatusView.render("show.json", activity: stored_activity)

    assert %{
             canonical_id: "https://bookwyrm.example/user/alice/status/1",
             class: "status",
             context: "https://bookwyrm.example/user/alice/status/1",
             controls: ["open"],
             fields: %{
               in_reply_to_book: "https://bookwyrm.example/book/1",
               rating: 4.5
             },
             type: "Review"
           } = rendered.pleroma.native

    assert {:ok, ^stored_activity} = Transmogrifier.handle_incoming(activity)

    assert 1 ==
             Activity.Queries.by_object_id(Activity, object.data["id"])
             |> Pleroma.Repo.aggregate(:count)
  end

  test "dereferences a same-origin linked ActivityPods Create exactly once" do
    recipient = insert(:user)

    actor =
      insert(:user,
        local: false,
        ap_id: "https://activitypods.example/alice",
        follower_address: "https://activitypods.example/alice/followers"
      )

    object_id = "https://activitypods.example/alice/data/project-1"

    project = %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        %{"pair" => "http://virtual-assembly.org/ontologies/pair#"}
      ],
      "attributedTo" => actor.ap_id,
      "cc" => "as:Public",
      "content" => "Native ActivityPods coordination state",
      "id" => object_id,
      "pair:description" => "Native ActivityPods coordination state",
      "pair:label" => "Alien federation project",
      "to" => recipient.ap_id,
      "type" => "pair:Project"
    }

    Tesla.Mock.mock(fn %{method: :get, url: ^object_id} ->
      %Tesla.Env{
        status: 200,
        body: Jason.encode!(project),
        headers: HttpRequestMock.activitypub_object_headers()
      }
    end)

    create = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "actor" => actor.ap_id,
      "cc" => project["cc"],
      "id" => "https://activitypods.example/alice/data/create-project-1",
      "object" => object_id,
      "to" => project["to"],
      "type" => "Create"
    }

    assert {:ok, %Activity{} = activity} = Transmogrifier.handle_incoming(create)
    stored_project = Object.get_by_ap_id(object_id).data
    assert stored_project["pair:label"] == "Alien federation project"
    assert stored_project["to"] == [recipient.ap_id]
    assert stored_project["cc"] == [Pleroma.Constants.as_public()]

    assert %{
             class: "status",
             fields: %{
               platform: "activitypods",
               project_description: "Native ActivityPods coordination state",
               project_label: "Alien federation project"
             },
             type: "pair:Project"
           } = StatusView.render("show.json", activity: activity).pleroma.native

    Tesla.Mock.mock(fn _env ->
      flunk("a linked Create redelivery attempted another network fetch")
    end)

    assert {:ok, ^activity} = Transmogrifier.handle_incoming(create)

    updated_project =
      project
      |> Map.put("content", "Updated ActivityPods coordination state")
      |> Map.put("pair:description", "Updated ActivityPods coordination state")

    Tesla.Mock.mock(fn %{method: :get, url: ^object_id} ->
      %Tesla.Env{
        status: 200,
        body: Jason.encode!(updated_project),
        headers: HttpRequestMock.activitypub_object_headers()
      }
    end)

    update = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "actor" => actor.ap_id,
      "cc" => updated_project["cc"],
      "id" => "https://activitypods.example/alice/data/update-project-1",
      "object" => object_id,
      "to" => updated_project["to"],
      "type" => "Update"
    }

    assert {:ok, %Activity{} = update_activity} = Transmogrifier.handle_incoming(update)
    assert Object.get_by_ap_id(object_id).data["content"] == updated_project["content"]
    assert Object.get_by_ap_id(object_id).data["cc"] == [Pleroma.Constants.as_public()]

    Tesla.Mock.mock(fn _env ->
      flunk("a linked Update redelivery attempted another network fetch")
    end)

    assert {:ok, ^update_activity} = Transmogrifier.handle_incoming(update)
  end

  test "does not dereference a linked Create outside the actor authority" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://activitypods.example/alice",
        follower_address: "https://activitypods.example/alice/followers"
      )

    Tesla.Mock.mock(fn _env ->
      flunk("an unauthorized linked Create attempted a network fetch")
    end)

    create = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "actor" => actor.ap_id,
      "cc" => [],
      "id" => "https://activitypods.example/alice/data/create-project-2",
      "object" => "https://unrelated.example/projects/1",
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Create"
    }

    assert :error = Transmogrifier.handle_incoming(create)
  end

  test "presents compact and expanded Mutual Aid listings with marketplace metadata" do
    offer = %{
      "id" => "https://pods.example/alice/data/maid/offer/drill",
      "type" => "maid:Offer",
      "pair:label" => "Cordless drill",
      "maid:offerOfResourceType" => "https://mutual-aid.example/types/tool"
    }

    request = %{
      "id" => "https://pods.example/alice/data/maid/request/ride",
      "type" => "https://mutual-aid.app/ns/core#Request",
      "http://virtual-assembly.org/ontologies/pair#label" => "Ride to the clinic",
      "https://mutual-aid.app/ns/core#requestOfResourceType" =>
        "https://mutual-aid.example/types/transport"
    }

    assert %{
             fields: %{
               listing_kind: "offer",
               listing_label: "Cordless drill",
               platform: "mutual_aid",
               resource_type: "https://mutual-aid.example/types/tool"
             }
           } = CustomObject.presentation(offer)

    assert %{
             fields: %{
               listing_kind: "request",
               listing_label: "Ride to the clinic",
               platform: "mutual_aid",
               resource_type: "https://mutual-aid.example/types/transport"
             }
           } = CustomObject.presentation(request)
  end

  test "stores an actorless Edition as a resource rather than a status" do
    edition = %{
      "id" => "https://bookwyrm.example/book/edition/1",
      "type" => "Edition",
      "title" => "A federated book",
      "work" => "https://bookwyrm.example/book/work/1",
      "isbn13" => "9780123456789",
      "bookwyrm:unknownField" => %{"preserved" => true}
    }

    assert {:ok, %Object{} = object, _meta} =
             Pipeline.common_pipeline(edition,
               local: false,
               fetched_from: edition["id"],
               do_not_federate: true
             )

    assert object.data["bookwyrm:unknownField"] == %{"preserved" => true}
    assert object.data[CustomObject.internal_field()]["class"] == "resource"
    assert Activity.get_create_by_object_ap_id(edition["id"]) == nil
  end

  test "stores and presents a Bonfire ValueFlows EconomicEvent without fetching links" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://bonfire.example/pub/actors/alice",
        follower_address: "https://bonfire.example/pub/actors/alice/followers"
      )

    event = %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        %{"ValueFlows" => "https://w3id.org/valueflows#"}
      ],
      "action" => "https://w3id.org/valueflows#transfer",
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "hasPointInTime" => "2026-07-18T12:00:00Z",
      "id" => "https://bonfire.example/pub/objects/economic-event-1",
      "provider" => %{"id" => actor.ap_id, "type" => "Person"},
      "receiver" => "https://remote.invalid/actors/receiver",
      "resourceInventoriedAs" => %{
        "id" => "https://inventory.invalid/resources/radio",
        "name" => "Alien federation radio",
        "type" => "ValueFlows:EconomicResource"
      },
      "resourceQuantity" => %{
        "hasNumericalValue" => 3,
        "hasUnit" => "https://units.invalid/items/radio",
        "type" => "om2:Measure"
      },
      "summary" => "Three radios transferred between federated agents.",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor.follower_address],
      "type" => "ValueFlows:EconomicEvent",
      "valueflows:unknown" => %{
        "id" => "https://linked.invalid/objects/unknown",
        "preserved" => true
      }
    }

    create = %{
      "id" => "https://bonfire.example/pub/activities/economic-event-1",
      "type" => "Create",
      "actor" => actor.ap_id,
      "to" => event["to"],
      "cc" => event["cc"],
      "object" => event
    }

    assert {:ok, %Activity{} = stored_activity} = Transmogrifier.handle_incoming(create)
    assert %Object{} = object = Object.get_by_ap_id(event["id"])
    assert object.data["valueflows:unknown"] == event["valueflows:unknown"]
    assert object.data[CustomObject.internal_field()]["class"] == "status"

    rendered = StatusView.render("show.json", activity: stored_activity)

    assert %{
             class: "status",
             fields: %{
               action: "transfer",
               has_point_in_time: "2026-07-18T12:00:00Z",
               platform: "bonfire_valueflows",
               provider: "https://bonfire.example/pub/actors/alice",
               receiver: "https://remote.invalid/actors/receiver",
               resource_inventoried_as: "https://inventory.invalid/resources/radio",
               resource_quantity: 3,
               resource_quantity_unit: "https://units.invalid/items/radio",
               valueflows_type: "EconomicEvent"
             },
             type: "ValueFlows:EconomicEvent"
           } = rendered.pleroma.native
  end

  test "keeps a ValueFlows EconomicResource off the status timeline" do
    resource = %{
      "id" => "https://bonfire.example/pub/objects/resource-1",
      "type" => "ValueFlows:EconomicResource",
      "attributedTo" => "https://bonfire.example/pub/actors/alice",
      "name" => "Alien federation radio",
      "trackingIdentifier" => "radio-1"
    }

    assert {:ok, %Object{} = object, _meta} =
             Pipeline.common_pipeline(resource,
               local: false,
               fetched_from: resource["id"],
               do_not_federate: true
             )

    assert object.data[CustomObject.internal_field()]["class"] == "resource"
    assert Activity.get_create_by_object_ap_id(resource["id"]) == nil

    assert %{
             class: "resource",
             fields: %{
               platform: "bonfire_valueflows",
               tracking_identifier: "radio-1",
               valueflows_type: "EconomicResource"
             }
           } = CustomObject.presentation(object.data)
  end

  test "handles a real BookWyrm Review shape that uses attributedTo", %{actor: actor} do
    create = fixture("bookwyrm-review-create.json")
    object_id = create["object"]["id"]

    refute Map.has_key?(create["object"], "actor")
    assert {:ok, %Activity{}} = Transmogrifier.handle_incoming(create)

    review = Object.get_by_ap_id(object_id)
    assert review.data["type"] == "Review"
    assert review.data["attributedTo"] == actor.ap_id
    assert review.data["inReplyToBook"] == "https://bookwyrm.example/book/edition/1"
    assert review.data["readingStatus"] == "read"
    assert review.data["rating"] == 5

    assert {:ok, %Activity{}} =
             object_id
             |> delete_object(actor, "attributed-to-review")
             |> Transmogrifier.handle_incoming()

    assert Object.get_by_ap_id(object_id).data["formerType"] == "Review"
  end

  test "upgrades a BookWyrm compatibility Article to one native Review" do
    fallback = fixture("bookwyrm-review-article-fallback.json")
    native = fixture("bookwyrm-review-create.json")
    object_id = native["object"]["id"]

    assert fallback["id"] == native["id"]
    assert {:ok, %Activity{} = create_activity} = Transmogrifier.handle_incoming(fallback)
    assert Object.get_by_ap_id(object_id).data["type"] == "Article"

    assert {:ok, ^create_activity} = Transmogrifier.handle_incoming(native)

    upgraded = Object.get_by_ap_id(object_id)
    assert upgraded.data["type"] == "Review"
    assert upgraded.data["rating"] == 5
    assert upgraded.data["inReplyToBook"] == native["object"]["inReplyToBook"]
    assert upgraded.data[CustomObject.internal_field()]["class"] == "status"

    assert 1 ==
             Activity.Queries.by_object_id(Activity, object_id)
             |> Pleroma.Repo.aggregate(:count)
  end

  test "does not downgrade a native BookWyrm Review when its fallback arrives" do
    native = fixture("bookwyrm-review-create.json")
    fallback = fixture("bookwyrm-review-article-fallback.json")
    object_id = native["object"]["id"]

    assert {:ok, %Activity{} = create_activity} = Transmogrifier.handle_incoming(native)
    assert {:ok, ^create_activity} = Transmogrifier.handle_incoming(fallback)

    stored = Object.get_by_ap_id(object_id)
    assert stored.data["type"] == "Review"
    assert stored.data["rating"] == 5
  end

  test "applies only newer Updates from the exact Review authority", %{actor: actor} do
    create = create_review(actor)
    object_id = create["object"]["id"]

    assert {:ok, %Activity{}} = Transmogrifier.handle_incoming(create)
    assert Object.get_cached_by_ap_id(object_id).data["content"] == create["object"]["content"]

    same_domain_actor =
      insert(:user,
        local: false,
        ap_id: "https://bookwyrm.example/user/mallory",
        follower_address: "https://bookwyrm.example/user/mallory/followers"
      )

    unauthorized_object =
      create["object"]
      |> Map.put("updated", "2026-07-17T12:30:00Z")
      |> Map.put("content", "A same-domain actor tried to replace this review.")

    assert {:error, _reason} =
             unauthorized_object
             |> update_review(same_domain_actor, "unauthorized")
             |> Transmogrifier.handle_incoming()

    assert Object.get_by_ap_id(object_id).data["content"] == create["object"]["content"]

    newer_object =
      create["object"]
      |> Map.drop(["bookwyrm:edition"])
      |> Map.merge(%{
        "content" => "The corrected native BookWyrm review.",
        "rating" => 5.0,
        "updated" => "2026-07-17T13:00:00Z",
        "bookwyrm:seriesPosition" => 2
      })

    assert {:ok, %Activity{}} =
             newer_object
             |> update_review(actor, "newer")
             |> Transmogrifier.handle_incoming()

    updated = Object.get_by_ap_id(object_id)
    assert updated.data["content"] == "The corrected native BookWyrm review."
    assert updated.data["rating"] == 5.0
    assert updated.data["bookwyrm:seriesPosition"] == 2
    assert updated.data["bookwyrm:edition"] == create["object"]["bookwyrm:edition"]

    equal_object =
      newer_object
      |> Map.put("content", "An equal timestamp must not win.")
      |> Map.put("rating", 1.0)

    assert {:ok, %Activity{}} =
             equal_object
             |> update_review(actor, "equal")
             |> Transmogrifier.handle_incoming()

    older_object =
      newer_object
      |> Map.put("updated", "2026-07-17T12:45:00Z")
      |> Map.put("content", "A delayed older Update must not win.")
      |> Map.put("rating", 2.0)

    assert {:ok, %Activity{}} =
             older_object
             |> update_review(actor, "older")
             |> Transmogrifier.handle_incoming()

    unchanged = Object.get_by_ap_id(object_id)
    assert unchanged.data["content"] == "The corrected native BookWyrm review."
    assert unchanged.data["rating"] == 5.0
    assert unchanged.data["updated"] == "2026-07-17T13:00:00Z"
  end

  test "applies one newly persisted timestamp-less Update with stable publication identity", %{
    actor: actor
  } do
    create = create_review(actor)
    object_id = create["object"]["id"]

    assert {:ok, %Activity{} = create_activity} = Transmogrifier.handle_incoming(create)
    assert Object.get_cached_by_ap_id(object_id).data["content"] == create["object"]["content"]

    create_activity = Activity.get_by_id_with_object(create_activity.id)
    initial_status = StatusView.render("show.json", activity: create_activity)
    assert initial_status.content =~ create["object"]["content"]

    update =
      create["object"]
      |> Map.put("content", "BookWyrm changed this review without a revision timestamp.")
      |> update_review(actor, "untimestamped")

    assert {:ok, %Activity{} = update_activity} = Transmogrifier.handle_incoming(update)

    assert Object.get_cached_by_ap_id(object_id).data["content"] =~
             "without a revision timestamp"

    create_activity = Activity.get_by_id_with_object(create_activity.id)
    updated_status = StatusView.render("show.json", activity: create_activity)
    assert updated_status.content =~ "without a revision timestamp"

    assert {:ok, ^update_activity} = Transmogrifier.handle_incoming(update)
    assert Object.get_by_ap_id(object_id).data["content"] =~ "without a revision timestamp"
  end

  test "requires exact authority for Delete and makes repeated Deletes safe", %{actor: actor} do
    create = create_review(actor)
    object_id = create["object"]["id"]

    assert {:ok, %Activity{}} = Transmogrifier.handle_incoming(create)

    same_domain_actor =
      insert(:user,
        local: false,
        ap_id: "https://bookwyrm.example/user/mallory",
        follower_address: "https://bookwyrm.example/user/mallory/followers"
      )

    assert {:error, _reason} =
             object_id
             |> delete_object(same_domain_actor, "unauthorized")
             |> Transmogrifier.handle_incoming()

    assert Object.get_by_ap_id(object_id).data["type"] == "Review"

    delete = delete_object(object_id, actor, "authorized")
    assert {:ok, %Activity{} = stored_delete} = Transmogrifier.handle_incoming(delete)

    tombstone = Object.get_by_ap_id(object_id)
    assert tombstone.data["type"] == "Tombstone"
    assert tombstone.data["formerType"] == "Review"

    assert {:ok, ^stored_delete} = Transmogrifier.handle_incoming(delete)

    assert {:ok, %Activity{}} =
             object_id
             |> delete_object(actor, "authorized-retry")
             |> Transmogrifier.handle_incoming()

    assert Object.get_by_ap_id(object_id).data["type"] == "Tombstone"
  end

  test "deletes an owned actorless resource without status side effects", %{actor: actor} do
    edition = %{
      "id" => "https://bookwyrm.example/book/edition/owned",
      "type" => "Edition",
      "owner" => actor.ap_id,
      "title" => "A removable federated book",
      "work" => "https://bookwyrm.example/book/work/1",
      "isbn13" => "9780123456789"
    }

    assert {:ok, %Object{}, _meta} =
             Pipeline.common_pipeline(edition,
               local: false,
               fetched_from: edition["id"],
               do_not_federate: true
             )

    assert {:ok, %Activity{}} =
             edition["id"]
             |> delete_object(actor, "edition")
             |> Transmogrifier.handle_incoming()

    tombstone = Object.get_by_ap_id(edition["id"])
    assert tombstone.data["type"] == "Tombstone"
    assert tombstone.data["formerType"] == "Edition"
    assert Activity.get_create_by_object_ap_id(edition["id"]) == nil
  end

  test "uses managedBy rather than attributedTo as ForgeFed Ticket authority" do
    author =
      insert(:user,
        local: false,
        ap_id: "https://forge.example/users/alice",
        follower_address: "https://forge.example/users/alice/followers"
      )

    repository =
      insert(:user,
        local: false,
        actor_type: "Repository",
        ap_id: "https://forge.example/projects/alpha",
        follower_address: "https://forge.example/projects/alpha/followers"
      )

    ticket = fixture("forgefed-ticket.json")

    assert {:ok, %Object{} = object, _meta} =
             Pipeline.common_pipeline(ticket,
               local: false,
               fetched_from: ticket["id"],
               do_not_federate: true
             )

    assert object.data[CustomObject.internal_field()]["authority"] == %{
             "delete" => [repository.ap_id],
             "write" => [repository.ap_id]
           }

    author_update =
      ticket
      |> Map.put("updated", "2026-07-17T13:00:00Z")
      |> Map.put("name", "The author must not control a managed ticket")

    assert {:error, _reason} =
             author_update
             |> update_object(author, "author")
             |> Transmogrifier.handle_incoming()

    assert Object.get_by_ap_id(ticket["id"]).data["name"] == ticket["name"]

    repository_update =
      ticket
      |> Map.put("updated", "2026-07-17T13:01:00Z")
      |> Map.put("name", "The repository accepted the ticket update")
      |> Map.delete("forgefed:milestone")

    assert {:ok, %Activity{}} =
             repository_update
             |> update_object(repository, "repository")
             |> Transmogrifier.handle_incoming()

    updated = Object.get_by_ap_id(ticket["id"])
    assert updated.data["name"] == "The repository accepted the ticket update"
    assert updated.data["forgefed:milestone"] == ticket["forgefed:milestone"]

    assert {:error, _reason} =
             ticket["id"]
             |> delete_object(author, "ticket-author")
             |> Transmogrifier.handle_incoming()

    assert Object.get_by_ap_id(ticket["id"]).data["type"] == "Ticket"

    assert {:ok, %Activity{}} =
             ticket["id"]
             |> delete_object(repository, "ticket-repository")
             |> Transmogrifier.handle_incoming()

    tombstone = Object.get_by_ap_id(ticket["id"])
    assert tombstone.data["type"] == "Tombstone"
    assert tombstone.data["formerType"] == "Ticket"
  end

  defp create_review(actor) do
    review = %{
      "id" => "https://bookwyrm.example/user/alice/status/1",
      "type" => "Review",
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor.follower_address],
      "content" => "A native BookWyrm review.",
      "context" => "https://bookwyrm.example/user/alice/status/1",
      "published" => "2026-07-17T12:00:00Z",
      "inReplyToBook" => "https://bookwyrm.example/book/1",
      "rating" => 4.5,
      "bookwyrm:edition" => %{
        "id" => "https://bookwyrm.example/book/edition/1",
        "isbn13" => "9780123456789"
      }
    }

    %{
      "id" => "https://bookwyrm.example/user/alice/status/1/activity",
      "type" => "Create",
      "actor" => actor.ap_id,
      "to" => review["to"],
      "cc" => review["cc"],
      "context" => review["context"],
      "object" => review
    }
  end

  defp update_review(object, actor, suffix) do
    update_object(object, actor, suffix)
  end

  defp update_object(object, actor, suffix) do
    %{
      "id" => "#{actor.ap_id}/activities/update/#{suffix}",
      "type" => "Update",
      "actor" => actor.ap_id,
      "to" => object["to"],
      "cc" => object["cc"],
      "object" => object
    }
  end

  defp delete_object(object_id, actor, suffix) do
    %{
      "id" => "#{actor.ap_id}/activities/delete/#{suffix}",
      "type" => "Delete",
      "actor" => actor.ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor.follower_address],
      "object" => object_id
    }
  end

  defp fixture(name) do
    "test/fixtures/#{name}"
    |> File.read!()
    |> Jason.decode!()
  end
end

# end of test/pleroma/web/activity_pub/transmogrifier/custom_object_handling_test.exs
