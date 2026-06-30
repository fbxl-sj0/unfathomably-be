# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReceiverWorkerTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import Mock
  import Pleroma.Factory

  alias Pleroma.Workers.ReceiverWorker

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

  test "it does not retry duplicates" do
    params = insert(:note_activity).data

    assert {:cancel, :already_present} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{"op" => "incoming_ap_doc", "params" => params}
             })
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
end
