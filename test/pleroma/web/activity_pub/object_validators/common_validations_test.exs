# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CommonValidationsTest do
  use Pleroma.DataCase, async: true

  import Ecto.Changeset
  import Pleroma.Factory

  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  defp changeset(changes) do
    {%{}, %{actor: :any, object: :any, id: :any}}
    |> change(changes)
  end

  describe "validate_object_presence/2" do
    test "accepts embedded object references with ids" do
      object = insert(:note)

      changeset =
        %{object: %{"id" => object.data["id"]}}
        |> changeset()
        |> CommonValidations.validate_object_presence()

      assert changeset.valid?
    end

    test "rejects malformed object references without raising" do
      changeset =
        %{object: %{"type" => "Note"}}
        |> changeset()
        |> CommonValidations.validate_object_presence()

      refute changeset.valid?
      assert {:object, {"can't find object", []}} in changeset.errors
    end
  end

  describe "same_domain?/2" do
    test "requires every field to have a real host" do
      refute CommonValidations.same_domain?(
               changeset(%{actor: nil, object: "https://example.com/o/1"})
             )

      refute CommonValidations.same_domain?(
               changeset(%{actor: "not a uri", object: "https://example.com/o/1"})
             )
    end

    test "compares embedded object ids by host" do
      changeset =
        changeset(%{
          actor: "https://example.com/users/alice",
          object: %{"id" => "https://example.com/objects/1"}
        })

      assert CommonValidations.same_domain?(changeset)
    end
  end

  describe "fetch_actor_and_object/1" do
    test "ignores malformed activity envelopes and object references" do
      for data <- [
            nil,
            [],
            %{"actor" => ["not", "an", "actor"], "object" => nil},
            %{"actor" => "not a url", "object" => ["not", "an", "object"]},
            %{"actor" => %{"id" => ["not", "an", "id"]}, "object" => 123}
          ] do
        assert :ok = ObjectValidator.fetch_actor_and_object(data)
      end
    end
  end
end
