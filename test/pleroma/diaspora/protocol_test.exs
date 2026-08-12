# Unfathomably BE
# ----------------
#
# File: test/pleroma/diaspora/protocol_test.exs
#
# Purpose:
#   Exercise diaspora* envelope encryption and entity parsing boundaries.
#
# Responsibilities:
#   - round-trip the official RSA plus AES-256-CBC private transport shape
#   - accept supported flat XML entities and reject unsigned arbitrary shapes
#
# This file intentionally does NOT discover a pod or create database records.

defmodule Pleroma.Diaspora.ProtocolTest do
  use ExUnit.Case, async: true

  alias Pleroma.Diaspora.Protocol
  alias Pleroma.Keys
  alias Pleroma.User

  test "round-trips an encrypted magic envelope for one local recipient" do
    {:ok, keys} = Keys.generate_rsa_pem()
    user = %User{keys: keys}
    public_key = public_key_pem(keys)
    envelope = "<me:env xmlns:me=\"http://salmon-protocol.org/ns/magic-env\" />"

    assert {:ok, payload} = Protocol.build_private_payload(envelope, public_key)
    assert {:ok, ^envelope} = Protocol.decrypt_private_payload(payload, user)
  end

  test "parses a supported status message" do
    xml = """
    <status_message>
      <author>alice@example.org</author>
      <guid>cbd482201fe1013486fe3131731751e9</guid>
      <created_at>2026-08-07T12:00:00Z</created_at>
      <text>Hello from diaspora*</text>
      <public>true</public>
    </status_message>
    """

    assert {:ok, data} = Protocol.parse_entity(xml)
    assert data["type"] == "status_message"
    assert data["author"] == "alice@example.org"
    assert data["text"] == "Hello from diaspora*"
  end

  test "parses bounded public profile fields" do
    xml = """
    <profile>
      <author>alice@example.org</author>
      <full_name>Alice Example</full_name>
      <image_url>https://example.org/alice.png</image_url>
      <bio>Federated **profile**</bio>
      <searchable>true</searchable>
      <public>true</public>
      <nsfw>false</nsfw>
      <tag_string>#books #federation</tag_string>
    </profile>
    """

    assert {:ok, data} = Protocol.parse_entity(xml)
    assert data["type"] == "profile"
    assert is_binary(data["guid"])
    assert byte_size(data["guid"]) == 32
    assert data["full_name"] == "Alice Example"
    assert data["bio"] == "Federated **profile**"
    assert data["public"] == "true"
  end

  test "rejects unsupported entity roots" do
    assert {:error, :unsupported_entity} =
             Protocol.parse_entity("<arbitrary><author>alice@example.org</author></arbitrary>")
  end

  defp public_key_pem(keys) do
    {:ok, _private_key, public_key} = Keys.keys_from_pem(keys)
    entry = :public_key.pem_entry_encode(:RSAPublicKey, public_key)
    :public_key.pem_encode([entry])
  end
end

# end of test/pleroma/diaspora/protocol_test.exs
