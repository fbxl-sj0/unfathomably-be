# Project: Unfathomably Backend Test Suite
# ----------------------------------------
#
# File: test/pleroma/web/federation/churn_test.exs
#
# Purpose:
#
#   Prove routine federation failure classification stays useful without
#   weakening protocol validation.
#
# Responsibilities:
#
#   * learn remote deactivation state from validation failures
#   * keep local account state protected from remote failure data
#   * classify PeerTube-style View signature mismatches as expected churn
#
# This file intentionally does NOT contain:
#
#   * network federation calls
#   * end-to-end ActivityPub delivery tests
#   * admin moderation workflow coverage

defmodule Pleroma.Web.Federation.ChurnTest do
  use Pleroma.DataCase, async: true

  import Ecto.Changeset
  import Pleroma.Factory

  alias Pleroma.User
  alias Pleroma.Web.Federation.Churn

  describe "mark_deactivated_actor/2" do
    test "marks a cached remote actor inactive when validation says the actor is deactivated" do
      remote_user = insert(:user, local: false, domain: "www.minds.com")
      error = deactivated_actor_error(remote_user.ap_id)

      assert {:ok, actor_id} =
               Churn.mark_deactivated_actor(error, "https://www.minds.com/object/1")

      assert actor_id == remote_user.ap_id
      refute User.get_by_ap_id(remote_user.ap_id).is_active
    end

    test "does not deactivate local users from remote validation errors" do
      local_user = insert(:user)
      error = deactivated_actor_error(local_user.ap_id)

      assert :noop = Churn.mark_deactivated_actor(error, "https://example.com/object/1")
      assert User.get_by_ap_id(local_user.ap_id).is_active
    end
  end

  test "classifies PeerTube telemetry signature mismatches as expected churn" do
    context = %{type: "View"}

    assert :forwarded_view_activity =
             Churn.signature_retry_category(:actor_signature_mismatch, context)

    assert :debug = Churn.signature_retry_log_level(:actor_signature_mismatch, context)

    context = %{type: "Download"}

    assert :forwarded_download_activity =
             Churn.signature_retry_category(:actor_signature_mismatch, context)

    assert :debug = Churn.signature_retry_log_level(:actor_signature_mismatch, context)
  end

  defp deactivated_actor_error(actor_id) do
    changeset =
      {%{}, %{actor: :string}}
      |> cast(%{actor: actor_id}, [:actor])
      |> add_error(:actor, "user is deactivated")

    {:error, {:transmogrifier, {:error, {:validate, {:error, changeset}}}}}
  end
end

# end of churn_test.exs
