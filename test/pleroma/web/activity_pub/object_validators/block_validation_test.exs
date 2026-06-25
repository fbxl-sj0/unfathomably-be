# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.BlockValidationTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.ObjectValidator

  import Pleroma.Factory

  describe "blocks" do
    setup do
      user = insert(:user, local: false)
      blocked = insert(:user)

      {:ok, valid_block, []} = Builder.block(user, blocked)

      %{user: user, valid_block: valid_block}
    end

    test "validates a basic object", %{
      valid_block: valid_block
    } do
      assert {:ok, _block, []} = ObjectValidator.validate(valid_block, [])
    end

    test "preserves Mbin-style scoped ban fields", %{
      valid_block: valid_block
    } do
      group = insert(:user, actor_type: "Group", local: false)

      block =
        valid_block
        |> Map.put("target", group.ap_id)
        |> Map.put("audience", [group.ap_id])
        |> Map.put("summary", "Off-topic in this magazine")
        |> Map.put("expires", "2026-07-24T12:00:00Z")

      assert {:ok, block, []} = ObjectValidator.validate(block, [])
      assert block["target"] == group.ap_id
      assert block["audience"] == [group.ap_id]
      assert block["summary"] == "Off-topic in this magazine"
      assert block["expires"] == "2026-07-24T12:00:00Z"
    end

    test "returns an error if we don't know the blocked user", %{
      valid_block: valid_block
    } do
      block =
        valid_block
        |> Map.put("object", "https://gensokyo.2hu/users/raymoo")

      assert {:error, _cng} = ObjectValidator.validate(block, [])
    end
  end
end
