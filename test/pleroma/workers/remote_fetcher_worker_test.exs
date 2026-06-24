# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RemoteFetcherWorkerTest do
  use Pleroma.DataCase, async: false

  import Mock

  alias Pleroma.Object.Fetcher
  alias Pleroma.Workers.RemoteFetcherWorker

  test "cancels permanent remote fetch failures" do
    with_mock Fetcher, fetch_object_from_id: fn _, _ -> {:error, {:http, 404}} end do
      assert {:cancel, :not_found} =
               RemoteFetcherWorker.perform(%Oban.Job{
                 args: %{"op" => "fetch_remote", "id" => "https://remote.example/missing"}
               })
    end
  end

  test "cancels reaction activities whose actor or object cannot be fetched" do
    with_mock Fetcher,
      fetch_object_from_id: fn _, _ ->
        {:error, {:transmogrifier, {:error, :object_not_found}}}
      end do
      assert {:cancel, :object_not_found} =
               RemoteFetcherWorker.perform(%Oban.Job{
                 args: %{
                   "op" => "fetch_remote",
                   "id" => "https://remote.example/activities/like/1"
                 }
               })
    end
  end
end
