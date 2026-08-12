# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP do
  @moduledoc """
    Wrapper for `Tesla.request/2`.
  """

  alias Pleroma.HTTP.AdapterHelper
  alias Pleroma.HTTP.Request
  alias Pleroma.HTTP.RequestBuilder, as: Builder
  alias Tesla.Client
  alias Tesla.Env

  require Logger

  @type t :: __MODULE__
  @type method() :: :get | :post | :put | :delete | :head

  @doc """
  Performs GET request.

  See `Pleroma.HTTP.request/5`
  """
  @spec get(Request.url() | nil, Request.headers(), keyword()) ::
          nil | {:ok, Env.t()} | {:error, any()}
  def get(url, headers \\ [], options \\ [])
  def get(nil, _, _), do: nil
  def get(url, headers, options), do: request(:get, url, "", headers, options)

  @spec head(Request.url(), Request.headers(), keyword()) :: {:ok, Env.t()} | {:error, any()}
  def head(url, headers \\ [], options \\ []), do: request(:head, url, "", headers, options)

  @doc """
  Performs POST request.

  See `Pleroma.HTTP.request/5`
  """
  @spec post(Request.url(), Tesla.Env.body(), Request.headers(), keyword()) ::
          {:ok, Env.t()} | {:error, any()}
  def post(url, body, headers \\ [], options \\ []),
    do: request(:post, url, body, headers, options)

  @doc """
  Builds and performs http request.

  # Arguments:
  `method` - :get, :post, :put, :delete, :head
  `url` - full url
  `body` - request body
  `headers` - a keyworld list of headers, e.g. `[{"content-type", "text/plain"}]`
  `options` - custom, per-request middleware or adapter options

  # Returns:
  `{:ok, %Tesla.Env{}}` or `{:error, error}`

  """
  @spec request(method(), Request.url(), Tesla.Env.body(), Request.headers(), keyword()) ::
          {:ok, Env.t()} | {:error, any()}
  def request(method, url, body, headers, options) when is_binary(url) do
    uri = URI.parse(url)
    adapter_opts = AdapterHelper.options(uri, options || [])

    options = put_in(options[:adapter], adapter_opts)
    params = options[:params] || []
    request = build_request(method, headers, options, url, body, params)

    adapter = Application.get_env(:tesla, :adapter)
    extra_middleware = options[:tesla_middleware] || []

    redirect_middleware =
      Keyword.get(options, :redirect_middleware, Tesla.Middleware.FollowRedirects)

    client =
      Tesla.client(adapter_middlewares(adapter, redirect_middleware, extra_middleware), adapter)

    result =
      maybe_limit(
        fn ->
          request(client, request)
        end,
        adapter,
        adapter_opts
      )

    maybe_retry_tls_compatibility(
      result,
      adapter,
      method,
      request,
      adapter_opts,
      redirect_middleware,
      extra_middleware,
      uri
    )
  end

  @spec request(Client.t(), keyword()) :: {:ok, Env.t()} | {:error, any()}
  def request(client, request) do
    try do
      Tesla.request(client, request)
    rescue
      error ->
        {:error, error}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  defp build_request(method, headers, options, url, body, params) do
    Builder.new()
    |> Builder.method(method)
    |> Builder.headers(headers)
    |> Builder.opts(options)
    |> Builder.url(url)
    |> Builder.add_param(:body, :body, body)
    |> Builder.add_param(:query, :query, params)
    |> Builder.convert_to_keyword()
  end

  @prefix Pleroma.Gun.ConnectionPool
  defp maybe_limit(fun, Tesla.Adapter.Gun, opts) do
    ConcurrentLimiter.limit(:"#{@prefix}.#{opts[:pool] || :default}", fun)
  end

  defp maybe_limit(fun, _, _) do
    fun.()
  end

  defp maybe_retry_tls_compatibility(
         {:error, {:tls_alert, {:handshake_failure, _detail}}},
         Tesla.Adapter.Gun,
         method,
         request,
         adapter_opts,
         redirect_middleware,
         extra_middleware,
         %URI{host: host}
       )
       when method in [:get, :head] do
    Logger.info("Retrying HTTP #{method} to #{host} with the TLS 1.2 compatibility pool")

    fallback_adapter = Tesla.Adapter.Gun

    fallback_opts =
      adapter_opts
      |> Keyword.put(:tls_opts, versions: [:"tlsv1.2"])
      |> Keyword.put(:tls_compatibility, :tls12)

    fallback_request = put_in(request, [:opts, :adapter], fallback_opts)

    fallback_client =
      Tesla.client(
        adapter_middlewares(fallback_adapter, redirect_middleware, extra_middleware),
        fallback_adapter
      )

    maybe_limit(
      fn -> request(fallback_client, fallback_request) end,
      fallback_adapter,
      fallback_opts
    )
  end

  defp maybe_retry_tls_compatibility(
         result,
         _adapter,
         _method,
         _request,
         _adapter_opts,
         _redirect_middleware,
         _extra_middleware,
         _uri
       ),
       do: result

  defp adapter_middlewares(Tesla.Adapter.Gun, redirect_middleware, extra_middleware) do
    List.wrap(redirect_middleware) ++
      [Pleroma.Tesla.Middleware.ConnectionPool] ++
      extra_middleware
  end

  defp adapter_middlewares({Tesla.Adapter.Finch, _}, redirect_middleware, extra_middleware) do
    List.wrap(redirect_middleware) ++ extra_middleware
  end

  defp adapter_middlewares(_, redirect_middleware, extra_middleware) do
    if Pleroma.Config.get(:env) == :test do
      # Emulate redirects in test env, which are handled by adapters in other environments
      List.wrap(redirect_middleware) ++ extra_middleware
    else
      extra_middleware
    end
  end
end
