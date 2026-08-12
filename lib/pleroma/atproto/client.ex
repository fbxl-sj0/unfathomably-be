# Unfathomably BE
# ----------------
#
# File: atproto/client.ex
#
# Purpose:
#   Provide bounded XRPC access to AT Protocol AppViews and PDS instances.
#
# Responsibilities:
#   - resolve handles and DIDs without subscribing to a network firehose
#   - read profiles, author feeds, threads, quotes, likes, and reposts
#   - create and delete records through an authorized PDS session
#   - reject oversized or malformed JSON responses
#
# This file intentionally does NOT implement a relay, CAR repository, Merkle
# Search Tree, Lexicon server, or OAuth authorization workflow.

defmodule Pleroma.ATProto.Client do
  alias Pleroma.ATProto.URL
  alias Pleroma.ATProto.DPoP
  alias Pleroma.Config
  alias Pleroma.HTTP

  @json_headers [{"accept", "application/json"}]
  @max_response_bytes 4_194_304
  @max_password_bytes 1_024
  @max_admin_password_bytes 4_096
  @max_blob_bytes 50_000_000

  def resolve_handle(handle) when is_binary(handle) do
    handle = String.downcase(String.trim(handle))

    if Pleroma.ATProto.Validation.valid_handle?(handle) do
      public_get("com.atproto.identity.resolveHandle", %{"handle" => handle})
    else
      {:error, :invalid_handle}
    end
  end

  def get_profile(actor),
    do: public_get("app.bsky.actor.getProfile", %{"actor" => actor})

  def get_author_feed(actor, cursor \\ nil, limit \\ 50) do
    params =
      %{"actor" => actor, "filter" => "posts_with_replies", "limit" => clamp(limit, 1, 100)}
      |> maybe_put("cursor", cursor)

    public_get("app.bsky.feed.getAuthorFeed", params)
  end

  def get_post_thread(uri, depth \\ 6, parent_height \\ 6) do
    public_get("app.bsky.feed.getPostThread", %{
      "uri" => uri,
      "depth" => clamp(depth, 0, 1000),
      "parentHeight" => clamp(parent_height, 0, 1000)
    })
  end

  def get_quotes(uri, cursor \\ nil, limit \\ 50) do
    %{"uri" => uri, "limit" => clamp(limit, 1, 100)}
    |> maybe_put("cursor", cursor)
    |> then(&public_get("app.bsky.feed.getQuotes", &1))
  end

  def get_likes(uri, cid, cursor \\ nil, limit \\ 50) do
    %{"uri" => uri, "cid" => cid, "limit" => clamp(limit, 1, 100)}
    |> maybe_put("cursor", cursor)
    |> then(&public_get("app.bsky.feed.getLikes", &1))
  end

  def get_reposted_by(uri, cursor \\ nil, limit \\ 50) do
    %{"uri" => uri, "limit" => clamp(limit, 1, 100)}
    |> maybe_put("cursor", cursor)
    |> then(&public_get("app.bsky.feed.getRepostedBy", &1))
  end

  def did_document("did:plc:" <> _rest = did) do
    did
    |> then(&get_json("https://plc.directory/#{URI.encode(&1)}"))
    |> validate_did_document(did)
  end

  def did_document("did:web:" <> encoded) do
    with {:ok, url} <- did_web_url(encoded) do
      url |> get_json() |> validate_did_document("did:web:#{encoded}")
    end
  end

  def did_document(_did), do: {:error, :unsupported_did_method}

  def pds_url(did) do
    with {:ok, %{} = document} <- did_document(did),
         %{} = service <-
           document
           |> Map.get("service", [])
           |> List.wrap()
           |> Enum.find(fn
             %{} = service ->
               service["id"] in ["#atproto_pds", "#{did}#atproto_pds"] and
                 service["type"] == "AtprotoPersonalDataServer"

             _service ->
               false
           end),
         endpoint when is_binary(endpoint) <- service["serviceEndpoint"],
         {:ok, origin} <- URL.normalize_origin(endpoint) do
      {:ok, origin}
    else
      _ -> {:error, :pds_not_found}
    end
  end

  def verified_handle(did, handle) when is_binary(did) and is_binary(handle) do
    handle = String.downcase(String.trim(handle))

    with true <- Pleroma.ATProto.Validation.valid_did?(did),
         true <- Pleroma.ATProto.Validation.valid_handle?(handle),
         {:ok, %{} = document} <- did_document(did),
         true <- "at://#{handle}" in List.wrap(document["alsoKnownAs"]),
         {:ok, %{"did" => ^did}} <- resolve_handle(handle) do
      {:ok, handle}
    else
      _reason -> {:error, :unverified_handle}
    end
  end

  def verified_handle(_did, _handle), do: {:error, :unverified_handle}

  def create_session(pds_url, identifier, password)
      when is_binary(identifier) and is_binary(password) and
             byte_size(identifier) <= 2_048 and byte_size(password) in 1..@max_password_bytes do
    pds_post(pds_url, "com.atproto.server.createSession", %{
      "identifier" => identifier,
      "password" => password
    })
  end

  def create_session(_pds_url, _identifier, _password), do: {:error, :invalid_credentials}

  def refresh_session(pds_url, refresh_token) when is_binary(refresh_token) do
    pds_post(pds_url, "com.atproto.server.refreshSession", %{}, refresh_token)
  end

  def create_invite_code(pds_url, admin_password)
      when is_binary(admin_password) and byte_size(admin_password) in 1..@max_admin_password_bytes do
    pds_post(
      pds_url,
      "com.atproto.server.createInviteCode",
      %{"useCount" => 1},
      {:basic, "admin", admin_password}
    )
  end

  def create_invite_code(_pds_url, _admin_password), do: {:error, :invalid_admin_credentials}

  def create_account(pds_url, handle, email, password, invite_code)
      when is_binary(handle) and is_binary(email) and is_binary(password) and
             is_binary(invite_code) and byte_size(password) in 1..@max_password_bytes do
    pds_post(pds_url, "com.atproto.server.createAccount", %{
      "email" => email,
      "handle" => handle,
      "password" => password,
      "inviteCode" => invite_code
    })
  end

  def create_account(_pds_url, _handle, _email, _password, _invite_code),
    do: {:error, :invalid_account}

  def create_record(pds_url, access_token, repo, collection, record, rkey \\ nil) do
    body =
      %{
        "repo" => repo,
        "collection" => collection,
        "record" => record,
        "validate" => true
      }
      |> maybe_put("rkey", rkey)

    pds_post(pds_url, "com.atproto.repo.createRecord", body, access_token)
  end

  def put_record(pds_url, access_token, repo, collection, rkey, record) do
    pds_post(
      pds_url,
      "com.atproto.repo.putRecord",
      %{
        "repo" => repo,
        "collection" => collection,
        "rkey" => rkey,
        "record" => record,
        "validate" => true
      },
      access_token
    )
  end

  def delete_record(pds_url, access_token, repo, collection, rkey) do
    pds_post(
      pds_url,
      "com.atproto.repo.deleteRecord",
      %{"repo" => repo, "collection" => collection, "rkey" => rkey},
      access_token
    )
  end

  def upload_blob(pds_url, authorization, body, mime_type)
      when is_binary(body) and byte_size(body) in 1..@max_blob_bytes and
             is_binary(mime_type) do
    with {:ok, origin} <- URL.normalize_origin(pds_url),
         url = origin <> "/xrpc/com.atproto.repo.uploadBlob",
         headers = [{"content-type", mime_type} | @json_headers],
         {:ok, %{status: status, body: response_body}} when status in 200..299 <-
           perform_request(
             :post,
             url,
             body,
             headers,
             authorization,
             Keyword.put(request_options(), :pool, :upload)
           ),
         {:ok, data} <- decode_body(response_body) do
      {:ok, data}
    else
      {:ok, %{status: status, body: response_body}} ->
        {:error, {:http, status, decode_error(response_body)}}

      error ->
        error
    end
  rescue
    _error -> {:error, :invalid_response}
  catch
    _, _ -> {:error, :invalid_response}
  end

  def upload_blob(_pds_url, _authorization, _body, _mime_type),
    do: {:error, :invalid_blob}

  def public_get(nsid, params) do
    with {:ok, origin} <- URL.normalize_origin(appview_url()) do
      request_json(:get, origin, nsid, params, nil, nil)
    end
  end

  defp pds_post(pds_url, nsid, body, authorization \\ nil) do
    with {:ok, origin} <- URL.normalize_origin(pds_url) do
      request_json(:post, origin, nsid, %{}, body, normalize_authorization(authorization))
    end
  end

  defp get_json(url) do
    with true <- URL.public_https_url?(url),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           HTTP.get(url, @json_headers, request_options()),
         {:ok, data} <- decode_body(body) do
      {:ok, data}
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      false -> {:error, :unsafe_service_url}
      error -> error
    end
  end

  defp request_json(method, origin, nsid, params, body, authorization) do
    url = origin <> "/xrpc/" <> nsid
    headers = [{"content-type", "application/json"} | @json_headers]
    encoded_body = if is_map(body), do: Jason.encode!(body), else: ""
    options = Keyword.put(request_options(), :params, Map.to_list(params))

    with {:ok, %{status: status, body: response_body}} when status in 200..299 <-
           perform_request(method, url, encoded_body, headers, authorization, options),
         {:ok, data} <- decode_body(response_body) do
      {:ok, data}
    else
      {:ok, %{status: status, body: response_body}} ->
        {:error, {:http, status, decode_error(response_body)}}

      error ->
        error
    end
  rescue
    _ -> {:error, :invalid_response}
  catch
    _, _ -> {:error, :invalid_response}
  end

  defp authenticated_headers(nil), do: []

  defp authenticated_headers({:bearer, token}) when is_binary(token) do
    [{"authorization", "Bearer #{token}"}]
  end

  defp authenticated_headers({:basic, username, password})
       when is_binary(username) and is_binary(password) do
    credentials = Base.encode64(username <> ":" <> password)
    [{"authorization", "Basic #{credentials}"}]
  end

  defp perform_request(
         method,
         url,
         body,
         headers,
         {:dpop, token, key_json, nonce, nonce_callback},
         options
       )
       when is_binary(token) and is_binary(key_json) and is_function(nonce_callback, 1) do
    case DPoP.request(
           method,
           url,
           body,
           headers,
           token,
           key_json,
           nonce,
           nonce_callback,
           options
         ) do
      {:ok, response, _nonce} -> {:ok, response}
      error -> error
    end
  end

  defp perform_request(method, url, body, headers, authorization, options) do
    HTTP.request(method, url, body, authenticated_headers(authorization) ++ headers, options)
  end

  defp normalize_authorization(authorization) when is_binary(authorization),
    do: {:bearer, authorization}

  defp normalize_authorization(authorization), do: authorization

  defp decode_body(body) when is_binary(body) and byte_size(body) <= @max_response_bytes do
    case Jason.decode(body) do
      {:ok, %{} = data} -> {:ok, data}
      _ -> {:error, :invalid_response}
    end
  end

  defp decode_body(_body), do: {:error, :response_too_large}

  defp decode_error(body) do
    case decode_body(body) do
      {:ok, data} -> Map.take(data, ["error", "message"])
      _ -> nil
    end
  end

  defp validate_did_document({:ok, %{"id" => did} = document}, did), do: {:ok, document}
  defp validate_did_document({:ok, _document}, _did), do: {:error, :did_document_mismatch}
  defp validate_did_document(error, _did), do: error

  defp did_web_url(encoded) do
    did = "did:web:#{encoded}"

    with true <- Pleroma.ATProto.Validation.valid_did?(did),
         true <- URL.public_host?(encoded) do
      {:ok, "https://#{encoded}/.well-known/did.json"}
    else
      _ -> {:error, :invalid_did_web}
    end
  end

  defp appview_url do
    Config.get([Pleroma.ATProto, :appview_url], "https://public.api.bsky.app")
  end

  defp request_options do
    [
      pool: :federation,
      recv_timeout: Config.get([Pleroma.ATProto, :request_timeout_ms], 10_000)
    ]
  end

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of atproto/client.ex
