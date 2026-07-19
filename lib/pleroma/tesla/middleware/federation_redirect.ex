# Pleroma: A lightweight social networking server
# SPDX-FileCopyrightText: 2026 Unfathomably Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Tesla.Middleware.FederationRedirect do
  @moduledoc """
  Follows federation redirects and rebuilds request-bound authentication.

  HTTP signatures cover the target URI. Reusing a signature after a redirect
  authenticates the old request rather than the request that is sent. The
  configured signer therefore receives each redirected Tesla environment after
  unsafe headers have been removed and before the next request is issued.

  This middleware intentionally does not choose an ActivityPub actor or a
  signature format. Callers retain that responsibility through the `:signer`
  callback.
  """

  @behaviour Tesla.Middleware

  @default_max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]
  @always_strip ~w(
    connection keep-alive proxy-connection te trailer transfer-encoding upgrade
    if-match if-modified-since if-none-match if-range if-unmodified-since
    signature signature-input authorization date host
  )
  @cross_origin_strip ~w(cookie origin proxy-authorization referer)
  @method_change_strip ~w(
    content-digest content-encoding content-language content-length
    content-location content-type digest last-modified
  )

  @impl Tesla.Middleware
  def call(env, next, opts \\ []) do
    max_redirects = Keyword.get(opts || [], :max_redirects, @default_max_redirects)
    redirect(env, next, opts || [], max_redirects)
  end

  defp redirect(env, next, _opts, 0) do
    case Tesla.run(env, next) do
      {:ok, %{status: status} = env} when status not in @redirect_statuses -> {:ok, env}
      {:ok, _env} -> {:error, {__MODULE__, :too_many_redirects}}
      error -> error
    end
  end

  defp redirect(env, next, opts, redirects_left) do
    case Tesla.run(env, next) do
      {:ok, %{status: status} = response} when status in @redirect_statuses ->
        follow(response, env, next, opts, status, redirects_left)

      result ->
        result
    end
  end

  defp follow(response, env, next, opts, status, redirects_left) do
    case Tesla.get_header(response, "location") do
      nil ->
        {:ok, response}

      location ->
        previous_uri = URI.parse(env.url)
        next_uri = parse_location(location, response)

        redirected_env =
          %{env | opts: response.opts}
          |> filter_headers(previous_uri, next_uri, status)
          |> new_request(status, URI.to_string(next_uri))

        with {:ok, redirected_env} <- resign(redirected_env, Keyword.get(opts, :signer)) do
          redirect(redirected_env, next, opts, redirects_left - 1)
        end
    end
  end

  defp resign(env, {module, function, arguments})
       when is_atom(module) and is_atom(function) and is_list(arguments) do
    apply(module, function, [env | arguments])
  end

  defp resign(_env, _), do: {:error, {__MODULE__, :missing_signer}}

  defp new_request(env, 303, location),
    do: %{env | url: location, method: :get, query: [], body: nil}

  defp new_request(env, 307, location), do: %{env | url: location}
  defp new_request(env, 308, location), do: %{env | url: location}
  defp new_request(env, _status, location), do: %{env | url: location, query: []}

  defp parse_location("https://" <> _rest = location, _env), do: URI.parse(location)
  defp parse_location("http://" <> _rest = location, _env), do: URI.parse(location)
  defp parse_location(location, env), do: env.url |> URI.parse() |> URI.merge(location)

  defp filter_headers(env, previous_uri, next_uri, status) do
    drop =
      @always_strip
      |> add_if(cross_origin?(previous_uri, next_uri), @cross_origin_strip)
      |> add_if(status == 303, @method_change_strip)

    %{env | headers: Enum.reject(env.headers, &dropped?(&1, drop))}
  end

  defp dropped?({key, _value}, drop), do: String.downcase(to_string(key)) in drop
  defp add_if(values, true, extra), do: values ++ extra
  defp add_if(values, false, _extra), do: values

  defp cross_origin?(previous_uri, next_uri) do
    previous_uri.host != next_uri.host or previous_uri.port != next_uri.port or
      previous_uri.scheme != next_uri.scheme
  end
end

# end of federation_redirect.ex
