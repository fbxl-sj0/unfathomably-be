# Unfathomably Backend
#
# File: activity_pub_metrics_plug_test.exs
#
# Purpose:
#   Prove that ActivityPub request telemetry remains useful and low-cardinality.

defmodule Pleroma.Web.Plugs.ActivityPubMetricsPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Pleroma.Web.ActivityPub.ActivityPubController
  alias Pleroma.Web.Plugs.ActivityPubMetricsPlug

  @event [:pleroma, :activity_pub, :request, :stop]

  test "emits only bounded route, method, and response-class metadata" do
    handler_id = "activity-pub-metrics-plug-#{System.unique_integer([:positive])}"
    test_process = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _config ->
          send(test_process, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :post
    |> conn("/users/private-name/inbox?token=secret")
    |> put_private(:phoenix_controller, ActivityPubController)
    |> put_private(:phoenix_action, :inbox)
    |> ActivityPubMetricsPlug.call([])
    |> send_resp(202, "accepted")

    assert_receive {:telemetry, @event, %{count: 1, duration: duration}, metadata}
    assert is_integer(duration) and duration >= 0

    assert metadata == %{
             method: "POST",
             response_class: "2xx",
             route: "activity_pub.inbox"
           }
  end
end

# end of test/pleroma/web/plugs/activity_pub_metrics_plug_test.exs
