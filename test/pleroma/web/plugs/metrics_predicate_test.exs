# Project: Unfathomably BE
# --------------------------
#
# File: metrics_predicate_test.exs
#
# Purpose:
#
#   Verify access-control behavior for the PromEx metrics endpoint predicate.
#
# Responsibilities:
#
#   * prove metrics access fails closed without an explicit token
#   * prove valid bearer tokens unlock metrics access
#   * prove unauthenticated metrics access requires an explicit source-config
#     opt-in
#
# This file intentionally does NOT contain:
#
#   * PromEx metric shape assertions
#   * endpoint integration tests
#   * Prometheus scraper configuration tests

defmodule Pleroma.Web.Plugs.MetricsPredicateTest do
  use Pleroma.Web.ConnCase, async: false

  alias Pleroma.Web.Plugs.MetricsPredicate

  setup do
    original = Application.get_env(:pleroma, MetricsPredicate)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:pleroma, MetricsPredicate)
        value -> Application.put_env(:pleroma, MetricsPredicate, value)
      end
    end)

    Application.delete_env(:pleroma, MetricsPredicate)

    :ok
  end

  test "fails closed when no metrics auth token is configured", %{conn: conn} do
    refute MetricsPredicate.call(conn, [])
  end

  test "fails closed when the configured metrics token is blank", %{conn: conn} do
    Application.put_env(:pleroma, MetricsPredicate, auth_token: nil)
    refute MetricsPredicate.call(conn, [])

    Application.put_env(:pleroma, MetricsPredicate, auth_token: "")
    refute MetricsPredicate.call(conn, [])
  end

  test "requires a matching bearer token", %{conn: conn} do
    Application.put_env(:pleroma, MetricsPredicate, auth_token: "metric-token")

    refute MetricsPredicate.call(conn, [])

    conn =
      Plug.Conn.put_req_header(conn, "authorization", "Bearer wrong-token")

    refute MetricsPredicate.call(conn, [])

    conn =
      Plug.Conn.put_req_header(conn, "authorization", "Bearer metric-token")

    assert MetricsPredicate.call(conn, [])
  end

  test "allows unauthenticated access only when explicitly disabled", %{conn: conn} do
    Application.put_env(:pleroma, MetricsPredicate, auth_token: :disabled)

    assert MetricsPredicate.call(conn, [])
  end
end

# end of metrics_predicate_test.exs
