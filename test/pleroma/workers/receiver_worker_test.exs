# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReceiverWorkerTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import Mock
  import Pleroma.Factory

  alias Pleroma.Workers.ReceiverWorker

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

  test "it does not retry permanent pipeline changeset failures" do
    params = insert(:note_activity).data
    changeset = %Ecto.Changeset{}

    with_mock Pleroma.Web.ActivityPub.Transmogrifier,
      handle_incoming: fn _ -> {:error, {:persist, {:error, changeset}}} end do
      assert {:cancel, {:error, ^changeset}} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end

  test "it does not retry unsupported incoming activity types" do
    params =
      insert(:note_activity).data
      |> Map.put("id", Pleroma.Web.ActivityPub.Utils.generate_activity_id())
      |> Map.put("type", "View")

    assert {:cancel, {:unsupported_activity_type, "View"}} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{"op" => "incoming_ap_doc", "params" => params}
             })
  end

  test "it does not retry duplicates" do
    params = insert(:note_activity).data

    assert {:cancel, :already_present} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{"op" => "incoming_ap_doc", "params" => params}
             })
  end

  test "it does not retry permanent HTTP fetch failures" do
    params = insert(:note_activity).data

    with_mock Pleroma.Web.Federator,
      perform: fn :incoming_ap_doc, _ -> {:error, {:http, 403}} end do
      assert {:cancel, {:http, 403}} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end

  test "it does not retry opaque permanent incoming errors" do
    params = insert(:note_activity).data

    with_mock Pleroma.Web.Federator,
      perform: fn :incoming_ap_doc, _ -> :error end do
      assert {:cancel, :error} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end

  test "it handles JSON activity batches one document at a time" do
    params = %{"_json" => [%{"id" => "known"}, %{"id" => "new"}]}

    with_mock Pleroma.Web.Federator,
      perform: fn
        :incoming_ap_doc, %{"id" => "known"} -> {:error, :already_present}
        :incoming_ap_doc, %{"id" => "new"} -> {:ok, :new}
      end do
      assert {:ok, :batch_processed} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end
end
