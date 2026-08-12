# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Helpers.UriHelperCredentialTest do
  use ExUnit.Case, async: true

  alias Pleroma.Helpers.UriHelper

  test "redacts credentials, fragments, and query values from HTTP URLs" do
    result =
      UriHelper.log_safe_url(
        "https://alice:secret@example.com/path/to/object?token=private&page=2#access-token"
      )

    assert result == "https://example.com/path/to/object?redacted"
    refute result =~ "alice"
    refute result =~ "secret"
    refute result =~ "private"
  end

  test "preserves useful service DSN location without logging credentials" do
    result = UriHelper.log_safe_url("postgresql://pleroma:database-secret@db.example/pleroma")

    assert result == "postgresql://db.example/pleroma"
    refute result =~ "database-secret"
  end

  test "redacts every recognized URL repeated by an adapter error" do
    result =
      UriHelper.log_safe_text(
        "request https://user:pass@example.com/a?sig=one failed via redis://:secret@cache.example/0"
      )

    assert result =~ "https://example.com/a?redacted"
    assert result =~ "redis://cache.example/0"
    refute result =~ "pass"
    refute result =~ "secret"
    refute result =~ "sig=one"
  end
end

# end of uri_helper_credential_test.exs
