defmodule Pleroma.Web.Plugs.MetricsPredicate do
  @moduledoc """
  This Unplug predicate is used to authorize requests to the PromEx metrics
  """

  @behaviour Unplug.Predicate

  @impl true
  def call(conn, _) do
    case get_configured_auth_token() do
      token when is_binary(token) and byte_size(token) > 0 ->
        conn
        |> Plug.Conn.get_req_header("authorization")
        |> bearer_token_matches?(token)

      :disabled ->
        true

      _ ->
        false
    end
  end

  defp bearer_token_matches?(["Bearer " <> token], configured_token)
       when byte_size(token) == byte_size(configured_token) do
    Plug.Crypto.secure_compare(token, configured_token)
  end

  defp bearer_token_matches?(_, _configured_token), do: false

  defp get_configured_auth_token do
    case Application.get_env(:pleroma, __MODULE__, auth_token: nil) do
      config when is_list(config) -> Keyword.get(config, :auth_token)
      _ -> nil
    end
  end
end
