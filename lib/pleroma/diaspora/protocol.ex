# Unfathomably BE
# ----------------
#
# File: diaspora/protocol.ex
#
# Purpose:
#   Encode and verify diaspora* magic envelopes and native XML entities.
#
# Responsibilities:
#   - parse XML with external entities and DTD processing disabled
#   - verify RSA-SHA256 magic-envelope signatures against discovered hCards
#   - expose a bounded map for bridge translation
#   - sign outbound public entities with a local user's RSA key
#
# This file intentionally does NOT accept unsigned payloads, implement legacy
# JSON federation, or retain decrypted transport envelopes.

defmodule Pleroma.Diaspora.Protocol do
  import SweetXml, only: [sigil_x: 2]

  alias Pleroma.Diaspora.Identities
  alias Pleroma.Keys
  alias Pleroma.User
  alias Pleroma.Web.XML

  @supported_types ~w[status_message comment like reshare retraction contact profile]
  @maximum_envelope_bytes 2_097_152
  @maximum_entity_bytes 1_048_576

  def parse_public_envelope(envelope)
      when is_binary(envelope) and byte_size(envelope) <= @maximum_envelope_bytes do
    with {:ok, doc} <- XML.parse_document(envelope),
         data64 when is_binary(data64) <- XML.string_from_xpath("//*[local-name()='data']", doc),
         encoding when encoding in ["base64url", "base64"] <-
           XML.string_from_xpath("//*[local-name()='encoding']", doc),
         "RSA-SHA256" <- XML.string_from_xpath("//*[local-name()='alg']", doc),
         signature64 when is_binary(signature64) <-
           XML.string_from_xpath("//*[local-name()='sig']", doc),
         key_id64 when is_binary(key_id64) <-
           XML.string_from_xpath("//*[local-name()='sig']/@key_id", doc),
         content_type <-
           XML.string_from_xpath("//*[local-name()='data']/@type", doc) ||
             "application/xml",
         {:ok, entity_xml} <- decode64(data64),
         true <- byte_size(entity_xml) <= @maximum_entity_bytes,
         {:ok, data} <- parse_entity(entity_xml),
         {:ok, signer_id} <- decode64(key_id64),
         true <- valid_author?(signer_id),
         {:ok, signature} <- decode64(signature64),
         true <-
           verify_signer(
             String.downcase(signer_id),
             signing_input(data64, encode64(content_type), encoding, "RSA-SHA256"),
             signature
           ),
         true <- verify_relayable_author(data, entity_xml, String.downcase(signer_id)) do
      {:ok, Map.put(data, "envelope_author", String.downcase(signer_id)), entity_xml}
    else
      _ -> {:error, :invalid_envelope}
    end
  end

  def parse_public_envelope(_envelope), do: {:error, :invalid_envelope}

  def build_public_envelope(%User{} = user, entity_xml) when is_binary(entity_xml) do
    with true <- byte_size(entity_xml) <= @maximum_entity_bytes,
         {:ok, private_key, _public_key} <- Keys.keys_from_pem(user.keys) do
      data64 = encode64(entity_xml)
      type64 = encode64("application/xml")
      encoding = "base64url"
      algorithm = "RSA-SHA256"

      signature =
        :public_key.sign(signing_input(data64, type64, encoding, algorithm), :sha256, private_key)

      {:ok,
       """
       <me:env xmlns:me="http://salmon-protocol.org/ns/magic-env">
         <me:data type="application/xml">#{data64}</me:data>
         <me:encoding>#{encoding}</me:encoding>
         <me:alg>#{algorithm}</me:alg>
         <me:sig key_id="#{encode64(Pleroma.Diaspora.diaspora_id(user))}">#{encode64(signature)}</me:sig>
       </me:env>
       """}
    else
      _ -> {:error, :could_not_sign}
    end
  rescue
    _ -> {:error, :could_not_sign}
  catch
    _, _ -> {:error, :could_not_sign}
  end

  def build_public_envelope(_user, _entity_xml), do: {:error, :could_not_sign}

  def build_private_payload(envelope, public_key_pem)
      when is_binary(envelope) and is_binary(public_key_pem) and
             byte_size(envelope) <= @maximum_envelope_bytes do
    with [public_key | _rest] <- Keys.public_keys_from_pem(public_key_pem) do
      key = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(16)
      encrypted_envelope = :crypto.crypto_one_time(:aes_256_cbc, key, iv, pad(envelope), true)

      key_json = Jason.encode!(%{"key" => Base.encode64(key), "iv" => Base.encode64(iv)})

      encrypted_key =
        :public_key.encrypt_public(key_json, public_key, rsa_pad: :rsa_pkcs1_padding)

      {:ok,
       %{
         "aes_key" => Base.encode64(encrypted_key),
         "encrypted_magic_envelope" => Base.encode64(encrypted_envelope)
       }}
    else
      _ -> {:error, :invalid_public_key}
    end
  rescue
    _ -> {:error, :could_not_encrypt}
  catch
    _, _ -> {:error, :could_not_encrypt}
  end

  def build_private_payload(_envelope, _public_key_pem), do: {:error, :could_not_encrypt}

  def decrypt_private_payload(params, %User{} = recipient) when is_map(params) do
    with encrypted_key64 when is_binary(encrypted_key64) <- params["aes_key"],
         encrypted_envelope64 when is_binary(encrypted_envelope64) <-
           params["encrypted_magic_envelope"],
         true <-
           byte_size(encrypted_key64) <= 16_384 and byte_size(encrypted_envelope64) <= 2_796_204,
         {:ok, encrypted_key} <- Base.decode64(encrypted_key64),
         {:ok, encrypted_envelope} <- Base.decode64(encrypted_envelope64),
         {:ok, private_key, _public_key} <- Keys.keys_from_pem(recipient.keys),
         key_json <-
           :public_key.decrypt_private(encrypted_key, private_key, rsa_pad: :rsa_pkcs1_padding),
         {:ok, %{"key" => key64, "iv" => iv64}} <- Jason.decode(key_json),
         {:ok, key} <- Base.decode64(key64),
         {:ok, iv} <- Base.decode64(iv64),
         true <- byte_size(key) == 32 and byte_size(iv) == 16,
         padded <- :crypto.crypto_one_time(:aes_256_cbc, key, iv, encrypted_envelope, false),
         {:ok, envelope} <- unpad(padded),
         true <- byte_size(envelope) <= @maximum_envelope_bytes do
      {:ok, envelope}
    else
      _ -> {:error, :invalid_encrypted_envelope}
    end
  rescue
    _ -> {:error, :invalid_encrypted_envelope}
  catch
    _, _ -> {:error, :invalid_encrypted_envelope}
  end

  def decrypt_private_payload(_params, _recipient), do: {:error, :invalid_encrypted_envelope}

  def parse_entity(xml) when is_binary(xml) and byte_size(xml) <= @maximum_entity_bytes do
    with {:ok, doc} <- XML.parse_document(xml),
         type when type in @supported_types <- XML.string_from_xpath("local-name(/*[1])", doc),
         author when is_binary(author) <- field(doc, "author") || field(doc, "author_id"),
         guid when is_binary(guid) <- entity_guid(type, doc, author),
         true <- valid_author?(author) and valid_guid?(guid) do
      data =
        %{
          "type" => type,
          "author" => String.downcase(author),
          "guid" => guid,
          "created_at" => field(doc, "created_at"),
          "recipient" => field(doc, "recipient"),
          "following" => field(doc, "following"),
          "sharing" => field(doc, "sharing"),
          "blocking" => field(doc, "blocking"),
          "author_signature" => field(doc, "author_signature"),
          "text" => bounded(field(doc, "text"), 300_000),
          "parent_guid" => field(doc, "parent_guid"),
          "parent_type" => field(doc, "parent_type"),
          "root_author" => field(doc, "root_author"),
          "root_guid" => field(doc, "root_guid"),
          "target_guid" => field(doc, "target_guid"),
          "target_type" => field(doc, "target_type"),
          "positive" => field(doc, "positive"),
          "public" => field(doc, "public"),
          "edited_at" => field(doc, "edited_at"),
          "full_name" => bounded(field(doc, "full_name"), 100),
          "first_name" => bounded(field(doc, "first_name"), 64),
          "last_name" => bounded(field(doc, "last_name"), 64),
          "image_url" => bounded(field(doc, "image_url"), 2_048),
          "image_url_medium" => bounded(field(doc, "image_url_medium"), 2_048),
          "image_url_small" => bounded(field(doc, "image_url_small"), 2_048),
          "bio" => bounded(field(doc, "bio"), 65_535),
          "birthday" => bounded(field(doc, "birthday"), 32),
          "location" => bounded(field(doc, "location"), 255),
          "searchable" => field(doc, "searchable"),
          "nsfw" => field(doc, "nsfw"),
          "tag_string" => bounded(field(doc, "tag_string"), 1_024)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {:ok, data}
    else
      _ -> {:error, :unsupported_entity}
    end
  end

  def parse_entity(_xml), do: {:error, :unsupported_entity}

  defp field(doc, name) do
    XML.string_from_xpath("/*[1]/*[local-name()='#{name}']", doc)
  end

  defp verify_signer(identifier, input, signature) do
    with {:ok, signer} <- Identities.resolve(identifier),
         signer_entity when not is_nil(signer_entity) <- Identities.get_by_user(signer) do
      verify(signer_entity.public_key, input, signature) or
        refresh_and_verify_signer(identifier, input, signature)
    else
      _ -> false
    end
  end

  defp refresh_and_verify_signer(identifier, input, signature) do
    with {:ok, signer} <- Identities.refresh(identifier),
         signer_entity when not is_nil(signer_entity) <- Identities.get_by_user(signer) do
      verify(signer_entity.public_key, input, signature)
    else
      _ -> false
    end
  end

  defp verify(pem, input, signature) do
    Keys.public_keys_from_pem(pem)
    |> Enum.any?(fn public_key ->
      :public_key.verify(input, :sha256, signature, public_key)
    end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp verify_relayable_author(%{"author" => author}, _xml, author), do: true

  defp verify_relayable_author(
         %{"type" => type, "author" => author, "author_signature" => signature64},
         xml,
         _signer
       )
       when type in ["comment", "like"] and is_binary(signature64) do
    with {:ok, signature} <- Base.decode64(String.replace(signature64, ~r/\s+/, "")),
         {:ok, input} <- relayable_signature_input(xml) do
      verify_signer(author, input, signature)
    else
      _ -> false
    end
  end

  defp verify_relayable_author(_data, _xml, _signer), do: false

  defp relayable_signature_input(xml) do
    with {:ok, doc} <- XML.parse_document(xml) do
      values =
        doc
        |> SweetXml.xpath(~x"/*[1]/*"l)
        |> Enum.flat_map(fn child ->
          case XML.string_from_xpath("local-name(.)", child) do
            "author_signature" -> []
            _name -> [XML.string_from_xpath(".", child) || ""]
          end
        end)

      {:ok, Enum.join(values, ";")}
    else
      _ -> {:error, :invalid_relayable}
    end
  end

  defp signing_input(data, type, encoding, algorithm) do
    Enum.join([data, type, encode64(encoding), encode64(algorithm)], ".")
  end

  defp encode64(value), do: Base.url_encode64(value)

  defp decode64(value) when is_binary(value) do
    case Base.url_decode64(String.replace(value, ~r/\s+/, ""), padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.url_decode64(value)
    end
  end

  defp valid_author?(value),
    do: byte_size(value) <= 320 and Regex.match?(~r/\A[^@\s\/]+@[^@\s\/]+\z/, value)

  defp valid_guid?(value),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_@.:-]{14,253}[A-Za-z0-9]\z/, value)

  defp bounded(value, limit) when is_binary(value) and byte_size(value) <= limit, do: value
  defp bounded(_value, _limit), do: nil

  defp entity_guid("contact", doc, author) do
    recipient = field(doc, "recipient") || ""

    :sha256
    |> :crypto.hash("contact:#{author}:#{recipient}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp entity_guid("profile", _doc, author) do
    :sha256
    |> :crypto.hash("profile:#{author}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp entity_guid(_type, doc, _author), do: field(doc, "guid")

  defp pad(value) do
    padding_length = 16 - rem(byte_size(value), 16)
    value <> :binary.copy(<<padding_length>>, padding_length)
  end

  defp unpad(value) when is_binary(value) and byte_size(value) > 0 do
    padding_length = :binary.last(value)

    if padding_length in 1..16 and byte_size(value) >= padding_length do
      content_length = byte_size(value) - padding_length
      <<content::binary-size(^content_length), padding::binary-size(^padding_length)>> = value

      if padding == :binary.copy(<<padding_length>>, padding_length) do
        {:ok, content}
      else
        {:error, :invalid_padding}
      end
    else
      {:error, :invalid_padding}
    end
  end

  defp unpad(_value), do: {:error, :invalid_padding}
end

# end of diaspora/protocol.ex
