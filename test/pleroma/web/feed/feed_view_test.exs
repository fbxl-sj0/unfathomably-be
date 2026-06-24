# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Feed.FeedViewTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.Feed.FeedView

  test "date helpers tolerate missing or malformed remote dates" do
    assert is_binary(FeedView.to_rfc3339(nil))
    assert is_binary(FeedView.to_rfc3339("not a date"))
    assert is_binary(FeedView.to_rfc2822(nil))
    assert is_binary(FeedView.to_rfc2822("not a date"))
  end
end
