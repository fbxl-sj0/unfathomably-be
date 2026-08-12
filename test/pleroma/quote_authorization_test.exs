# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.QuoteAuthorizationTest do
  use Pleroma.DataCase
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.QuoteAuthorization
  alias Pleroma.Repo
  alias Pleroma.Workers.QuoteAuthorizationWorker

  test "an implicit update can enqueue verification without changing quote targets" do
    quoted_actor = insert(:user)
    quote_actor = insert(:user)

    quoted_object =
      insert(:note,
        data: %{
          "id" => "https://local.example/objects/quoted",
          "type" => "Note",
          "actor" => quoted_actor.ap_id,
          "content" => "Quoted post"
        }
      )

    quote_object =
      insert(:note,
        data: %{
          "id" => "https://remote.example/objects/quote",
          "type" => "Note",
          "actor" => quote_actor.ap_id,
          "content" => "Quoted commentary",
          "quoteUrl" => quoted_object.data["id"],
          "quoteState" => "pending"
        }
      )

    Repo.insert!(
      QuoteAuthorization.changeset(%QuoteAuthorization{}, %{
        quote_object_id: quote_object.id,
        quoted_object_id: quoted_object.id,
        quote_actor: quote_actor.ap_id,
        quoted_actor: quoted_actor.ap_id,
        state: "pending",
        policy: "manual",
        local: false
      })
    )

    authorization = "https://local.example/quote-authorizations/1"

    updated_data =
      quote_object.data
      |> Map.put("quoteAuthorization", authorization)

    assert :ok = QuoteAuthorization.reconcile_implicit_update(quote_object, updated_data)

    assert_enqueued(
      worker: QuoteAuthorizationWorker,
      args: %{
        "quote_object_id" => quote_object.id,
        "authorization" => authorization
      }
    )
  end

  test "an implicit update cannot swap the quote target while adding authorization" do
    quoted_object = insert(:note)
    quote_object = insert(:note, data: %{"quoteUrl" => quoted_object.data["id"]})

    Repo.insert!(
      QuoteAuthorization.changeset(%QuoteAuthorization{}, %{
        quote_object_id: quote_object.id,
        quoted_object_id: quoted_object.id,
        quote_actor: "https://remote.example/users/alice",
        quoted_actor: "https://local.example/users/bob",
        state: "pending",
        policy: "manual",
        local: false
      })
    )

    updated_data = %{
      "quoteUrl" => "https://local.example/objects/another",
      "quoteAuthorization" => "https://local.example/quote-authorizations/2"
    }

    assert :ok = QuoteAuthorization.reconcile_implicit_update(quote_object, updated_data)
    refute_enqueued(worker: QuoteAuthorizationWorker)
  end

  test "private authorization documents are limited to the quote participants" do
    quoted_actor = insert(:user)
    quote_actor = insert(:user)
    unrelated_actor = insert(:user)

    quoted_object =
      insert(:note,
        user: quoted_actor,
        data: %{
          "id" => "https://local.example/objects/private-quoted",
          "type" => "Note",
          "actor" => quoted_actor.ap_id,
          "to" => [quote_actor.ap_id],
          "cc" => []
        }
      )

    quote_object =
      insert(:note,
        user: quote_actor,
        data: %{
          "id" => "https://local.example/objects/private-quote",
          "type" => "Note",
          "actor" => quote_actor.ap_id,
          "quoteUrl" => quoted_object.data["id"],
          "to" => [quoted_actor.ap_id],
          "cc" => []
        }
      )

    Repo.insert!(
      QuoteAuthorization.changeset(%QuoteAuthorization{}, %{
        quote_object_id: quote_object.id,
        quoted_object_id: quoted_object.id,
        quote_actor: quote_actor.ap_id,
        quoted_actor: quoted_actor.ap_id,
        authorization_ap_id: QuoteAuthorization.authorization_uri(quote_object),
        state: "accepted",
        policy: "manual",
        local: true
      })
    )

    assert {:ok, _document} =
             QuoteAuthorization.authorization_document_for_requester(
               quote_object,
               quote_actor
             )

    assert {:ok, _document} =
             QuoteAuthorization.authorization_document_for_requester(
               quote_object,
               quoted_actor
             )

    assert {:error, :not_found} =
             QuoteAuthorization.authorization_document_for_requester(
               quote_object,
               unrelated_actor
             )

    assert {:error, :not_found} =
             QuoteAuthorization.authorization_document_for_requester(quote_object, nil)
  end
end

# end of quote_authorization_test.exs
