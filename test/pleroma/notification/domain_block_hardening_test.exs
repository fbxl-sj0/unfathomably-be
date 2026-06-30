# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Notification.DomainBlockHardeningTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Activity
  alias Pleroma.Notification

  import Pleroma.Factory

  describe "exclude_domain_blocker_ap_ids/3" do
    test "keeps recipients when the activity actor host is malformed" do
      user = insert(:user, domain_blocks: ["example.com"])
      activity = %Activity{actor: "https://%"}

      assert Notification.exclude_domain_blocker_ap_ids([user.ap_id], activity, [user]) == [
               user.ap_id
             ]
    end
  end
end
