# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Helpers.UriHelperTest do
  use ExUnit.Case, async: true

  alias Pleroma.Helpers.UriHelper

  describe "log_safe_url/1" do
    test "removes credentials, query values, and fragments while retaining context" do
      result =
        UriHelper.log_safe_url(
          "https://alice:secret@example.com/inbox/item?access_token=private#key"
        )

      assert result == "https://example.com/inbox/item?redacted"
      refute result =~ "alice"
      refute result =~ "secret"
      refute result =~ "private"
      refute result =~ "key"
    end

    test "does not echo malformed, non-HTTP, or oversized values" do
      assert UriHelper.log_safe_url("acct:alice@example.com") == "[invalid URL]"
      assert UriHelper.log_safe_url("not a URL?token=private") == "[invalid URL]"

      assert UriHelper.log_safe_url("https://example.com/" <> String.duplicate("x", 20_000)) ==
               "[invalid URL]"
    end
  end

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
