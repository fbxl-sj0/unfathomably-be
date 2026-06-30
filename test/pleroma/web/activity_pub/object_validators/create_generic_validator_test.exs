# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
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
