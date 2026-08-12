# Unfathomably ActivityPub identity proofs
# -----------------------------------------
#
# File: identity_proof.ex
#
# Purpose:
#   Verify FEP-c390 identity statements attached to remote actors.
#
# Responsibilities:
#   - enforce the FEP-c390 actor and DID binding rules
#   - implement the W3C eddsa-jcs-2022 verification algorithm
#   - bound untrusted JSON before canonicalization
#   - return original verified statements for client presentation
#
# This file intentionally does not authorize account migration, merge users,
# generate proofs, resolve arbitrary DID documents, or verify other suites.

defmodule Pleroma.Web.ActivityPub.IdentityProof do
  alias Pleroma.Keys

  @statement_type "VerifiableIdentityStatement"
  @proof_type "DataIntegrityProof"
  @cryptosuite "eddsa-jcs-2022"
  @proof_purpose "assertionMethod"

  @maximum_attachments_scanned 64
  @maximum_proofs 8
  @maximum_depth 8
  @maximum_nodes 256
  @maximum_map_entries 32
  @maximum_list_items 32
  @maximum_key_bytes 256
  @maximum_string_bytes 4_096
  @maximum_statement_bytes 16_384
  @maximum_uri_bytes 2_048
  @ed25519_signature_bytes 64

  @type verification_error :: :invalid_identity_proof

  @doc "Extracts original, successfully verified FEP-c390 statements from an actor."
  @spec extract(map()) :: [map()]
  def extract(%{"id" => actor_id} = actor) when is_binary(actor_id) do
    actor
    |> Map.get("attachment", [])
    |> List.wrap()
    |> Enum.take(@maximum_attachments_scanned)
    |> Enum.reduce_while([], fn attachment, proofs ->
      if length(proofs) >= @maximum_proofs do
        {:halt, proofs}
      else
        case verify(attachment, actor_id) do
          {:ok, statement} -> {:cont, [statement | proofs]}
          {:error, :invalid_identity_proof} -> {:cont, proofs}
        end
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1["subject"])
  end

  def extract(_actor), do: []

  @doc "Verifies one FEP-c390 eddsa-jcs-2022 identity statement."
  @spec verify(term(), String.t()) :: {:ok, map()} | {:error, verification_error()}
  def verify(
        %{
          "type" => @statement_type,
          "subject" => subject,
          "alsoKnownAs" => actor_id,
          "proof" =>
            %{
              "type" => @proof_type,
              "cryptosuite" => @cryptosuite,
              "created" => created,
              "verificationMethod" => subject,
              "proofPurpose" => @proof_purpose,
              "proofValue" => proof_value
            } = proof
        } = statement,
        actor_id
      )
      when is_binary(subject) and is_binary(actor_id) and is_binary(created) and
             is_binary(proof_value) do
    with true <- byte_size(actor_id) <= @maximum_uri_bytes,
         true <- byte_size(subject) <= @maximum_uri_bytes,
         true <- bounded_statement?(statement),
         {:ok, _created_at, _offset} <- DateTime.from_iso8601(created),
         {:ok, public_key} <- Keys.ed25519_public_key_from_did_key(subject),
         {:ok, signature} <-
           Keys.decode_multibase_base58btc(proof_value, @ed25519_signature_bytes),
         true <- byte_size(signature) == @ed25519_signature_bytes,
         {:ok, hash_data} <- signature_data(statement, proof),
         true <- verify_ed25519(hash_data, signature, public_key) do
      {:ok, statement}
    else
      _ -> {:error, :invalid_identity_proof}
    end
  end

  def verify(_statement, _actor_id), do: {:error, :invalid_identity_proof}

  @doc "Checks whether a previously verified statement remains safe to persist."
  @spec storable?(term()) :: boolean()
  def storable?(
        %{
          "type" => @statement_type,
          "subject" => subject,
          "alsoKnownAs" => actor_id,
          "proof" => %{
            "type" => @proof_type,
            "cryptosuite" => @cryptosuite,
            "created" => created,
            "verificationMethod" => subject,
            "proofPurpose" => @proof_purpose,
            "proofValue" => proof_value
          }
        } = statement
      )
      when is_binary(subject) and is_binary(actor_id) and is_binary(created) and
             is_binary(proof_value) do
    bounded_statement?(statement)
  end

  def storable?(_statement), do: false

  defp signature_data(statement, proof) do
    unsecured_document = Map.delete(statement, "proof")
    proof_config = Map.delete(proof, "proofValue")

    with {:ok, unsecured_document} <- apply_proof_context(unsecured_document, proof_config),
         {:ok, canonical_document} <- canonicalize(unsecured_document),
         {:ok, canonical_proof_config} <- canonicalize(proof_config) do
      document_hash = :crypto.hash(:sha256, canonical_document)
      proof_config_hash = :crypto.hash(:sha256, canonical_proof_config)
      {:ok, proof_config_hash <> document_hash}
    end
  end

  defp apply_proof_context(unsecured_document, proof_config) do
    case Map.fetch(proof_config, "@context") do
      :error ->
        {:ok, unsecured_document}

      {:ok, proof_context} ->
        if context_prefix?(unsecured_document["@context"], proof_context) do
          {:ok, Map.put(unsecured_document, "@context", proof_context)}
        else
          {:error, :invalid_identity_proof}
        end
    end
  end

  defp context_prefix?(document_context, proof_context) do
    document_values = context_values(document_context)
    proof_values = context_values(proof_context)

    proof_values != [] and
      Enum.take(document_values, length(proof_values)) == proof_values
  end

  defp context_values(value) when is_binary(value), do: [value]

  defp context_values(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) or is_map(&1))), do: values, else: []
  end

  defp context_values(_value), do: []

  defp canonicalize(value) do
    {:ok, Jcs.encode(value)}
  rescue
    _ -> {:error, :invalid_identity_proof}
  catch
    _, _ -> {:error, :invalid_identity_proof}
  end

  defp verify_ed25519(hash_data, signature, public_key) do
    :crypto.verify(:eddsa, :none, hash_data, signature, [public_key, :ed25519])
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp bounded_statement?(statement) do
    with {:ok, _remaining_nodes} <- bounded_json(statement, 0, @maximum_nodes),
         {:ok, encoded} <- Jason.encode(statement) do
      byte_size(encoded) <= @maximum_statement_bytes
    else
      _ -> false
    end
  end

  defp bounded_json(_value, depth, _remaining_nodes) when depth > @maximum_depth,
    do: {:error, :too_deep}

  defp bounded_json(_value, _depth, remaining_nodes) when remaining_nodes <= 0,
    do: {:error, :too_many_nodes}

  defp bounded_json(value, _depth, remaining_nodes)
       when is_binary(value) and byte_size(value) <= @maximum_string_bytes,
       do: {:ok, remaining_nodes - 1}

  defp bounded_json(value, _depth, remaining_nodes)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, remaining_nodes - 1}

  defp bounded_json(values, depth, remaining_nodes)
       when is_list(values) and length(values) <= @maximum_list_items do
    Enum.reduce_while(values, {:ok, remaining_nodes - 1}, fn value, {:ok, nodes_left} ->
      case bounded_json(value, depth + 1, nodes_left) do
        {:ok, _nodes_left} = result -> {:cont, result}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp bounded_json(value, depth, remaining_nodes)
       when is_map(value) and map_size(value) <= @maximum_map_entries do
    Enum.reduce_while(value, {:ok, remaining_nodes - 1}, fn
      {key, child}, {:ok, nodes_left}
      when is_binary(key) and byte_size(key) <= @maximum_key_bytes ->
        case bounded_json(child, depth + 1, nodes_left) do
          {:ok, _nodes_left} = result -> {:cont, result}
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _accumulator ->
        {:halt, {:error, :invalid_key}}
    end)
  end

  defp bounded_json(_value, _depth, _remaining_nodes), do: {:error, :invalid_json}
end

# end of lib/pleroma/web/activity_pub/identity_proof.ex
