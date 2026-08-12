# Unfathomably BE
# ----------------
#
# File: web/nostr_relay_plug.ex
#
# Purpose:
#   Expose the optional Nostr relay and NIP-11 information document.
#
# Responsibilities:
#   - intercept only the configured relay path
#   - upgrade valid WebSocket requests through WebSockAdapter
#   - return relay capabilities for application/nostr+json requests
#   - keep disabled instances indistinguishable from an absent route
#
# This file intentionally does NOT parse Nostr frames, persist events, or
# authorize group operations.

defmodule Pleroma.Web.NostrRelayPlug do
  import Plug.Conn

  alias Pleroma.Config
  alias Pleroma.Nostr
  alias Pleroma.Nostr.RelaySocket

  def init(opts), do: opts

  def call(conn, _opts) do
    if Nostr.enabled?() and conn.request_path == Nostr.relay_path() do
      serve_relay(conn)
    else
      conn
    end
  end

  defp serve_relay(%Plug.Conn{method: "GET"} = conn) do
    cond do
      websocket_upgrade?(conn) ->
        conn
        |> WebSockAdapter.upgrade(RelaySocket, %{},
          compress: false,
          max_frame_size: max_event_bytes()
        )
        |> halt()

      accepts_nostr_json?(conn) ->
        conn
        |> put_resp_content_type("application/nostr+json")
        |> send_resp(:ok, Jason.encode!(relay_information()))
        |> halt()

      accepts_activitypub_json?(conn) ->
        conn

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:upgrade_required, "This endpoint is a Nostr WebSocket relay.\n")
        |> halt()
    end
  end

  defp serve_relay(conn) do
    conn
    |> send_resp(:method_not_allowed, "")
    |> halt()
  end

  defp relay_information do
    metadata = Nostr.instance_metadata() || %{}

    %{
      name: Config.get([:instance, :name], "Unfathomably"),
      description: "ActivityPub-authoritative Nostr compatibility relay",
      pubkey: metadata[:pubkey],
      self: metadata[:pubkey],
      software: Pleroma.Application.repository(),
      version: Pleroma.Application.version(),
      supported_nips: Nostr.supported_nips(),
      limitation: %{
        auth_required: false,
        default_limit: Config.get([Nostr, :max_filter_limit], 500),
        max_content_length: Config.get([Nostr, :max_content_bytes], 50_000),
        max_event_tags: Config.get([Nostr, :max_tags], 128),
        max_limit: Config.get([Nostr, :max_filter_limit], 500),
        max_message_length: max_event_bytes(),
        max_subscriptions: Config.get([Nostr, :max_subscriptions], 20),
        payment_required: false,
        restricted_writes: true
      },
      nip29: %{subgroups: false}
    }
  end

  defp websocket_upgrade?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  defp accepts_nostr_json?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(String.downcase(&1), "application/nostr+json"))
  end

  # The Nostr relay and the ActivityPub relay intentionally share /relay.
  # ActivityPub actor fetches must continue through the Phoenix router instead
  # of receiving the Nostr endpoint's HTTP 426 response.
  defp accepts_activitypub_json?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(fn value ->
      value = String.downcase(value)

      String.contains?(value, "application/activity+json") or
        (String.contains?(value, "application/ld+json") and
           String.contains?(value, "https://www.w3.org/ns/activitystreams"))
    end)
  end

  defp max_event_bytes do
    case Config.get([Nostr, :max_event_bytes], 65_536) do
      value when is_integer(value) and value > 0 -> value
      _ -> 65_536
    end
  end
end

# end of web/nostr_relay_plug.ex
