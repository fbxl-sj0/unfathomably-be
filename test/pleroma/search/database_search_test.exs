# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearchTest do
  alias Pleroma.Search.DatabaseSearch, as: Search
  alias Pleroma.Web.CommonAPI
  import Pleroma.Factory

  use Pleroma.DataCase, async: true

  test "it finds something" do
    user = insert(:user)
    {:ok, post} = CommonAPI.post(user, %{status: "it's wednesday my dudes"})

    [result] = Search.search(nil, "wednesday")

    assert result.id == post.id
  end

  test "it finds content warnings" do
    user = insert(:user)
    {:ok, post} = CommonAPI.post(user, %{status: "ordinary body", spoiler_text: "hidden walrus"})

    [result] = Search.search(nil, "walrus")

    assert result.id == post.id
  end

  test "it finds local-only posts for authenticated users" do
    user = insert(:user)
    reader = insert(:user)
    {:ok, post} = CommonAPI.post(user, %{status: "it's wednesday my dudes", visibility: "local"})

    [result] = Search.search(reader, "wednesday")

    assert result.id == post.id
  end

  test "it does not find local-only posts for anonymous users" do
    user = insert(:user)
    {:ok, _post} = CommonAPI.post(user, %{status: "it's wednesday my dudes", visibility: "local"})

    assert [] = Search.search(nil, "wednesday")
  end

  test "using plainto_tsquery on postgres < 11" do
    postgres_version_key = {Pleroma.Repo, :postgres_version}
    old_version = :persistent_term.get(postgres_version_key, nil)

    :persistent_term.put(postgres_version_key, 10.0)

    on_exit(fn ->
      if is_nil(old_version) do
        :persistent_term.erase(postgres_version_key)
      else
        :persistent_term.put(postgres_version_key, old_version)
      end
    end)

    user = insert(:user)
    {:ok, post} = CommonAPI.post(user, %{status: "it's wednesday my dudes"})
    {:ok, _post2} = CommonAPI.post(user, %{status: "it's wednesday my bros"})

    # plainto doesn't understand complex queries
    assert [result] = Search.search(nil, "wednesday -dudes")

    assert result.id == post.id
  end

  test "using websearch_to_tsquery" do
    user = insert(:user)
    {:ok, _post} = CommonAPI.post(user, %{status: "it's wednesday my dudes"})
    {:ok, other_post} = CommonAPI.post(user, %{status: "it's wednesday my bros"})

    assert [result] = Search.search(nil, "wednesday -dudes")

    assert result.id == other_post.id
  end
end
