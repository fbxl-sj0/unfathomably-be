# Project: Unfathomably Backend
# --------------------------------
#
# File: test/pleroma/http_dependency_hardening_test.exs
#
# Purpose:
#
#   Preserve security fixes applied to vendored HTTP protocol dependencies.
#
# Responsibilities:
#
#   * prove cookie serialization rejects request-splitting characters
#   * prove structured-header serialization rejects non-VCHAR bytes
#
# This file intentionally does NOT contain:
#
#   * application HTTP client tests
#   * endpoint response tests

defmodule Pleroma.HTTPDependencyHardeningTest do
  use ExUnit.Case, async: true

  test "cookie encoding rejects separator and control-character injection" do
    assert catch_error(:cow_cookie.cookie([{<<"session">>, <<"value\r\nX-Injected: true">>}]))
    assert catch_error(:cow_cookie.cookie([{<<"session">>, <<"value; admin=true">>}]))
  end

  test "structured-header encoding rejects bytes outside visible ASCII" do
    assert catch_error(:cow_http_struct_hd.item({:item, <<"value\r\nX-Injected: true">>, []}))
  end
end

# end of test/pleroma/http_dependency_hardening_test.exs
