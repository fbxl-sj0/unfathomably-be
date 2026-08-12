# Unfathomably Backend
#
# File: activity_pub_metrics_plug.ex
#
# Purpose:
#   Emit bounded aggregate telemetry for ActivityPub HTTP traffic.
#
# Responsibilities:
#   - time one request at the shared ActivityPub pipeline boundary
#   - classify routes from code-defined controller and action values
#   - classify status codes and methods into finite label sets
#
# This file intentionally does not record actors, account names, IP addresses,
# hosts, request bodies, query strings, or concrete request paths.

defmodule Pleroma.Web.Plugs.ActivityPubMetricsPlug do
  import Plug.Conn, only: [register_before_send: 2]

  @event [:pleroma, :activity_pub, :request, :stop]
  @known_methods ~w[DELETE GET HEAD OPTIONS PATCH POST PUT]
  @controller_labels %{
    Pleroma.Web.ActivityPub.ActivityPubController => "activity_pub",
    Pleroma.Web.ActivityPub.BookShelfController => "book_shelf",
    Pleroma.Web.ActivityPub.QuoteAuthorizationController => "quote_authorization"
  }

  def init(opts), do: opts

  def call(conn, _opts) do
    started_at = System.monotonic_time()

    register_before_send(conn, fn response_conn ->
      :telemetry.execute(
        @event,
        %{
          count: 1,
          duration: System.monotonic_time() - started_at
        },
        %{
          method: method_label(response_conn.method),
          response_class: response_class(response_conn.status),
          route: route_label(response_conn.private)
        }
      )

      response_conn
    end)
  end

  defp route_label(private) when is_map(private) do
    controller = Map.get(@controller_labels, private[:phoenix_controller], "other")

    action =
      case private[:phoenix_action] do
        action when is_atom(action) -> Atom.to_string(action)
        _unknown -> "unknown"
      end

    controller <> "." <> action
  end

  defp route_label(_private), do: "other.unknown"

  defp method_label(method) when method in @known_methods, do: method
  defp method_label(_method), do: "OTHER"

  defp response_class(status) when is_integer(status) and status >= 100 and status <= 599 do
    "#{div(status, 100)}xx"
  end

  defp response_class(_status), do: "other"
end

# end of lib/pleroma/web/plugs/activity_pub_metrics_plug.ex
