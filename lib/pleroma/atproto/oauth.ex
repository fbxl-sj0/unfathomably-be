# Unfathomably BE
# ----------------
#
# File: atproto/oauth.ex
#
# Purpose:
#   Implement the server-side AT Protocol OAuth authorization flow.
#
# Responsibilities:
#   - resolve and bind the expected DID, handle, PDS, and authorization server
#   - validate protected-resource and authorization-server metadata
#   - use PAR, PKCE, and a per-session DPoP key
#   - consume one-use callback state and exchange authorization codes
#   - refresh DPoP-bound OAuth sessions
#
# This file intentionally does NOT implement a firehose, retain account
# passwords, expose tokens to browsers, or grant account-management/DM access.

defmodule Pleroma.ATProto.OAuth do
  import Ecto.Query

  alias Pleroma.ATProto.Client
  alias Pleroma.ATProto.Crypto
  alias Pleroma.ATProto.DPoP
  alias Pleroma.ATProto.OAuthRequest
  alias Pleroma.ATProto.URL
  alias Pleroma.Config
  alias Pleroma.HTTP
  alias Pleroma.Repo
  alias Pleroma.User

  @maximum_metadata_bytes 1_048_576
  @maximum_token_bytes 16_384
  @request_lifetime_seconds 600
  @default_scope Enum.join(
                   [
                     "atproto",
                     "repo:app.bsky.feed.post",
                     "repo:app.bsky.feed.like",
                     "repo:app.bsky.feed.repost",
                     "repo:app.bsky.graph.follow",
                     "blob:image/*",
                     "blob:video/*"
                   ],
                   " "
                 )

  @doc "Returns the public metadata document fetched by authorization servers."
  def client_metadata do
    %{
      "client_id" => client_id(),
      "client_name" => "Unfathomably",
      "client_uri" => external_origin(),
      "application_type" => "web",
      "grant_types" => ["authorization_code", "refresh_token"],
      "scope" => scope(),
      "response_types" => ["code"],
      "redirect_uris" => [redirect_uri()],
      "token_endpoint_auth_method" => "none",
      "dpop_bound_access_tokens" => true
    }
  end

  @doc "Starts a bounded OAuth authorization for one local user."
  def start(%User{local: true} = user, identifier) when is_binary(identifier) do
    identifier = identifier |> String.trim() |> String.trim_leading("@") |> String.downcase()

    with {:ok, %{did: did, handle: handle}} <- resolve_identity(identifier),
         {:ok, pds_url} <- Client.pds_url(did),
         {:ok, metadata} <- discover(pds_url),
         {:ok, key_json} <- DPoP.generate_key(),
         verifier <- random_token(48),
         challenge <-
           verifier |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false),
         state <- random_token(32),
         {:ok, verifier_ciphertext} <- Crypto.encrypt(verifier),
         {:ok, key_ciphertext} <- Crypto.encrypt(key_json),
         {:ok, request_uri, expires_in, authorization_nonce} <-
           pushed_authorization_request(
             metadata,
             identifier,
             state,
             challenge,
             key_json
           ),
         {:ok, _request} <-
           persist_request(%{
             state: state,
             user_id: user.id,
             did: did,
             handle: handle,
             pds_url: pds_url,
             issuer: metadata.issuer,
             authorization_endpoint: metadata.authorization_endpoint,
             token_endpoint: metadata.token_endpoint,
             scope: scope(),
             pkce_verifier_ciphertext: verifier_ciphertext,
             dpop_key_ciphertext: key_ciphertext,
             authorization_dpop_nonce: authorization_nonce,
             expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
           }) do
      query = URI.encode_query(%{"client_id" => client_id(), "request_uri" => request_uri})
      {:ok, %{authorization_url: metadata.authorization_endpoint <> "?" <> query}}
    else
      _error = error -> normalize_error(error)
    end
  end

  def start(_user, _identifier), do: {:error, :invalid_identifier}

  @doc "Consumes an OAuth callback and returns encrypted-link input material."
  def finish(%{"state" => state, "code" => code, "iss" => issuer})
      when is_binary(state) and is_binary(code) and is_binary(issuer) and
             byte_size(state) <= 128 and byte_size(code) <= 4_096 and
             byte_size(issuer) <= 2_048 do
    with %OAuthRequest{} = request <- Repo.get(OAuthRequest, state),
         true <- DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt,
         true <- secure_equal?(request.issuer, issuer),
         {:ok, request} <- Repo.delete(request),
         {:ok, verifier} <- Crypto.decrypt(request.pkce_verifier_ciphertext),
         {:ok, key_json} <- Crypto.decrypt(request.dpop_key_ciphertext),
         {:ok, token} <- exchange_code(request, code, verifier, key_json),
         true <- String.downcase(to_string(token["token_type"])) == "dpop",
         true <- token["sub"] == request.did,
         true <- granted_scope?(token["scope"], request.scope),
         expected_pds_url = request.pds_url,
         {:ok, ^expected_pds_url} <- Client.pds_url(request.did),
         {:ok, metadata} <- discover(request.pds_url),
         true <- secure_equal?(metadata.issuer, request.issuer),
         {:ok, handle} <- Client.verified_handle(request.did, request.handle),
         access_token when is_binary(access_token) <- token["access_token"],
         refresh_token when is_binary(refresh_token) <- token["refresh_token"] do
      {:ok,
       %{
         user_id: request.user_id,
         did: request.did,
         handle: handle,
         pds_url: request.pds_url,
         access_token: access_token,
         refresh_token: refresh_token,
         scope: token["scope"],
         issuer: request.issuer,
         token_endpoint: request.token_endpoint,
         dpop_key: key_json,
         authorization_dpop_nonce: token["authorization_dpop_nonce"]
       }}
    else
      nil -> {:error, :oauth_request_not_found}
      false -> {:error, :oauth_identity_mismatch}
      error -> normalize_error(error)
    end
  end

  def finish(%{"state" => state, "error" => _error}) when is_binary(state) do
    OAuthRequest |> where(state: ^state) |> Repo.delete_all()
    {:error, :oauth_denied}
  end

  def finish(_params), do: {:error, :invalid_oauth_callback}

  @doc "Refreshes one OAuth session using its existing DPoP key."
  def refresh(token_endpoint, refresh_token, key_json, nonce, nonce_callback)
      when is_binary(token_endpoint) and is_binary(refresh_token) and
             is_binary(key_json) and is_function(nonce_callback, 1) do
    form =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => client_id()
      })

    with true <- byte_size(refresh_token) <= @maximum_token_bytes,
         {:ok, response, response_nonce} <-
           DPoP.request(
             :post,
             token_endpoint,
             form,
             form_headers(),
             nil,
             key_json,
             nonce,
             nonce_callback,
             request_options()
           ),
         true <- response.status in 200..299,
         {:ok, token} <- decode_json(response.body),
         true <- String.downcase(to_string(token["token_type"])) == "dpop",
         access when is_binary(access) <- token["access_token"],
         refresh when is_binary(refresh) <- token["refresh_token"],
         true <- granted_scope?(token["scope"], scope()) do
      {:ok,
       token
       |> Map.put("access_token", access)
       |> Map.put("refresh_token", refresh)
       |> Map.put("authorization_dpop_nonce", response_nonce)}
    else
      false -> {:error, :oauth_refresh_rejected}
      error -> normalize_error(error)
    end
  end

  @doc "Discovers and validates the authorization authority for a PDS."
  def discover(pds_url) do
    protected_resource_url = pds_url <> "/.well-known/oauth-protected-resource"

    with {:ok, resource} <- fetch_metadata(protected_resource_url),
         [issuer] <- resource["authorization_servers"],
         {:ok, issuer} <- URL.normalize_origin(issuer),
         {:ok, authorization_server} <-
           fetch_metadata(issuer <> "/.well-known/oauth-authorization-server"),
         true <- authorization_server["issuer"] == issuer,
         true <- "code" in List.wrap(authorization_server["response_types_supported"]),
         true <-
           Enum.all?(["authorization_code", "refresh_token"], fn grant ->
             grant in List.wrap(authorization_server["grant_types_supported"])
           end),
         true <- "S256" in List.wrap(authorization_server["code_challenge_methods_supported"]),
         true <-
           "none" in List.wrap(authorization_server["token_endpoint_auth_methods_supported"]),
         true <- "atproto" in List.wrap(authorization_server["scopes_supported"]),
         true <- authorization_server["authorization_response_iss_parameter_supported"] == true,
         true <- authorization_server["require_pushed_authorization_requests"] == true,
         true <- authorization_server["client_id_metadata_document_supported"] == true,
         true <- "ES256" in List.wrap(authorization_server["dpop_signing_alg_values_supported"]),
         {:ok, authorization_endpoint} <-
           safe_endpoint(authorization_server["authorization_endpoint"]),
         {:ok, token_endpoint} <- safe_endpoint(authorization_server["token_endpoint"]),
         {:ok, par_endpoint} <-
           safe_endpoint(authorization_server["pushed_authorization_request_endpoint"]) do
      {:ok,
       %{
         issuer: issuer,
         authorization_endpoint: authorization_endpoint,
         token_endpoint: token_endpoint,
         par_endpoint: par_endpoint
       }}
    else
      _error -> {:error, :invalid_oauth_server}
    end
  end

  defp pushed_authorization_request(metadata, login_hint, state, challenge, key_json) do
    form =
      URI.encode_query(%{
        "client_id" => client_id(),
        "response_type" => "code",
        "redirect_uri" => redirect_uri(),
        "scope" => scope(),
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "login_hint" => login_hint
      })

    with {:ok, response, nonce} <-
           DPoP.request(
             :post,
             metadata.par_endpoint,
             form,
             form_headers(),
             nil,
             key_json,
             nil,
             fn _nonce -> :ok end,
             request_options()
           ),
         true <- response.status in 200..299,
         {:ok, data} <- decode_json(response.body),
         request_uri when is_binary(request_uri) <- data["request_uri"],
         true <- byte_size(request_uri) <= 2_048 do
      expires_in =
        case data["expires_in"] do
          value when is_integer(value) -> value |> max(60) |> min(@request_lifetime_seconds)
          _value -> @request_lifetime_seconds
        end

      {:ok, request_uri, expires_in, nonce}
    else
      false -> {:error, :oauth_authorization_rejected}
      error -> normalize_error(error)
    end
  end

  defp exchange_code(request, code, verifier, key_json) do
    form =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri(),
        "client_id" => client_id(),
        "code_verifier" => verifier
      })

    with {:ok, response, nonce} <-
           DPoP.request(
             :post,
             request.token_endpoint,
             form,
             form_headers(),
             nil,
             key_json,
             request.authorization_dpop_nonce,
             fn _nonce -> :ok end,
             request_options()
           ),
         true <- response.status in 200..299,
         {:ok, token} <- decode_json(response.body) do
      {:ok, Map.put(token, "authorization_dpop_nonce", nonce)}
    else
      false -> {:error, :oauth_token_rejected}
      error -> normalize_error(error)
    end
  end

  defp resolve_identity("did:" <> _rest = did) do
    with {:ok, document} <- Client.did_document(did),
         handle when is_binary(handle) <-
           document
           |> Map.get("alsoKnownAs", [])
           |> List.wrap()
           |> Enum.find_value(fn
             "at://" <> handle -> handle
             _alias -> nil
           end),
         {:ok, handle} <- Client.verified_handle(did, handle) do
      {:ok, %{did: did, handle: handle}}
    else
      _error -> {:error, :identity_not_found}
    end
  end

  defp resolve_identity(handle) do
    with {:ok, %{"did" => did}} <- Client.resolve_handle(handle),
         {:ok, handle} <- Client.verified_handle(did, handle) do
      {:ok, %{did: did, handle: handle}}
    else
      _error -> {:error, :identity_not_found}
    end
  end

  defp persist_request(attrs) do
    now = DateTime.utc_now()

    OAuthRequest
    |> where([request], request.expires_at <= ^now or request.user_id == ^attrs.user_id)
    |> Repo.delete_all()

    %OAuthRequest{} |> OAuthRequest.changeset(attrs) |> Repo.insert()
  end

  defp fetch_metadata(url) do
    with true <- URL.public_https_url?(url),
         {:ok, %{status: 200, body: body, headers: headers}} <-
           HTTP.get(url, [{"accept", "application/json"}], request_options()),
         true <- json_content_type?(headers),
         {:ok, data} <- decode_json(body) do
      {:ok, data}
    else
      _error -> {:error, :invalid_oauth_metadata}
    end
  end

  defp safe_endpoint(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) ->
        if URL.public_https_url?(url), do: {:ok, url}, else: {:error, :unsafe_oauth_endpoint}

      _uri ->
        {:error, :unsafe_oauth_endpoint}
    end
  end

  defp safe_endpoint(_url), do: {:error, :unsafe_oauth_endpoint}

  defp decode_json(body) when is_binary(body) and byte_size(body) <= @maximum_metadata_bytes do
    case Jason.decode(body) do
      {:ok, %{} = data} -> {:ok, data}
      _error -> {:error, :invalid_oauth_response}
    end
  end

  defp decode_json(_body), do: {:error, :oauth_response_too_large}

  defp json_content_type?(headers) do
    Enum.any?(List.wrap(headers), fn
      {key, value} when is_binary(key) and is_binary(value) ->
        String.downcase(key) == "content-type" and
          String.starts_with?(String.downcase(value), "application/json")

      _header ->
        false
    end)
  end

  defp granted_scope?(granted, requested) when is_binary(granted) and is_binary(requested) do
    requested
    |> String.split()
    |> MapSet.new()
    |> MapSet.subset?(granted |> String.split() |> MapSet.new())
  end

  defp granted_scope?(_granted, _requested), do: false

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp client_id, do: external_origin() <> "/api/v1/atproto/oauth/client-metadata.json"
  defp redirect_uri, do: external_origin() <> "/api/v1/atproto/oauth/callback"

  defp external_origin do
    Pleroma.Web.Endpoint.url()
    |> URL.normalize_origin()
    |> case do
      {:ok, origin} -> origin
      _error -> "https://localhost"
    end
  end

  defp scope do
    Config.get([Pleroma.ATProto, :oauth_scope], @default_scope)
  end

  defp form_headers do
    [
      {"accept", "application/json"},
      {"content-type", "application/x-www-form-urlencoded"}
    ]
  end

  defp request_options do
    [
      pool: :federation,
      recv_timeout: Config.get([Pleroma.ATProto, :request_timeout_ms], 10_000)
    ]
  end

  defp random_token(bytes) do
    bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp normalize_error({:error, _reason} = error), do: error
  defp normalize_error(_error), do: {:error, :oauth_failed}
end

# end of atproto/oauth.ex
