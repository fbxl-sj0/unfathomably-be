# Unfathomably FASP client
# ------------------------
#
# File: client.ex
#
# Purpose:
#   Perform authenticated protocol calls to administrator-approved FASPs.
#
# Responsibilities:
#   - sign outbound requests with the per-provider local Ed25519 identity
#   - reject redirects and unsigned or incorrectly keyed responses
#   - normalize provider information and advertised capabilities
#   - activate only capabilities supported by both parties
#
# This file intentionally does not select providers for users, export discovery
# data, or perform account searches before a capability is activated.

defmodule Pleroma.FASP.Client do
  alias Pleroma.FASP.Crypto
  alias Pleroma.FASP.Registration
  alias Pleroma.HTTP
  alias Pleroma.HTTP.MessageSignatures

  @maximum_provider_info_bytes 262_144
  @maximum_account_search_bytes 262_144
  @supported_capabilities %{"account_search" => ["0.1"]}

  def refresh_provider_info(%Registration{state: "accepted"} = registration) do
    with {:ok, response} <- signed_request(registration, :get, "/provider_info", ""),
         true <- response.status == 200,
         true <-
           is_binary(response.body) and byte_size(response.body) <= @maximum_provider_info_bytes,
         {:ok, decoded} <- Jason.decode(response.body),
         {:ok, provider_info} <- normalize_provider_info(decoded, registration.name),
         {:ok, registration} <- Registration.update_provider_info(registration, provider_info) do
      {:ok, registration}
    else
      false -> {:error, :invalid_provider_response}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_provider_response}
    end
  end

  def refresh_provider_info(%Registration{}), do: {:error, :not_accepted}

  def activate(%Registration{} = registration, capability, version) do
    change_activation(registration, capability, version, true)
  end

  def deactivate(%Registration{} = registration, capability, version) do
    change_activation(registration, capability, version, false)
  end

  def supported_capabilities, do: @supported_capabilities

  def account_search(
        %Registration{state: "accepted"} = registration,
        term,
        limit
      )
      when is_binary(term) and is_integer(limit) do
    term = term |> String.trim() |> String.slice(0, 200)
    limit = limit |> max(1) |> min(20)

    with true <- term != "",
         true <- Registration.capability_active?(registration, "account_search", "0.1"),
         query <- URI.encode_query(%{"term" => term, "limit" => limit}),
         {:ok, response} <-
           signed_request(
             registration,
             :get,
             "/account_search/v0/search?#{query}",
             ""
           ),
         true <- response.status == 200,
         true <-
           is_binary(response.body) and byte_size(response.body) <= @maximum_account_search_bytes,
         {:ok, decoded} <- Jason.decode(response.body),
         {:ok, actor_ids} <- normalize_actor_ids(decoded, limit) do
      {:ok, actor_ids}
    else
      false -> {:error, :account_search_not_active}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_account_search_response}
    end
  end

  def account_search(%Registration{}, _term, _limit), do: {:error, :not_accepted}

  defp change_activation(
         %Registration{state: "accepted"} = registration,
         capability,
         version,
         enabled
       ) do
    with :ok <- supported_capability(capability, version),
         true <- provider_advertises?(registration, capability, version),
         path <- "/capabilities/#{capability}/#{version}/activation",
         method <- if(enabled, do: :post, else: :delete),
         {:ok, response} <- signed_request(registration, method, path, ""),
         true <- response.status == 204,
         {:ok, registration} <-
           Registration.set_capability(registration, capability, version, enabled) do
      {:ok, registration}
    else
      false -> {:error, :capability_not_advertised}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :capability_activation_failed}
    end
  end

  defp change_activation(%Registration{}, _capability, _version, _enabled),
    do: {:error, :not_accepted}

  defp signed_request(registration, method, path, body) do
    url = endpoint_url(registration.base_url, path)
    content_digest = MessageSignatures.content_digest(body)
    signed_headers = %{"content-digest" => content_digest}

    with {:ok, private_key} <-
           Crypto.decrypt_private_key(registration.local_private_key_ciphertext),
         {:ok, signature_headers} <-
           MessageSignatures.sign_ed25519(
             private_key,
             registration.fasp_id,
             method,
             url,
             signed_headers
           ),
         {:ok, response} <-
           HTTP.request(
             method,
             url,
             body,
             [
               {"Accept", "application/json"},
               {"Content-Type", "application/json"},
               {"Content-Digest", content_digest}
               | signature_headers
             ],
             pool: :federation,
             public_only: true,
             redirect_middleware: nil
           ),
         {:ok, key_id} <- MessageSignatures.key_id(response),
         true <- key_id == registration.provider_server_id,
         :ok <-
           MessageSignatures.validate_response_result(
             response,
             {:ed25519, registration.provider_public_key}
           ) do
      {:ok, response}
    else
      false -> {:error, :invalid_provider_signature}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :provider_request_failed}
    end
  end

  defp normalize_provider_info(data, expected_name) when is_map(data) do
    privacy_policy = data["privacyPolicy"] || data["privacy_policy"]
    capabilities = data["capabilities"]

    with {:ok, name} <- bounded_string(data["name"], 200),
         true <- name == expected_name,
         {:ok, privacy_policy} <- normalize_privacy_policy(privacy_policy),
         {:ok, capabilities} <- normalize_capabilities(capabilities) do
      {:ok,
       %{
         "name" => name,
         "privacy_policy" => privacy_policy,
         "capabilities" => capabilities
       }
       |> put_optional("sign_in_url", valid_https_url(data["signInUrl"] || data["sign_in_url"]))
       |> put_optional(
         "contact_email",
         contact_email(data["contactEmail"] || data["contact_email"])
       )
       |> put_optional(
         "fediverse_account",
         fediverse_account(data["fediverseAccount"] || data["fediverse_account"])
       )}
    else
      false -> {:error, :provider_identity_changed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_provider_info}
    end
  end

  defp normalize_provider_info(_, _), do: {:error, :invalid_provider_info}

  defp normalize_actor_ids(values, limit) when is_list(values) do
    actor_ids =
      values
      |> Enum.map(&valid_https_url/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(limit)

    if length(actor_ids) == length(Enum.take(values, limit)) do
      {:ok, actor_ids}
    else
      {:error, :invalid_account_search_response}
    end
  end

  defp normalize_actor_ids(_, _limit), do: {:error, :invalid_account_search_response}

  defp normalize_privacy_policy(values) when is_list(values) and length(values) <= 20 do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_map(value) ->
        with url when is_binary(url) <- valid_https_url(value["url"]),
             {:ok, language} <- language_code(value["language"]) do
          {:cont, {:ok, [%{"url" => url, "language" => language} | acc]}}
        else
          _ -> {:halt, {:error, :invalid_privacy_policy}}
        end

      _, _ ->
        {:halt, {:error, :invalid_privacy_policy}}
    end)
    |> reverse_result()
  end

  defp normalize_privacy_policy(_), do: {:error, :invalid_privacy_policy}

  defp normalize_capabilities(values) when is_list(values) and length(values) <= 50 do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_map(value) ->
        with {:ok, id} <- capability_identifier(value["id"]),
             {:ok, version} <- capability_version(value["version"]) do
          {:cont, {:ok, [%{"id" => id, "version" => version} | acc]}}
        else
          _ -> {:halt, {:error, :invalid_capabilities}}
        end

      _, _ ->
        {:halt, {:error, :invalid_capabilities}}
    end)
    |> reverse_result()
  end

  defp normalize_capabilities(_), do: {:error, :invalid_capabilities}

  defp provider_advertises?(registration, capability, version) do
    registration.provider_info
    |> Map.get("capabilities", [])
    |> Enum.any?(fn
      %{"id" => ^capability, "version" => ^version} -> true
      _ -> false
    end)
  end

  defp supported_capability(capability, version) do
    with {:ok, capability} <- capability_identifier(capability),
         {:ok, version} <- capability_version(version),
         true <- version in Map.get(@supported_capabilities, capability, []) do
      :ok
    else
      _ -> {:error, :unsupported_capability}
    end
  end

  defp capability_identifier(value) when is_binary(value) do
    value = String.trim(value)

    if String.match?(value, ~r/\A[a-z][a-z0-9_]{0,63}\z/) do
      {:ok, value}
    else
      {:error, :invalid_capability}
    end
  end

  defp capability_identifier(_), do: {:error, :invalid_capability}

  defp capability_version(value) when is_binary(value) do
    value = String.trim(value)

    if String.match?(value, ~r/\A[0-9]+(?:\.[0-9]+){1,2}\z/) && String.length(value) <= 20 do
      {:ok, value}
    else
      {:error, :invalid_capability_version}
    end
  end

  defp capability_version(_), do: {:error, :invalid_capability_version}

  defp language_code(value) when is_binary(value) do
    value = String.trim(value)

    if String.match?(value, ~r/\A[a-z]{2}(?:-[A-Za-z0-9]{2,8})*\z/) do
      {:ok, value}
    else
      {:error, :invalid_language}
    end
  end

  defp language_code(_), do: {:error, :invalid_language}

  defp contact_email(value) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) <= 254 && String.match?(value, ~r/\A[^@\s]+@[^@\s]+\z/) do
      value
    end
  end

  defp contact_email(_), do: nil

  defp fediverse_account(value) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) <= 300 && String.match?(value, ~r/\A@?[^@\s]+@[^@\s]+\z/) do
      value
    end
  end

  defp fediverse_account(_), do: nil

  defp valid_https_url(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: "https", host: host, userinfo: nil} = uri
      when is_binary(host) and byte_size(host) > 0 ->
        url = URI.to_string(uri)
        if byte_size(url) <= 2_048, do: url

      _ ->
        nil
    end
  rescue
    URI.Error -> nil
  end

  defp valid_https_url(_), do: nil

  defp bounded_string(value, maximum) when is_binary(value) do
    value = String.trim(value)

    if value != "" && String.length(value) <= maximum do
      {:ok, value}
    else
      {:error, :invalid_string}
    end
  end

  defp bounded_string(_, _), do: {:error, :invalid_string}

  defp endpoint_url(base_url, path) do
    uri = URI.parse(base_url)
    base_path = (uri.path || "") |> String.trim_trailing("/")
    [path | query] = String.split(path, "?", parts: 2)
    path = "/" <> String.trim_leading(path, "/")

    uri
    |> Map.put(:path, base_path <> path)
    |> Map.put(:query, List.first(query))
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result(error), do: error

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end

# end of client.ex
