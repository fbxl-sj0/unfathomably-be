# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only
defmodule Pleroma.Web.ActivityPub.MRF.UserAllowListPolicyTest do
  use Pleroma.DataCase
  import Pleroma.Factory

  alias Pleroma.Web.ActivityPub.MRF.UserAllowListPolicy

  setup do: clear_config(:mrf_user_allowlist)

  test "pass filter if allow list is empty" do
    actor = insert(:user)
    message = %{"actor" => actor.ap_id}
    assert UserAllowListPolicy.filter(message) == {:ok, message}
  end

  test "pass filter if allow list isn't empty and user in allow list" do
    actor = insert(:user)
    clear_config([:mrf_user_allowlist], %{"localhost" => [actor.ap_id, "test-ap-id"]})
    message = %{"actor" => actor.ap_id}
    assert UserAllowListPolicy.filter(message) == {:ok, message}
  end

  test "pass filter if allow list uses hosts subkey and user is in allow list" do
    actor = insert(:user)
    clear_config([:mrf_user_allowlist], %{hosts: %{"localhost" => [actor.ap_id]}})
    message = %{"actor" => actor.ap_id}
    assert UserAllowListPolicy.filter(message) == {:ok, message}
  end

  test "rejected if allow list isn't empty and user not in allow list" do
    actor = insert(:user)
    clear_config([:mrf_user_allowlist], %{"localhost" => ["test-ap-id"]})
    message = %{"actor" => actor.ap_id}
    assert {:reject, _} = UserAllowListPolicy.filter(message)
  end

  test "describe counts hosts from the hosts subkey" do
    clear_config([:mrf_user_allowlist], %{hosts: %{"localhost" => ["test-ap-id"]}})
    assert {:ok, %{mrf_user_allowlist: %{"localhost" => 1}}} = UserAllowListPolicy.describe()
  end
end
