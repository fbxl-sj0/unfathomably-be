# Unfathomably BE
# ----------------
#
# File: atproto/dpop.ex
#
# Purpose:
#   Sign and send AT Protocol OAuth requests bound to a per-session DPoP key.
#
# Responsibilities:
#   - generate private ES256 keys for OAuth sessions
#   - create unique RFC 9449 proof JWTs for HTTP requests
#   - bind resource requests to their access token
#   - accept and rotate mandatory server DPoP nonces
#
# This file intentionally does NOT discover OAuth servers, persist keys, or
# decide which repository permissions a user should grant.

defmodule Pleroma.ATProto.DPoP do
  alias Pleroma.HTTP

  @maximum_key_bytes 8_192

  @doc "Generates a serialized private P-256 key for one OAuth session."
  def generate_key do
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_fields, private_map} = JOSE.JWK.to_map(key)
    {:ok, Jason.encode!(private_map)}
  rescue
    _error -> {:error, :dpop_key_generation_failed}
  end

  @doc "Creates one unique DPoP proof for the exact HTTP method and URL."
  def proof(method, url, key_json, nonce \\ nil, access_token \\ nil)

  def proof(method, url, key_json, nonce, access_token)
      when is_binary(url) and is_binary(key_json) and
             byte_size(key_json) <= @maximum_key_bytes do
    with {:ok, private_map} <- Jason.decode(key_json),
         %JOSE.JWK{} = key <- JOSE.JWK.from_map(private_map),
         {_fields, public_map} <- key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map() do
      claims =
        %{
          "htm" => method |> to_string() |> String.upcase(),
          "htu" => normalized_htu(url),
          "iat" => System.system_time(:second),
          "jti" => random_token()
        }
        |> maybe_put("nonce", nonce)
        |> maybe_put_ath(access_token)

      signed =
        JOSE.JWT.sign(
          key,
          %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public_map},
          claims
        )

      {_jws, compact} = JOSE.JWS.compact(signed)
      {:ok, compact}
    else
      _error -> {:error, :invalid_dpop_key}
    end
  rescue
    _error -> {:error, :dpop_signing_failed}
  end

  def proof(_method, _url, _key_json, _nonce, _access_token),
    do: {:error, :invalid_dpop_key}

  @doc """
  Sends a DPoP request and retries once when a server rotates its nonce.

  AT Protocol requires a nonce on every response to a DPoP request. Rejecting
  a response without it prevents an OAuth token from silently degrading to a
  bearer token when a PDS or authorization proxy is misconfigured.
  """
  def request(method, url, body, headers, access_token, key_json, nonce, nonce_callback, options)
      when is_function(nonce_callback, 1) do
    do_request(
      method,
      url,
      body,
      headers,
      access_token,
      key_json,
      nonce,
      nonce_callback,
      options,
      false
    )
  end

  defp do_request(
         method,
         url,
         body,
         headers,
         access_token,
         key_json,
         nonce,
         nonce_callback,
         options,
         retried?
       ) do
    with {:ok, proof} <- proof(method, url, key_json, nonce, access_token),
         request_headers <-
           [{"dpop", proof} | maybe_authorization(headers, access_token)],
         {:ok, response} <- HTTP.request(method, url, body, request_headers, options),
         response_nonce when is_binary(response_nonce) <-
           response_header(response.headers, "dpop-nonce") do
      nonce_callback.(response_nonce)

      if not retried? and response.status in [400, 401] and response_nonce != nonce do
        do_request(
          method,
          url,
          body,
          headers,
          access_token,
          key_json,
          response_nonce,
          nonce_callback,
          options,
          true
        )
      else
        {:ok, response, response_nonce}
      end
    else
      nil -> {:error, :missing_dpop_nonce}
      error -> error
    end
  end

  defp normalized_htu(url) do
    url
    |> URI.parse()
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp maybe_authorization(headers, token) when is_binary(token),
    do: [{"authorization", "DPoP #{token}"} | headers]

  defp maybe_authorization(headers, _token), do: headers

  defp maybe_put(map, _key, value) when not is_binary(value) or value == "", do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_ath(claims, token) when is_binary(token) do
    Map.put(
      claims,
      "ath",
      token |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)
    )
  end

  defp maybe_put_ath(claims, _token), do: claims

  defp response_header(headers, name) when is_list(headers) do
    name = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: value

      _header ->
        nil
    end)
  end

  defp response_header(_headers, _name), do: nil

  defp random_token do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end

# end of atproto/dpop.ex
