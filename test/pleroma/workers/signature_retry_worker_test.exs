# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.SignatureRetryWorkerTest do
  use Pleroma.DataCase, async: false

  import Mock

  alias Pleroma.Instances
  alias Pleroma.Signature
  alias Pleroma.User
  alias Pleroma.Web.Federator
  alias Pleroma.Web.Plugs.EnsureHostMatchesPlug
  alias Pleroma.Web.Plugs.MappedSignatureToIdentityPlug
  alias Pleroma.Workers.SignatureRetryWorker

  @actor "https://remote.example/users/alice"

  test "cancels terminal actor fetch failures instead of retrying forever" do
    terminal_statuses = [400, 404, 405, 406, 501]

    Enum.each(terminal_statuses, fn status ->
      with_mocks([
        {Signature, [],
         [
           get_actor_id: fn _conn -> {:ok, @actor} end,
           refetch_public_key: fn _conn -> {:ok, "public key"} end,
           validate_signature: fn _conn -> true end
         ]},
        {EnsureHostMatchesPlug, [],
         [
           call: fn conn, [] ->
             Plug.Conn.assign(conn, :valid_host_header, true)
           end
         ]},
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

  test "accepts the same signature actor with an explicit default HTTP port" do
    payload_actor = "http://xwiki.example:80/users/alice"
    signature_actor = "http://xwiki.example/users/alice"

    params = %{
      "id" => "http://xwiki.example:80/activities/accept-1",
      "type" => "Accept",
      "actor" => payload_actor,
      "object" => "https://local.example/activities/follow-1"
    }

    with_mocks([
      {Signature, [],
       [
         get_actor_id: fn _conn -> {:ok, signature_actor} end,
         refetch_public_key: fn _conn -> {:ok, "public key"} end,
         validate_signature: fn _conn -> true end
       ]},
      {EnsureHostMatchesPlug, [],
       [
         call: fn conn, [] ->
           Plug.Conn.assign(conn, :valid_host_header, true)
         end
       ]},
      {MappedSignatureToIdentityPlug, [], [call: fn conn, [] -> conn end]},
      {User, [], [get_or_fetch_by_ap_id: fn ^payload_actor -> {:ok, %User{}} end]},
      {Federator, [], [perform: fn :incoming_ap_doc, ^params -> {:ok, :accepted} end]},
      {Instances, [], [reachable?: fn ^payload_actor -> true end]}
    ]) do
      assert {:ok, :accepted} = SignatureRetryWorker.perform(retry_job(params))
    end
  end

  defp retry_job(status) when is_integer(status) do
    retry_job(%{
      "id" => "https://remote.example/activities/#{status}",
      "type" => "Create",
      "actor" => @actor
    })
  end

  defp retry_job(params) when is_map(params) do
    %Oban.Job{
      args: %{
        "op" => "incoming_failed_signature_ap_doc",
        "method" => "POST",
        "params" => params,
        "req_headers" => [{"host", "example.test"}],
        "request_path" => "/inbox",
        "query_string" => ""
      }
    }
  end
end

# end of signature_retry_worker_test.exs
