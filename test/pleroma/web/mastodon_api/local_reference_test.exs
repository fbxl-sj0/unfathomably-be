# Unfathomably Backend
#
# File: local_reference_test.exs
#
# Purpose:
#   Protect cache-only local routing for canonical actor and object links.

defmodule Pleroma.Web.MastodonAPI.LocalReferenceTest do
  use Pleroma.DataCase

  import Pleroma.Factory

  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.MastodonAPI.LocalReference

  test "maps known canonical links without changing labels or unknown links" do
    activity = insert(:note_activity)
    object = Object.normalize(activity, fetch: false)

    actor =
      insert(:user,
        local: false,
        ap_id: "https://remote.example/users/reader",
        nickname: "reader@remote.example"
      )

    html = """
    <p>
      <a href="#{object.data["id"]}">known post</a>
      <a href="#{actor.ap_id}">#{User.full_nickname(actor)}</a>
      <a href="https://unknown.example/item">unknown item</a>
    </p>
    """

    assert %{
             activity.id => %{
               object.data["id"] => "/notice/#{activity.id}",
               actor.ap_id => "/@#{User.full_nickname(actor)}"
             }
           } == LocalReference.for_statuses([{activity, html}], nil)
  end

  test "does not expose a locally stored direct status to a logged-out reader" do
    activity = insert(:direct_note_activity)
    object = Object.normalize(activity, fetch: false)
    html = ~s(<a href="#{object.data["id"]}">private</a>)

    assert %{activity.id => %{}} == LocalReference.for_statuses([{activity, html}], nil)
  end
end

# end of test/pleroma/web/mastodon_api/local_reference_test.exs
