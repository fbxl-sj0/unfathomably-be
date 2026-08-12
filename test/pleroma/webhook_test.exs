# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.WebhookTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Webhook
  alias Pleroma.Webhook.Crypto

  test "creating a webhook" do
    %{id: id} = Webhook.create(%{url: "https://example.com/webhook", events: [:"report.created"]})

    assert %{url: "https://example.com/webhook", secret: ciphertext} = webhook = Webhook.get(id)
    assert Crypto.encrypted?(ciphertext)
    assert {:ok, secret} = Webhook.signing_secret(webhook)
    assert byte_size(secret) == 40
  end

  test "editing a webhook" do
    %{id: id} =
      webhook = Webhook.create(%{url: "https://example.com/webhook", events: [:"report.created"]})

    Webhook.update(webhook, %{events: [:"account.created"]})

    assert %{events: [:"account.created"]} = Webhook.get(id)
  end

  test "filter webhooks by type" do
    %{id: id1} =
      Webhook.create(%{url: "https://example.com/webhook1", events: [:"report.created"]})

    %{id: id2} =
      Webhook.create(%{
        url: "https://example.com/webhook2",
        events: [:"account.created", :"report.created"]
      })

    Webhook.create(%{url: "https://example.com/webhook3", events: [:"account.created"]})

    disabled =
      Webhook.create(%{url: "https://example.com/webhook4", events: [:"report.created"]})

    Webhook.set_enabled(disabled, false)

    assert [%{id: ^id1}, %{id: ^id2}] = Webhook.get_by_type(:"report.created")
  end

  test "change webhook state" do
    %{id: id, enabled: true} =
      webhook = Webhook.create(%{url: "https://example.com/webhook", events: [:"report.created"]})

    Webhook.set_enabled(webhook, false)
    assert %{enabled: false} = Webhook.get(id)
  end

  test "rotate webhook secrets" do
    %{id: id} =
      webhook = Webhook.create(%{url: "https://example.com/webhook", events: [:"report.created"]})

    assert {:ok, secret} = Webhook.signing_secret(webhook)
    assert {:ok, _webhook} = Webhook.rotate_secret(webhook)
    assert {:ok, new_secret} = id |> Webhook.get() |> Webhook.signing_secret()
    assert secret != new_secret
  end

  test "ciphertext is bound to its webhook record" do
    first = Webhook.create(%{url: "https://example.com/webhook1", events: [:"report.created"]})
    second = Webhook.create(%{url: "https://example.com/webhook2", events: [:"report.created"]})

    refute first.secret == second.secret

    assert {:error, :invalid_webhook_secret_ciphertext} =
             Crypto.decrypt(first.secret, second.id)
  end
end
