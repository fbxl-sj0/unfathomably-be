# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.UserViewInteractionPolicyTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  alias Pleroma.Web.ActivityPub.UserView

  test "allows public collection featuring for a discoverable actor" do
    user = insert(:user, is_discoverable: true)

    assert get_in(UserView.render("user.json", %{user: user}), [
             "interactionPolicy",
             "canFeature",
             "automaticApproval"
           ]) == [Pleroma.Constants.as_public()]
  end

  test "limits collection featuring to a non-discoverable actor itself" do
    user = insert(:user, is_discoverable: false)

    assert get_in(UserView.render("user.json", %{user: user}), [
             "interactionPolicy",
             "canFeature",
             "automaticApproval"
           ]) == [user.ap_id]
  end
end

# end of user_view_interaction_policy_test.exs
