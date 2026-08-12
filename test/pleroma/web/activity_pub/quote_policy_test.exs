# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.QuotePolicyTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.QuotePolicy

  import Pleroma.Factory

  test "uses the following collection advertised by a remote actor" do
    following_address = "https://remote.example/collections/alice-follows"
    author = insert(:user, following_address: following_address)

    assert %{
             "canQuote" => %{"automaticApproval" => [^following_address]}
           } = QuotePolicy.build(author, "following")

    object = %Object{data: %{"actor" => author.ap_id}}

    assert QuotePolicy.name(
             %{"canQuote" => %{"automaticApproval" => [following_address]}},
             object
           ) == "following"
  end

  test "falls back to the conventional following collection for legacy actors" do
    author = insert(:user, following_address: nil)

    assert %{
             "canQuote" => %{"automaticApproval" => [following_address]}
           } = QuotePolicy.build(author, "following")

    assert following_address == author.ap_id <> "/following"
  end
end

# end of quote_policy_test.exs
