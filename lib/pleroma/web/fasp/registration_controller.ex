# Unfathomably FASP registration API
# -----------------------------------
#
# File: registration_controller.ex
#
# Purpose:
#   Receive signed FASP trust-on-first-contact registration requests.
#
# Responsibilities:
#   - require a valid content digest and RFC 9421 Ed25519 signature
#   - bind the signature key ID to the provider's submitted server identifier
#   - create an inert pending registration
#   - return the server identity and administrator completion URI
#
# This file intentionally does not approve providers or expose capabilities.

defmodule Pleroma.Web.FASP.RegistrationController do
  use Pleroma.Web, :controller

  alias Pleroma.FASP.Crypto
  alias Pleroma.FASP.Registration
  alias Pleroma.HTTP.MessageSignatures
  alias Pleroma.Web.Plugs.RateLimiter

  plug(RateLimiter, name: :fasp_registration)

  def create(conn, params) do
    if Registration.enabled?() do
      register(conn, params)
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "FASP registration is not enabled"})
    end
  end

  defp register(conn, params) do
    with {:ok, normalized} <- Registration.normalize(params),
         {:ok, key_id} <- MessageSignatures.key_id(conn),
         true <- key_id == normalized.provider_server_id,
         :ok <-
           MessageSignatures.validate_result(
             conn,
             {:ed25519, normalized.provider_public_key}
           ),
         {:ok, registration} <- Registration.create(normalized) do
      signed_registration_response(conn, registration)
    else
      false -> registration_error(conn, :invalid_signature)
      {:error, reason} -> registration_error(conn, reason)
    end
  end

  defp signed_registration_response(conn, registration) do
    payload = %{
      faspId: registration.fasp_id,
      publicKey: Base.encode64(registration.local_public_key),
      registrationCompletionUri: Registration.completion_uri(registration)
    }

    body = Jason.encode!(payload)
    content_digest = MessageSignatures.content_digest(body)

    with {:ok, private_key} <-
           Crypto.decrypt_private_key(registration.local_private_key_ciphertext),
         {:ok, signature_headers} <-
           MessageSignatures.sign_response_ed25519(
             private_key,
             registration.fasp_id,
             201,
             %{"content-digest" => content_digest}
           ) do
      conn =
        Enum.reduce(signature_headers, conn, fn {name, value}, conn ->
          put_resp_header(conn, String.downcase(name), value)
        end)

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-digest", content_digest)
      |> send_resp(:created, body)
    else
      _ -> registration_error(conn, :response_signature_failed)
    end
  end

  defp registration_error(conn, reason)
       when reason in [
              :invalid_signature,
              :malformed_signature,
              :missing_key_id,
              :missing_created,
              :missing_content_digest,
              :invalid_content_digest,
              :expired,
              :created_in_future,
              :unsupported_algorithm,
              :unsupported_components
            ] do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "The FASP registration signature could not be verified"})
  end

  defp registration_error(conn, :registration_conflict) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "A different FASP identity is already registered for this base URL"})
  end

  defp registration_error(conn, :rejected) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "This FASP registration was rejected by an administrator"})
  end

  defp registration_error(conn, :too_many_pending) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: "The server is not accepting more pending FASP registrations"})
  end

  defp registration_error(conn, :response_signature_failed) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "The server could not sign the FASP registration response"})
  end

  defp registration_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "The FASP registration request is invalid"})
  end
end

# end of registration_controller.ex
