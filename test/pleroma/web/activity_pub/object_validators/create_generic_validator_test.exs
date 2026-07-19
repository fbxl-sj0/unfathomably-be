# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CreateGenericValidatorTest do
  use Pleroma.DataCase, async: true

  require Pleroma.Constants

  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.CreateGenericValidator
  alias Pleroma.Web.ActivityPub.Utils

  import Pleroma.Factory

  test "a Create/Note from Roadhouse validates" do
    insert(:user, ap_id: "https://macgirvin.com/channel/mike")

    note_activity =
      "test/fixtures/roadhouse-create-activity.json"
      |> File.read!()
      |> Jason.decode!()

    # Build metadata
    {:ok, object_data} = ObjectValidator.cast_and_apply(note_activity["object"])
    meta = [object_data: ObjectValidator.stringify_keys(object_data)]

    assert %{valid?: true} = CreateGenericValidator.cast_and_validate(note_activity, meta)
  end

  test "a Create/Note with mismatched context uses the Note's context" do
    user = insert(:user)

    note = %{
      "id" => Utils.generate_object_id(),
      "type" => "Note",
      "actor" => user.ap_id,
      "to" => [user.follower_address],
      "cc" => [],
      "content" => "Hello world",
      "context" => Utils.generate_context_id()
    }

    note_activity = %{
      "id" => Utils.generate_activity_id(),
      "type" => "Create",
      "actor" => note["actor"],
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "context" => Utils.generate_context_id()
    }

    # Build metadata
    {:ok, object_data} = ObjectValidator.cast_and_apply(note_activity["object"])
    meta = [object_data: ObjectValidator.stringify_keys(object_data)]

    validated = CreateGenericValidator.cast_and_validate(note_activity, meta)

    assert validated.valid?
    assert {:context, note["context"]} in validated.changes
  end

  test "a Create accepts an equivalent to and cc recipient partition" do
    actor = "https://lemmit.example/u/bot"
    community = "https://lemmit.example/c/example"

    insert(:user,
      local: false,
      ap_id: actor,
      follower_address: actor <> "/followers"
    )

    note = %{
      "id" => "https://lemmit.example/post/1",
      "type" => "Note",
      "actor" => actor,
      "attributedTo" => actor,
      "to" => [Pleroma.Constants.as_public(), community],
      "cc" => [],
      "audience" => community,
      "content" => "The same audience is split differently on the Create.",
      "context" => "https://lemmit.example/post/1"
    }

    activity = %{
      "id" => "https://lemmit.example/activities/create/1",
      "type" => "Create",
      "actor" => actor,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [community],
      "audience" => community,
      "object" => note,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "context" => note["context"]
    }

    {:ok, object_data} = ObjectValidator.cast_and_apply(note)
    object_data = ObjectValidator.stringify_keys(object_data)

    validated =
      CreateGenericValidator.cast_and_validate(activity, object_data: object_data)

    assert validated.valid?
    assert Ecto.Changeset.get_field(validated, :to) == object_data["to"]
    assert Ecto.Changeset.get_field(validated, :cc) == object_data["cc"]
  end

  test "a public Create accepts a local per-follower delivery recipient" do
    actor = "https://gancio.example/federation/u/relay"
    follower = insert(:user)

    insert(:user,
      local: false,
      ap_id: actor,
      follower_address: actor <> "/followers"
    )

    event = %{
      "id" => "https://gancio.example/federation/m/1",
      "type" => "Event",
      "actor" => actor,
      "attributedTo" => actor,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor <> "/followers"],
      "name" => "Public Gancio event",
      "content" => "The local follower appears only on the Create activity.",
      "startTime" => "2026-11-21T17:00:00+01:00",
      "context" => "https://gancio.example/federation/m/1"
    }

    activity = %{
      "id" => "https://gancio.example/federation/m/1#Create-1",
      "type" => "Create",
      "actor" => actor,
      "to" => event["to"],
      "cc" => [actor <> "/followers", follower.ap_id],
      "object" => event,
      "context" => event["context"]
    }

    {:ok, object_data} = ObjectValidator.cast_and_apply(event)
    object_data = ObjectValidator.stringify_keys(object_data)

    validated =
      CreateGenericValidator.cast_and_validate(activity, object_data: object_data)

    assert validated.valid?
    assert Ecto.Changeset.get_field(validated, :cc) == object_data["cc"]
  end

  test "a public Create still rejects an added remote delivery recipient" do
    actor = "https://gancio.example/federation/u/relay"

    insert(:user,
      local: false,
      ap_id: actor,
      follower_address: actor <> "/followers"
    )

    event = %{
      "id" => "https://gancio.example/federation/m/2",
      "type" => "Event",
      "actor" => actor,
      "attributedTo" => actor,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor <> "/followers"],
      "name" => "Public Gancio event",
      "content" => "A remote activity recipient must not widen the object audience.",
      "startTime" => "2026-11-21T17:00:00+01:00",
      "context" => "https://gancio.example/federation/m/2"
    }

    activity = %{
      "id" => "https://gancio.example/federation/m/2#Create-1",
      "type" => "Create",
      "actor" => actor,
      "to" => event["to"],
      "cc" => [actor <> "/followers", "https://remote.example/users/bob"],
      "object" => event,
      "context" => event["context"]
    }

    {:ok, object_data} = ObjectValidator.cast_and_apply(event)
    object_data = ObjectValidator.stringify_keys(object_data)

    validated =
      CreateGenericValidator.cast_and_validate(activity, object_data: object_data)

    refute validated.valid?
    assert {:cc, {_, []}} = List.keyfind(validated.errors, :cc, 0)
  end

  test "a public Create cannot use missing object addressing to accept a remote recipient" do
    actor = "https://wanderer.example/api/v1/activitypub/user/explorer"

    insert(:user,
      local: false,
      ap_id: actor,
      follower_address: actor <> "/followers"
    )

    note = %{
      "id" => "https://wanderer.example/api/v1/trail/unsafe-route",
      "type" => "Note",
      "actor" => actor,
      "attributedTo" => actor,
      "content" => "The embedded Trail deliberately omits its audience.",
      "context" => "https://wanderer.example/api/v1/trail/unsafe-route"
    }

    activity = %{
      "id" => "https://wanderer.example/api/v1/activitypub/activity/create-unsafe-route",
      "type" => "Create",
      "actor" => actor,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor <> "/followers", "https://remote.example/users/bob"],
      "object" => note,
      "context" => note["context"]
    }

    assert {:error, changeset} = ObjectValidator.validate(activity, local: false)
    assert {:cc, {_, []}} = List.keyfind(changeset.errors, :cc, 0)
  end

  test "a public Create accepts a producer-owned remote delivery collection" do
    actor = "https://mobilizon.example/@organizer"
    group = "https://mobilizon.example/@local_group"

    insert(:user,
      local: false,
      ap_id: actor,
      follower_address: actor <> "/followers"
    )

    event = %{
      "id" => "https://mobilizon.example/events/1",
      "type" => "Event",
      "actor" => actor,
      "attributedTo" => group,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor <> "/followers"],
      "name" => "Public Mobilizon event",
      "content" => "The group members collection is an outer delivery hint.",
      "startTime" => "2026-11-21T17:00:00Z",
      "context" => "https://mobilizon.example/events/1"
    }

    activity = %{
      "id" => "https://mobilizon.example/events/1/activity",
      "type" => "Create",
      "actor" => actor,
      "to" => event["to"],
      "cc" => [group <> "/members", actor <> "/followers"],
      "object" => event,
      "context" => event["context"]
    }

    {:ok, object_data} = ObjectValidator.cast_and_apply(event)
    object_data = ObjectValidator.stringify_keys(object_data)

    validated =
      CreateGenericValidator.cast_and_validate(activity, object_data: object_data)

    assert validated.valid?
    assert Ecto.Changeset.get_field(validated, :cc) == object_data["cc"]
  end

  test "a public ZenPub Create inherits its exact same-origin collection context" do
    actor = "https://zenpub.example/pub/actors/publisher"
    context = "https://zenpub.example/pub/actors/library"

    insert(:user,
      local: false,
      ap_id: actor,
      follower_address: actor <> "/followers"
    )

    document = %{
      "id" => "https://zenpub.example/pub/objects/resource-1",
      "type" => "Document",
      "actor" => actor,
      "attributedTo" => actor,
      "context" => context,
      "name" => "A native publishing resource",
      "summary" => "The embedded Document deliberately omits its audience.",
      "url" => "https://zenpub.example/uploads/resource-1.txt",
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    activity = %{
      "id" => "https://zenpub.example/pub/objects/create-resource-1",
      "type" => "Create",
      "actor" => actor,
      "to" => [Pleroma.Constants.as_public(), context],
      "cc" => [actor <> "/followers"],
      "object" => document,
      "context" => context,
      "published" => document["published"]
    }

    assert {:ok, validated, meta} = ObjectValidator.validate(activity, local: false)
    assert validated["to"] == activity["to"]
    assert validated["cc"] == activity["cc"]
    assert meta[:object_data]["to"] == activity["to"]
    assert meta[:object_data]["cc"] == activity["cc"]
  end

  test "a public Create cannot inherit a same-origin actor outside its context" do
    actor = "https://zenpub.example/pub/actors/publisher"
    context = "https://zenpub.example/pub/actors/library"
    unrelated = "https://zenpub.example/pub/actors/unrelated"

    insert(:user,
      local: false,
      ap_id: actor,
      follower_address: actor <> "/followers"
    )

    document = %{
      "id" => "https://zenpub.example/pub/objects/resource-unsafe",
      "type" => "Document",
      "actor" => actor,
      "attributedTo" => actor,
      "context" => context,
      "name" => "An unsafe publishing resource",
      "summary" => "A sibling actor is not a trusted delivery context.",
      "url" => "https://zenpub.example/uploads/resource-unsafe.txt",
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    activity = %{
      "id" => "https://zenpub.example/pub/objects/create-resource-unsafe",
      "type" => "Create",
      "actor" => actor,
      "to" => [Pleroma.Constants.as_public(), context, unrelated],
      "cc" => [actor <> "/followers"],
      "object" => document,
      "context" => context,
      "published" => document["published"]
    }

    assert {:error, changeset} = ObjectValidator.validate(activity, local: false)
    assert {:to, {_, []}} = List.keyfind(changeset.errors, :to, 0)
  end

  test "a Create/Note with an unknown actor is rejected without raising during addressing fixes" do
    actor = "https://unknown-create.example/users/alice"

    note = %{
      "id" => "https://unknown-create.example/objects/1",
      "type" => "Note",
      "actor" => actor,
      "attributedTo" => actor,
      "to" => [%{"href" => "Public"}],
      "cc" => [%{"id" => "https://unknown-create.example/users/alice/followers"}],
      "content" => "This actor has not been fetched yet.",
      "context" => Utils.generate_context_id()
    }

    note_activity = %{
      "id" => "https://unknown-create.example/activities/create/1",
      "type" => "Create",
      "actor" => actor,
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "context" => note["context"]
    }

    meta = [object_data: note]
    validated = CreateGenericValidator.cast_and_validate(note_activity, meta)

    refute validated.valid?
    assert {:actor, {"can't find user", []}} in validated.errors
  end

  test "a Create/Note with a missing actor is rejected without raising during host containment" do
    actor = "https://missing-actor.example/users/alice"

    note = %{
      "id" => "https://missing-actor.example/objects/1",
      "type" => "Note",
      "actor" => actor,
      "attributedTo" => actor,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [],
      "content" => "The activity actor is missing.",
      "context" => Utils.generate_context_id()
    }

    note_activity = %{
      "id" => "https://missing-actor.example/activities/create/1",
      "type" => "Create",
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "context" => note["context"]
    }

    validated = CreateGenericValidator.cast_and_validate(note_activity, object_data: note)

    refute validated.valid?
    assert {:actor, {"can't be blank", [validation: :required]}} in validated.errors
  end
end
