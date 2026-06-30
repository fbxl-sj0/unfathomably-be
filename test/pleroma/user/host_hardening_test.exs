# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.User.HostHardeningTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.User

  describe "host helpers" do
    test "normalizes AP ID hosts" do
      assert User.get_host(%User{ap_id: "https://Example.COM./users/alice"}) == "example.com"
    end

    test "returns nil for malformed AP IDs without raising" do
      assert is_nil(User.get_host(%User{ap_id: "https://%"}))
      assert is_nil(User.get_by_guessed_nickname("https://%"))
    end
  end
end
