# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidatorTest do
  use Pleroma.DataCase, async: false

  import Mock
  import Pleroma.Factory

  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.ObjectValidator

  test "fetch_actor_and_object returns the object fetch failure" do
    actor = insert(:user)
    object_id = "https://remote.example/objects/missing"

    with_mock Fetcher, fetch_object_from_id: fn ^object_id -> {:error, {:http, 404}} end do
      assert {:error, {:http, 404}} =
               ObjectValidator.fetch_actor_and_object(%{
                 "actor" => actor.ap_id,
                 "object" => object_id
               })
    end
  end

  test "fetch_actor_and_object returns actor fetch failures" do
    with_mock Pleroma.User, get_or_fetch_by_ap_id: fn _ -> {:error, :not_found} end do
      assert {:error, :not_found} =
               ObjectValidator.fetch_actor_and_object(%{
                 "actor" => "https://remote.example/users/missing",
                 "object" => "https://remote.example/objects/missing"
               })
    end
  end
end
