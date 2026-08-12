# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.InboxGuardPlugTest do
  use Pleroma.Web.ConnCase

  import ExUnit.CaptureLog
  import Pleroma.Factory
  import Plug.Conn

  alias Pleroma.Web.Plugs.InboxGuardPlug

  setup do
    clear_config([:instance, :federating], true)
  end

  test "logs bounded activity context for an unknown unsigned activity type" do
    log =
      capture_log(fn ->
        conn =
          build_conn(:post, "/inbox", %{
            "actor" => "https://remote.example/users/alice",
            "id" => "https://remote.example/activities/unsupported",
            "type" => "UnsupportedActivity"
          })
          |> InboxGuardPlug.call([])

        assert conn.halted
        assert conn.status == 400
        assert Jason.decode!(conn.resp_body) == "Invalid activity type"
      end)

    assert log =~ "Inbox guard rejected request"
    assert log =~ "actor=\"https://remote.example/users/alice\""
    assert log =~ "activity_id=\"https://remote.example/activities/unsupported\""
    assert log =~ "type=\"UnsupportedActivity\""
  end

  test "acknowledges an unsupported activity with a valid signature" do
    conn =
      build_conn(:post, "/inbox", %{
        "actor" => "https://remote.example/users/alice",
        "id" => "https://remote.example/activities/unsupported",
        "type" => "UnsupportedActivity"
      })
      |> assign(:valid_signature, true)
      |> InboxGuardPlug.call([])

    assert conn.halted
    assert conn.status == 202
    assert conn.resp_body == "Unsupported activity acknowledged"
  end

  test "acknowledges an unsupported activity from an already-known actor" do
    actor = "https://remote.example/users/alice"
    insert(:user, local: false, ap_id: actor, nickname: "alice@remote.example")

    conn =
      build_conn(:post, "/inbox", %{
        "actor" => actor,
        "id" => "https://remote.example/activities/unsupported",
        "type" => "UnsupportedActivity"
      })
      |> InboxGuardPlug.call([])

    assert conn.halted
    assert conn.status == 202
    assert conn.resp_body == "Unsupported activity acknowledged"
  end

  test "rejects an actorless activity before it reaches the receiver queue" do
    conn =
      build_conn(:post, "/inbox", %{
        "id" => "https://remote.example/activities/actorless",
        "object" => %{"type" => "Note"},
        "type" => "Create"
      })
      |> assign(:valid_signature, true)
      |> InboxGuardPlug.call([])

    assert conn.halted
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == "Activity actor is required"
  end

  test "derives an actorless FeatureRequest actor from its verified direct signer" do
    signer = insert(:user, local: false, is_active: true)

    conn =
      build_conn(:post, "/inbox", %{
        "id" => signer.ap_id <> "/feature-requests/1",
        "instrument" => signer.ap_id <> "/collections/starter-pack",
        "object" => "https://local.example/users/alice",
        "type" => "FeatureRequest"
      })
      |> assign(:valid_signature, true)
      |> assign(:user, signer)
      |> InboxGuardPlug.call([])

    refute conn.halted
    assert conn.body_params["actor"] == signer.ap_id
    assert conn.params["actor"] == signer.ap_id
  end

  test "passes supported QuoteRequest activities to the receiver" do
    actor = insert(:user, local: false)

    conn =
      build_conn(:post, "/inbox", %{
        "actor" => actor.ap_id,
        "id" => actor.ap_id <> "/quote-requests/1",
        "instrument" => actor.ap_id <> "/objects/quote",
        "object" => "https://local.example/objects/quoted",
        "to" => ["https://local.example/users/alice"],
        "type" => "QuoteRequest"
      })
      |> assign(:valid_signature, true)
      |> InboxGuardPlug.call([])

    refute conn.halted
  end

  test "accepts an embedded actor identifier" do
    conn =
      build_conn(:post, "/inbox", %{
        "actor" => %{"id" => "https://remote.example/users/alice"},
        "id" => "https://remote.example/activities/create",
        "object" => %{"type" => "Note"},
        "type" => "Create"
      })
      |> InboxGuardPlug.call([])

    refute conn.halted
  end

  test "acknowledges a self-delete for an unknown actor on first contact" do
    actor = "https://remote.example/users/deleted"

    conn =
      build_conn(:post, "/inbox", %{
        "actor" => actor,
        "id" => actor <> "#delete",
        "object" => actor,
        "type" => "Delete"
      })
      |> InboxGuardPlug.call([])

    assert conn.halted
    assert conn.status == 202
    assert conn.resp_body == "Delete acknowledged for unknown actor"
  end

  test "rejects an unknown actor deleting a different object" do
    actor = "https://remote.example/users/unknown"

    conn =
      build_conn(:post, "/inbox", %{
        "actor" => actor,
        "id" => actor <> "#delete",
        "object" => "https://remote.example/users/someone-else",
        "type" => "Delete"
      })
      |> InboxGuardPlug.call([])

    assert conn.halted
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == "Invalid activity type for an unknown actor"
  end
end

# end of inbox_guard_plug_test.exs
