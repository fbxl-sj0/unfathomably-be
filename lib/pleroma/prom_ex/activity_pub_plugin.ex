# Unfathomably Backend
#
# File: activity_pub_plugin.ex
#
# Purpose:
#   Export privacy-preserving ActivityPub request telemetry through PromEx.
#
# This plugin intentionally exposes only bounded route, method, and response
# classes. It contains no actor, address, host, or concrete URL dimensions.

defmodule Pleroma.PromEx.ActivityPubPlugin do
  use PromEx.Plugin

  @event [:pleroma, :activity_pub, :request, :stop]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    metric_prefix =
      Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :activity_pub))

    tags = [:route, :method, :response_class]

    Event.build(
      :pleroma_activity_pub_event_metrics,
      [
        counter(
          metric_prefix ++ [:request, :count],
          event_name: @event,
          measurement: :count,
          description: "ActivityPub HTTP requests grouped by bounded route and response class.",
          tags: tags
        ),
        distribution(
          metric_prefix ++ [:request, :duration, :milliseconds],
          event_name: @event,
          measurement: :duration,
          description: "ActivityPub HTTP request duration.",
          tags: tags,
          unit: {:native, :millisecond},
          reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000, 15_000]]
        )
      ]
    )
  end
end

# end of lib/pleroma/prom_ex/activity_pub_plugin.ex
