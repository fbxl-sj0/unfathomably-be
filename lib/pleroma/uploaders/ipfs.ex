# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Uploaders.IPFS do
  @behaviour Pleroma.Uploaders.Uploader
  require Logger

  alias Pleroma.Config
  alias Tesla.Multipart

  @api_add "/api/v0/add"
  @api_delete "/api/v0/files/rm"

  def put_file_endpoint do
    ipfs_endpoint(@api_add)
  end

  def delete_file_endpoint do
    ipfs_endpoint(@api_delete)
  end

  @placeholder "{CID}"
  def placeholder, do: @placeholder

  @impl true
  def get_file(file) do
    b_url = Config.get([__MODULE__, :get_gateway_url]) || Pleroma.Upload.base_url()

    if String.contains?(b_url, @placeholder) do
      {:ok, {:url, String.replace(b_url, @placeholder, URI.decode(file))}}
    else
      {:error, "IPFS Get URL doesn't contain 'cid' placeholder"}
    end
  end

  @impl true
  def put_file(%Pleroma.Upload{tempfile: tempfile}) do
    mp =
      Multipart.new()
      |> Multipart.add_content_type_param("charset=utf-8")
      |> Multipart.add_file(tempfile)

    with endpoint when is_binary(endpoint) <- put_file_endpoint(),
         {:ok, %{body: body}} when is_binary(body) <-
           Pleroma.HTTP.post(endpoint, mp, [], params: ["cid-version": "1"], pool: :upload),
         {_, {:ok, decoded}} <- {:json, Jason.decode(body)},
         {_, true} <- {:hash, Map.has_key?(decoded, "Hash")} do
      {:ok, {:file, decoded["Hash"]}}
    else
      {:hash, false} ->
        {:error, "JSON doesn't contain Hash key"}

      {:json, error} ->
        Logger.error("#{__MODULE__}: #{inspect(error)}")
        {:error, "JSON decode failed"}

      error ->
        Logger.error("#{__MODULE__}: #{inspect(error)}")
        {:error, "IPFS Gateway upload failed"}
    end
  end

  @impl true
  def delete_file(file) do
    case Pleroma.HTTP.post(delete_file_endpoint(), "", [], params: [arg: file]) do
      {:ok, %{status: 204}} -> :ok
      error -> {:error, inspect(error)}
    end
  end

  defp ipfs_endpoint(path) do
    case Config.get([__MODULE__, :post_gateway_url]) do
      post_base_url when is_binary(post_base_url) ->
        post_base_url
        |> URI.parse()
        |> Map.put(:path, path)
        |> URI.to_string()

      _ ->
        nil
    end
  end
end
