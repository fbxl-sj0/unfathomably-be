# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReceiverWorkerTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import Mock
  import Pleroma.Factory

  alias Pleroma.Workers.ReceiverWorker

  setup do
    clear_config([:instance, :federating], true)
  end

  test "it does not retry malformed incoming params" do
    assert {:cancel, :missing_incoming_ap_doc_params} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{"op" => "incoming_ap_doc", "params" => ["not", "a", "map"]}
             })

    assert {:cancel, :missing_incoming_ap_doc_params} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{"op" => "unknown"}
             })
  end

  test "it processes verified incoming jobs that preserve request headers normally" do
    params = insert(:note_activity).data

    with_mock Pleroma.Web.Federator,
      perform: fn :incoming_ap_doc, received_params ->
        assert received_params == params
        {:ok, :accepted}
      end do
      assert {:ok, :accepted} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{
                   "op" => "incoming_ap_doc",
                   "params" => params,
                   "req_headers" => [["signature", "verified"]]
                 }
               })
    end
  end

  test "it does not retry MRF reject" do
    params = insert(:note).data

    with_mock Pleroma.Web.ActivityPub.Transmogrifier,
      handle_incoming: fn _ -> {:reject, "MRF"} end do
      assert {:cancel, "MRF"} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end

  test "it does not retry ObjectValidator reject" do
    params =
      insert(:note_activity).data
      |> Map.put("id", Pleroma.Web.ActivityPub.Utils.generate_activity_id())
      |> Map.put("object", %{
        "type" => "Note",
        "id" => Pleroma.Web.ActivityPub.Utils.generate_object_id()
      })

    with_mock Pleroma.Web.ActivityPub.ObjectValidator, [:passthrough],
      validate: fn _, _ -> {:error, %Ecto.Changeset{}} end do
      assert {:cancel, {:error, %Ecto.Changeset{}}} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end

  test "it completes duplicate deliveries idempotently" do
    params = insert(:note_activity).data

    assert {:ok, :already_present} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{"op" => "incoming_ap_doc", "params" => params}
             })
  end

  test "it completes duplicate Like validation idempotently" do
    params = insert(:note_activity).data

    changeset =
      {%{}, %{actor: :string, object: :string}}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:actor, "already liked this object")
      |> Ecto.Changeset.add_error(:object, "already liked by this actor")

    with_mock Pleroma.Web.Federator,
      perform: fn :incoming_ap_doc, _ -> {:error, {:validate, {:error, changeset}}} end do
      assert {:ok, :already_present} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end

  test "it does not retry terminal HTTP errors" do
    params = insert(:note_activity).data

    for status <- [400, 405, 406, 501] do
      with_mock Pleroma.Web.Federator,
        perform: fn :incoming_ap_doc, _ -> {:error, {:http, status}} end do
        assert {:cancel, {:http, ^status}} =
                 ReceiverWorker.perform(%Oban.Job{
                   args: %{"op" => "incoming_ap_doc", "params" => params}
                 })
      end
    end
  end

  test "it bounds retries for unavailable remote action targets" do
    params = insert(:note_activity).data

    with_mock Pleroma.Web.Federator,
      perform: fn :incoming_ap_doc, _ -> {:error, :remote_object_unavailable} end do
      assert {:error, :remote_object_unavailable} =
               ReceiverWorker.perform(%Oban.Job{
                 attempt: 2,
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })

      assert {:cancel, {:remote_object_retries_exhausted, {:error, :remote_object_unavailable}}} =
               ReceiverWorker.perform(%Oban.Job{
                 attempt: 3,
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end

  test "it retries an Announce quickly while its referenced Create is pending" do
    object_id = "https://peertube.example/videos/watch/queued"

    create = %{
      "id" => "https://peertube.example/activities/create-queued",
      "type" => "Create",
      "actor" => "https://peertube.example/accounts/channel",
      "object" => %{"id" => object_id, "type" => "Video"}
    }

    assert {:ok, _job} =
             %{"op" => "incoming_ap_doc", "params" => create}
             |> ReceiverWorker.new()
             |> Oban.insert()

    announce_job = %Oban.Job{
      attempt: 2,
      args: %{
        "op" => "incoming_ap_doc",
        "params" => %{
          "type" => "Announce",
          "actor" => "https://peertube.example/accounts/channel",
          "object" => object_id
        }
      }
    }

    assert ReceiverWorker.backoff(announce_job) == 10
  end

  test "it keeps the normal backoff when an Announce has no pending Create" do
    job = %Oban.Job{
      attempt: 1,
      args: %{
        "op" => "incoming_ap_doc",
        "params" => %{"type" => "Announce", "object" => "https://remote.example/missing"}
      }
    }

    assert ReceiverWorker.backoff(job) >= 5 * 60
  end

  test "it bounds retries after verified TLS compatibility also fails" do
    params = insert(:note_activity).data

    error = {:error, {:tls_alert, {:handshake_failure, ~c"TLS client: handshake failed"}}}

    with_mock Pleroma.Web.Federator,
      perform: fn :incoming_ap_doc, _ -> error end do
      assert ^error =
               ReceiverWorker.perform(%Oban.Job{
                 attempt: 2,
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })

      assert {:cancel, {:transport_retries_exhausted, ^error}} =
               ReceiverWorker.perform(%Oban.Job{
                 attempt: 3,
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end
end
