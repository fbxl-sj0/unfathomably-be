# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Helpers.UriHelperTest do
  use ExUnit.Case, async: true

  alias Pleroma.Helpers.UriHelper

  describe "equivalent?/2" do
    test "treats an omitted default port as the same HTTP resource" do
      assert UriHelper.equivalent?(
               "http://xwiki.example:80/users/alice",
               "http://xwiki.example/users/alice"
             )

      assert UriHelper.equivalent?(
               "https://xwiki.example:443/users/alice",
               "https://xwiki.example/users/alice"
             )
    end

    test "normalizes URI scheme and host case" do
      assert UriHelper.equivalent?(
               "HTTP://XWIKI.EXAMPLE/users/alice",
               "http://xwiki.example/users/alice"
             )
    end

    test "does not collapse distinct actor resources" do
      reference = "https://xwiki.example/users/alice"

      refute UriHelper.equivalent?(reference, "http://xwiki.example/users/alice")
      refute UriHelper.equivalent?(reference, "https://other.example/users/alice")
      refute UriHelper.equivalent?(reference, "https://xwiki.example:444/users/alice")
      refute UriHelper.equivalent?(reference, "https://xwiki.example/users/bob")
      refute UriHelper.equivalent?(reference, reference <> "?view=profile")
      refute UriHelper.equivalent?(reference, reference <> "#main-key")
    end

    test "rejects malformed and non-HTTP identifiers" do
      refute UriHelper.equivalent?(nil, nil)
      refute UriHelper.equivalent?("not a URI", "not a URI")
      refute UriHelper.equivalent?("acct:alice@example.com", "acct:alice@example.com")
    end
  end
end

# end of test/pleroma/helpers/uri_helper_test.exs
