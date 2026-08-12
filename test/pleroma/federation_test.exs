# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.FederationTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.Federation
  alias Pleroma.Web.Federator.Publisher

  import Pleroma.Tests.Helpers, only: [clear_config: 2]

  describe "runtime ActivityPub gate" do
    test "removes protocol advertisement and rejects new delivery work when disabled" do
      clear_config([:instance, :federating], false)

      refute Federation.enabled?()
      assert Federation.ensure_enabled() == {:error, :federation_disabled}
      assert Publisher.gather_nodeinfo_protocol_names() == []

      assert Publisher.enqueue_one(Pleroma.Web.ActivityPub.Publisher, %{}) ==
               {:error, :federation_disabled}
    end

    test "advertises configured protocols when enabled" do
      clear_config([:instance, :federating], true)

      assert Federation.enabled?()
      assert Federation.ensure_enabled() == :ok
      assert "activitypub" in Publisher.gather_nodeinfo_protocol_names()
    end
  end
end

# end of test/pleroma/federation_test.exs
