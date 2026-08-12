# Unfathomably Backend
#
# File: report_audience_test.exs
#
# Purpose:
#   Prove that federated reports reach only authorized remote destinations.
#
# The tests intentionally exercise audience construction independently of HTTP
# publishing so follower fanout cannot be reintroduced by caller input.

defmodule Pleroma.Web.ActivityPub.ReportAudienceTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  alias Pleroma.GroupMembership
  alias Pleroma.Web.ActivityPub.ReportAudience

  test "routes a local community report to remote moderators and the reported instance" do
    group =
      insert(:user,
        local: true,
        actor_type: "Group",
        ap_id: "https://local.example/groups/engineering"
      )

    moderator =
      insert(:user,
        local: false,
        ap_id: "https://mods.example/users/alice"
      )

    ordinary_member =
      insert(:user,
        local: false,
        ap_id: "https://followers.example/users/bob"
      )

    reported =
      insert(:user,
        local: false,
        ap_id: "https://reported.example/users/carol"
      )

    assert {:ok, _membership} =
             GroupMembership.sync_directory_member(group, moderator, "moderator")

    assert {:ok, _membership} =
             GroupMembership.sync_directory_member(group, ordinary_member, "user")

    data = %{
      "type" => "Flag",
      "to" => [group.follower_address],
      "cc" => ["https://www.w3.org/ns/activitystreams#Public"],
      "audience" => group.follower_address
    }

    scoped =
      ReportAudience.scope(data, %{
        account: reported,
        statuses: [%{"audience" => group.ap_id}]
      })

    assert scoped["to"] == [moderator.ap_id, reported.ap_id]
    assert scoped["cc"] == []
    refute Map.has_key?(scoped, "audience")
    refute ordinary_member.ap_id in scoped["to"]
    refute group.follower_address in scoped["to"]
  end

  test "deduplicates authorized recipients by destination instance" do
    remote_group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://remote.example/c/engineering"
      )

    reported =
      insert(:user,
        local: false,
        ap_id: "https://remote.example/u/reported"
      )

    assert [recipient] =
             ReportAudience.recipients(%{
               account: reported,
               statuses: [%{"audience" => remote_group.ap_id}]
             })

    assert recipient == remote_group.ap_id
  end
end

# end of test/pleroma/web/activity_pub/report_audience_test.exs
