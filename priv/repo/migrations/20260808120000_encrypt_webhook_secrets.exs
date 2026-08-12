# Unfathomably BE
# ----------------
#
# File: 20260808120000_encrypt_webhook_secrets.exs
#
# Purpose:
#   Replace plaintext webhook signing secrets with authenticated ciphertext.
#
# Responsibilities:
#   - encrypt every existing non-empty webhook secret
#   - derive row-specific keys so ciphertext cannot be copied between webhooks
#   - provide a reversible rollback for operational recovery
#
# This file intentionally does NOT rotate webhook secrets or change webhook
# URLs, subscriptions, enabled state, or delivery history.

defmodule Pleroma.Repo.Migrations.EncryptWebhookSecrets do
  use Ecto.Migration

  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.MessageEncryptor

  @ciphertext_prefix "v1:"
  @encryption_salt "unfathomably-webhook-secret-v1"
  @signing_salt "unfathomably-webhook-secret-sign-v1"

  def up do
    transform_secrets(&encrypt/2, "NOT LIKE 'v1:%'")
  end

  def down do
    transform_secrets(&decrypt/2, "LIKE 'v1:%'")
  end

  defp transform_secrets(transform, predicate) do
    query =
      "SELECT id, secret FROM webhooks " <>
        "WHERE secret IS NOT NULL AND secret <> '' AND secret #{predicate}"

    %{rows: rows} = repo().query!(query, [], log: false)

    Enum.each(rows, fn [id, secret] ->
      transformed = transform.(secret, id)

      repo().query!(
        "UPDATE webhooks SET secret = $1 WHERE id = $2",
        [transformed, id],
        log: false
      )
    end)
  end

  defp encrypt(secret, webhook_id) do
    {encryption_secret, signing_secret} = secret_pair(webhook_id)
    @ciphertext_prefix <> MessageEncryptor.encrypt(secret, encryption_secret, signing_secret)
  end

  defp decrypt(@ciphertext_prefix <> ciphertext, webhook_id) do
    {encryption_secret, signing_secret} = secret_pair(webhook_id)
    {:ok, secret} = MessageEncryptor.decrypt(ciphertext, encryption_secret, signing_secret)
    secret
  end

  defp secret_pair(webhook_id) do
    endpoint_config = Application.fetch_env!(:pleroma, Pleroma.Web.Endpoint)
    secret_key_base = Keyword.fetch!(endpoint_config, :secret_key_base)
    row_salt = Integer.to_string(webhook_id)

    {
      KeyGenerator.generate(secret_key_base, @encryption_salt <> ":" <> row_salt),
      KeyGenerator.generate(secret_key_base, @signing_salt <> ":" <> row_salt)
    }
  end
end

# end of 20260808120000_encrypt_webhook_secrets.exs
