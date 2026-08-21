# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.QuoteHydrationTest do
  use Pleroma.DataCase
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.QuoteAuthorization
  alias Pleroma.QuoteHydration
  alias Pleroma.Workers.RemoteFetcherWorker

  test "enqueues a missing quote object for asynchronous hydration" do
    quote_actor = insert(:user)
    quote_url = "https://remote.example/objects/missing-quote"

    quote_object =
      insert(:note,
        user: quote_actor,
        data: %{
          "id" => "https://remote.example/objects/quote",
          "actor" => quote_actor.ap_id,
          "quoteUrl" => quote_url
        }
      )

    assert {:ok, %Oban.Job{}} = QuoteHydration.maybe_enqueue(quote_object, false, 1)

    assert_enqueued(
      worker: RemoteFetcherWorker,
      args: %{"op" => "fetch_quote", "id" => quote_url, "depth" => 1}
    )
  end

  test "reconciles quote objects that reference the hydrated object" do
    quoted_actor = insert(:user)
    quote_actor = insert(:user)

    quoted_object =
      insert(:note,
        user: quoted_actor,
        data: %{
          "id" => "https://origin.example/objects/hydrated",
          "actor" => quoted_actor.ap_id
        }
      )

    quote_object =
      insert(:note,
        user: quote_actor,
        data: %{
          "id" => "https://remote.example/objects/quote",
          "actor" => quote_actor.ap_id,
          "quoteUrl" => quoted_object.data["id"]
        }
      )

    assert QuoteAuthorization.get_by_quote_object(quote_object) == nil
    assert QuoteHydration.reconcile(quoted_object.data["id"]) == :ok

    assert %QuoteAuthorization{
             quote_object_id: quote_object_id,
             quoted_object_id: quoted_object_id
           } = QuoteAuthorization.get_by_quote_object(quote_object)

    assert quote_object_id == quote_object.id
    assert quoted_object_id == quoted_object.id
  end
end

# end of quote_hydration_test.exs
