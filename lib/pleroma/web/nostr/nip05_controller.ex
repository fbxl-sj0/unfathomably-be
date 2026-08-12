# Unfathomably BE
# ----------------
#
# File: web/nostr/nip05_controller.ex
#
# Purpose:
#   Publish local ActivityPub usernames as NIP-05 Nostr identifiers.
#
# Responsibilities:
#   - resolve an active local account by its existing ActivityPub nickname
#   - lazily provision the account's deterministic bridge public key
#   - return the bounded NIP-05 names and relay document
#
# This file intentionally does NOT allocate alternate usernames, accept remote
# accounts, expose private keys, or introduce a separate name-review workflow.

defmodule Pleroma.Web.Nostr.NIP05Controller do
  use Pleroma.Web, :controller

  alias Pleroma.Nostr
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.User
  alias Pleroma.Web.WebFinger

  def show(conn, %{"name" => requested_name}) do
    if Nostr.enabled?() do
      requested_name
      |> local_mapping()
      |> respond(conn)
    else
      send_resp(conn, :not_found, "")
    end
  end

  def show(conn, _params) do
    if Nostr.enabled?(), do: respond(nil, conn), else: send_resp(conn, :not_found, "")
  end

  defp local_mapping(requested_name) when is_binary(requested_name) do
    name = requested_name |> String.trim() |> String.downcase()
    expected_identifier = "#{name}@#{String.downcase(WebFinger.domain())}"

    with true <- valid_name?(name),
         %User{} = user <- User.get_cached_by_nickname(name),
         true <- eligible?(user),
         ^expected_identifier <- Identity.local_nip05(user),
         {:ok, %Entity{pubkey: pubkey}} <- Identity.local_actor(user) do
      {name, pubkey}
    else
      _ -> nil
    end
  end

  defp local_mapping(_requested_name), do: nil

  defp eligible?(%User{
         local: true,
         invisible: false,
         is_active: true,
         is_approved: true,
         is_confirmed: true,
         actor_type: actor_type
       })
       when actor_type != "Group",
       do: true

  defp eligible?(_user), do: false

  defp valid_name?(name) do
    case Pleroma.Nostr.NIP05.parse_identifier("#{name}@#{WebFinger.domain()}") do
      {:ok, %{name: ^name}} -> true
      _ -> false
    end
  end

  defp respond({name, pubkey}, conn) do
    relays =
      case Nostr.relay_url() do
        relay when is_binary(relay) -> %{pubkey => [relay]}
        _ -> %{}
      end

    json_response(conn, %{
      names: %{name => pubkey},
      relays: relays
    })
  end

  defp respond(nil, conn), do: json_response(conn, %{names: %{}, relays: %{}})

  defp json_response(conn, document) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(document)
  end
end

# end of web/nostr/nip05_controller.ex
