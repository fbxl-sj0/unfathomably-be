# Unfathomably BE
# ----------------
#
# File: test/pleroma/workers/diaspora_delivery_worker_test.exs
#
# Purpose:
#   Verify independently retryable Diaspora HTTP delivery boundaries.
#
# Responsibilities:
#   - reject unsafe or malformed destination URLs before queue insertion
#   - retry temporary HTTP responses
#   - cancel deterministic remote rejection
#
# This file intentionally does NOT select Diaspora recipients or serialize
# protocol entities.

defmodule Pleroma.Workers.DiasporaDeliveryWorkerTest do
  use Pleroma.DataCase, async: false

  import Tesla.Mock

  alias Pleroma.Workers.DiasporaDeliveryWorker

  @body "<me:env />"
  @content_type "application/magic-envelope+xml"

  test "rejects non-HTTPS and private-network destinations" do
    assert {:error, :invalid_destination} =
             DiasporaDeliveryWorker.enqueue_delivery(
               "http://example.com/receive/public",
               @body,
               @content_type
             )

    assert {:error, :invalid_destination} =
             DiasporaDeliveryWorker.enqueue_delivery(
               "https://127.0.0.1/receive/public",
               @body,
               @content_type
             )
  end

  test "retries temporary HTTP failures" do
    mock(fn %{method: :post} -> %Tesla.Env{status: 503, body: "unavailable"} end)

    job =
      build_job("https://example.com/receive/public")

    assert {:error, {:http, 503}} = DiasporaDeliveryWorker.perform(job)
  end

  test "cancels deterministic HTTP rejection" do
    mock(fn %{method: :post} -> %Tesla.Env{status: 404, body: "missing"} end)

    job =
      build_job("https://example.com/receive/public")

    assert {:cancel, {:http, 404}} = DiasporaDeliveryWorker.perform(job)
  end

  defp build_job(url) do
    %Oban.Job{
      attempt: 1,
      args: %{"body" => @body, "content_type" => @content_type, "url" => url}
    }
  end
end

# end of test/pleroma/workers/diaspora_delivery_worker_test.exs
