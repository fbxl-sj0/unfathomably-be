# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ControllerHelper do
  use Pleroma.Web, :controller

  alias Pleroma.Pagination
  alias Pleroma.Web.Utils.Params

  def json_response(conn, status, _) when status in [204, :no_content] do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, "")
  end

  def json_response(conn, status, json) do
    conn
    |> put_status(status)
    |> json(json)
  end

  @spec fetch_integer_param(map(), String.t(), integer() | nil) :: integer() | nil
  def fetch_integer_param(params, name, default \\ nil) do
    params
    |> Map.get(name, default)
    |> param_to_integer(default)
  end

  defp param_to_integer(val, _) when is_integer(val), do: val

  defp param_to_integer(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {res, _} -> res
      _ -> default
    end
  end

  defp param_to_integer(_, default), do: default

  def add_link_headers(conn, entries, extra_params \\ %{}, order \\ :desc)

  def add_link_headers(
        %{assigns: %{skip_link_headers: true}} = conn,
        _entries,
        _extra_params,
        _order
      ),
      do: conn

  def add_link_headers(conn, entries, extra_params, order) do
    extra_params = Map.reject(extra_params, fn {_key, value} -> is_nil(value) end)

    case get_pagination_fields(conn, entries, extra_params, order) do
      %{"next" => next_url, "prev" => prev_url} ->
        put_resp_header(conn, "link", "<#{next_url}>; rel=\"next\", <#{prev_url}>; rel=\"prev\"")

      %{"prev" => prev_url} ->
        put_resp_header(conn, "link", "<#{prev_url}>; rel=\"prev\"")

      _ ->
        conn
    end
  end

  @id_keys Pagination.page_keys() -- ["limit", "order"]
  @id_key_atoms Enum.map(@id_keys, &String.to_atom/1)
  @drop_id_params_key :drop_id_params

  defp build_pagination_fields(conn, min_id, max_id, extra_params, order, full_page?) do
    drop_id_params? = Map.get(extra_params, @drop_id_params_key, false)
    extra_params = Map.delete(extra_params, @drop_id_params_key)

    params =
      conn.params
      |> Map.drop(path_param_keys(conn.path_params))
      |> merge_pagination_params(extra_params)
      |> Map.drop(@id_keys ++ if(drop_id_params?, do: @id_key_atoms, else: []))

    {{next_id, next_value}, {prev_id, prev_value}} =
      if order == :desc do
        {{:max_id, max_id}, {:min_id, min_id}}
      else
        {{:min_id, min_id}, {:max_id, max_id}}
      end

    id = current_url(conn)
    part_of = %{URI.parse(id) | query: nil} |> URI.to_string()
    pagination_conn = %{conn | query_string: ""}

    fields = %{
      "prev" => current_url(pagination_conn, Map.put(params, prev_id, prev_value)),
      "id" => id,
      "partOf" => part_of
    }

    if full_page? do
      Map.put(fields, "next", current_url(pagination_conn, Map.put(params, next_id, next_value)))
    else
      fields
    end
  end

  # OpenAPI casting uses atom keys while controller-specific pagination
  # parameters are commonly supplied with string keys. Normalize both maps
  # before merging so one logical query parameter cannot be emitted twice.
  defp merge_pagination_params(params, extra_params) do
    params
    |> stringify_pagination_param_keys()
    |> Map.merge(stringify_pagination_param_keys(extra_params))
  end

  defp stringify_pagination_param_keys(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      entry -> entry
    end)
  end

  defp path_param_keys(path_params) do
    path_params
    |> Map.keys()
    |> Enum.flat_map(&path_param_key_variants/1)
  end

  defp path_param_key_variants(key) when is_binary(key) do
    try do
      [key, String.to_existing_atom(key)]
    rescue
      ArgumentError -> [key]
    end
  end

  defp path_param_key_variants(key), do: [key]

  defp get_first_last_pagination_id(entries) do
    case List.last(entries) do
      %{pagination_id: last_id} when not is_nil(last_id) ->
        %{pagination_id: first_id} = List.first(entries)
        {first_id, last_id}

      %{id: last_id} ->
        %{id: first_id} = List.first(entries)
        {first_id, last_id}

      _ ->
        nil
    end
  end

  def get_pagination_fields(conn, entries, extra_params \\ %{}, order \\ :desc)

  def get_pagination_fields(conn, entries, extra_params, :desc) do
    case get_first_last_pagination_id(entries) do
      nil ->
        %{}

      {min_id, max_id} ->
        build_pagination_fields(
          conn,
          min_id,
          max_id,
          extra_params,
          :desc,
          full_page?(conn, entries)
        )
    end
  end

  def get_pagination_fields(conn, entries, extra_params, :asc) do
    case get_first_last_pagination_id(entries) do
      nil ->
        %{}

      {max_id, min_id} ->
        build_pagination_fields(
          conn,
          min_id,
          max_id,
          extra_params,
          :asc,
          full_page?(conn, entries)
        )
    end
  end

  defp full_page?(conn, entries) do
    length(entries) >= Pagination.page_limit(conn.params)
  end

  def assign_account_by_id(conn, _) do
    account =
      if valid_account_id?(conn.params.id) do
        Pleroma.User.get_cached_by_id(conn.params.id)
      end

    case account do
      %Pleroma.User{} = account -> assign(conn, :account, account)
      nil -> Pleroma.Web.MastodonAPI.FallbackController.call(conn, {:error, :not_found}) |> halt()
    end
  end

  # Mastodon account IDs rendered by this server are Base62 Flake IDs. Reject
  # malformed and unreasonably large route values before the Ecto cache key is
  # dumped, where Base62 decoding errors would otherwise become HTTP 500s.
  defp valid_account_id?(id) when is_binary(id) and byte_size(id) in 1..64,
    do: Regex.match?(~r/\A[A-Za-z0-9]+\z/, id)

  defp valid_account_id?(_), do: false

  def try_render(conn, target, params) when is_binary(target) do
    render(conn, target, params)
  end

  def try_render(conn, _, _) do
    render_error(conn, :not_implemented, "Can't display this activity")
  end

  @doc """
  Returns true if request specifies to include embedded relationships in account objects.
  May only be used in selected account-related endpoints; has no effect for status- or
    notification-related endpoints.
  """
  # Intended for PleromaFE: https://git.pleroma.social/pleroma/pleroma-fe/-/issues/838
  def embed_relationships?(params) do
    # To do once OpenAPI transition mess is over: just `truthy_param?(params[:with_relationships])`
    params
    |> Map.get(:with_relationships, params["with_relationships"])
    |> Params.truthy_param?()
  end
end
