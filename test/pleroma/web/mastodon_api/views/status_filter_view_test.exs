# Unfathomably Mastodon filter result rendering
# ----------------------------------------------
# File: status_filter_view_test.exs
# Purpose: Protect exact filter-match metadata in rendered statuses.
# Responsibilities: Verify context handling and legacy filter compatibility.
# This file intentionally does NOT contain timeline query tests.

defmodule Pleroma.Web.MastodonAPI.StatusFilterViewTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  alias Pleroma.Filter
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.MastodonAPI.StatusView

  test "renders the exact matched text for an active reversible filter" do
    reader = insert(:user)
    author = insert(:user)

    {:ok, _filter} =
      Filter.create(%{
        user_id: reader.id,
        phrase: "cat",
        context: ["home"],
        whole_word: true,
        hide: false
      })

    {:ok, activity} = CommonAPI.post(author, %{status: "A CAT arrived"})

    rendered =
      StatusView.render("show.json", %{
        activity: activity,
        for: reader,
        filter_context: "home"
      })

    assert [result] = rendered.filtered
    assert result.filter.phrase == "cat"
    assert result.keyword_matches == ["CAT"]
    assert result.status_matches == []

    assert StatusView.render("show.json", %{
             activity: activity,
             for: reader,
             filter_context: "public"
           }).filtered == []
  end
end

# end of status_filter_view_test.exs
