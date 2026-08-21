# Unfathomably BE
# ----------------
#
# File: security_regression_test.exs
#
# Purpose:
#
#   Prove that security fixes present in vendored Erlang dependencies remain
#   active even when external advisory databases misclassify their versions.
#
# Responsibilities:
#
#   * Guard Gun request headers against CR/LF injection.
#   * Guard cowlib structured header strings against control characters.
#   * Guard cowlib cookie values against response-header injection.
#
# This file intentionally does not test application HTTP policy or networking.

defmodule Pleroma.Vendor.SecurityRegressionTest do
  use ExUnit.Case, async: true

  describe "vendored header injection protections" do
    test "Gun rejects CR/LF in request header values by default" do
      assert_raise ErlangError, fn ->
        :gun.headers(self(), "GET", "/", [{"x-test", "safe\r\ninjected: true"}])
      end
    end

    test "cowlib rejects control characters in structured header strings" do
      assert_raise ArgumentError, fn ->
        :cow_http_struct_hd.item({:item, {:string, "safe\r\ninjected"}, []})
      end
    end

    test "cowlib rejects CR/LF in Cookie request header values" do
      assert_raise MatchError, fn ->
        :cow_cookie.cookie([{"session", "safe\r\ninjected"}])
      end
    end
  end
end

# end of security_regression_test.exs
