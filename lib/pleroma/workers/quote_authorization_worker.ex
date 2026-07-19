# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.QuoteAuthorizationWorker do
  @moduledoc """
  Fetches and verifies remote QuoteAuthorization documents outside the inbox
  transaction. Remote authorization is accepted only when every identity in
  the document matches the stored quote relationship.
  """

  use Oban.Worker,
    queue: :background,
    max_attempts: 5,
    unique: [period: :infinity, states: Oban.Job.states() -- [:discarded, :cancelled, :completed]]

  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.QuoteAuthorization
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.QuotePolicy

  def enqueue(quote_object_id, authorization) do
    %{"quote_object_id" => quote_object_id, "authorization" => authorization}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"quote_object_id" => quote_object_id, "authorization" => authorization}
      }) do
    with %Object{} = quote_object <- Repo.get(Object, quote_object_id),
         %QuoteAuthorization{} = record <- QuoteAuthorization.get_by_quote_object(quote_object),
         %Object{} = quoted_object <- Repo.get(Object, record.quoted_object_id),
         {:ok, document} <- Fetcher.fetch_and_contain_remote_object_from_id(authorization),
         true <- QuotePolicy.valid_authorization?(document, authorization, quote_object, quoted_object),
         {:ok, _object} <- QuoteAuthorization.transition(record, "accepted", authorization) do
      :ok
    else
      false -> {:cancel, :invalid_quote_authorization}
      nil -> {:cancel, :missing_quote}
      {:error, :not_found} -> {:cancel, :authorization_not_found}
      error -> error
    end
  end
end

# end of quote_authorization_worker.ex
