# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Object.IdempotencyTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Object

  test "create/1 returns the existing object on duplicate AP IDs" do
    data = %{
      "id" => "https://remote.example/objects/duplicate",
      "type" => "Note",
      "actor" => "https://remote.example/users/alice",
      "content" => "duplicate delivery"
    }

    assert {:ok, first_object} = Object.create(data)
    assert {:ok, second_object} = Object.create(data)

    assert second_object.id == first_object.id
  end
end
