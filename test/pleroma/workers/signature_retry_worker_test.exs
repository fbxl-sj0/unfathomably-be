# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.SignatureRetryWorkerTest do
  use Pleroma.DataCase, async: false

  import Mock

  alias Pleroma.Signature
  alias Pleroma.User
  alias Pleroma.Workers.SignatureRetryWorker

  @actor "https://remote.example/users/alice"

  test "cancels terminal actor fetch failures instead of retrying forever" do
    terminal_statuses = [400, 404, 405, 406, 501]

    Enum.each(terminal_statuses, fn status ->
      with_mocks([
        {Signature, [], [get_actor_id: fn _conn -> {:ok, @actor} end]},
        {User, [], [get_or_fetch_by_ap_id: fn @actor -> {:error, {:http, status}} end]}
      ]) do
        assert {:cancel, {:http, ^status}} = SignatureRetryWorker.perform(retry_job(status))
      end
    end)
  end

  test "cancels jobs that are missing the preserved request metadata" do
    assert {:cancel, :missing_signature_retry_metadata} =
             SignatureRetryWorker.perform(%Oban.Job{
               args: %{"op" => "incoming_failed_signature_ap_doc"}
             })
  end

  defp retry_job(status) do
    %Oban.Job{
      args: %{
        "op" => "incoming_failed_signature_ap_doc",
        "method" => "POST",
        "params" => %{
          "id" => "https://remote.example/activities/#{status}",
          "type" => "Create",
          "actor" => @actor
        },
        "req_headers" => [{"host", "example.test"}],
        "request_path" => "/inbox",
        "query_string" => ""
      }
    }
  end
end

# end of signature_retry_worker_test.exs
