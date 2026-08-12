# Unfathomably BE
# ----------------
#
# File: nostr/lists.ex
#
# Purpose:
#   Project local follow state into public NIP-51 list events.
#
# Responsibilities:
#   - build the public NIP-29 simple-groups list for a local actor
#   - include relay hints needed by other Nostr clients
#   - bound list size and presentation metadata
#
# This file intentionally does NOT decrypt private lists, change follows from
# received list events, or publish signed events.

defmodule Pleroma.Nostr.Lists do
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.User

  @max_groups 500
  @max_group_name 200

  def simple_groups(%User{} = actor) do
    groups =
      actor
      |> User.get_friends()
      |> Enum.flat_map(&group_entry/1)
      |> Enum.uniq_by(fn %{group_id: group_id, relay_url: relay_url} ->
        {relay_url, group_id}
      end)
      |> Enum.take(@max_groups)

    group_tags =
      Enum.map(groups, fn group ->
        ["group", group.group_id, group.relay_url, group.name]
      end)

    relays = groups |> Enum.map(& &1.relay_url) |> Enum.uniq()
    relay_tags = Enum.map(relays, &["r", &1])

    {group_tags ++ relay_tags, relays}
  end

  def simple_groups(_actor), do: {[], []}

  defp group_entry(%User{} = group) do
    case Identity.get_by_user(group) do
      %Entity{kind: kind, group_id: group_id, relay_url: relay_url}
      when kind in ["mirror_group", "local_group"] and is_binary(group_id) and
             is_binary(relay_url) ->
        [
          %{
            group_id: group_id,
            relay_url: relay_url,
            name: group_name(group, group_id)
          }
        ]

      _entity ->
        []
    end
  end

  defp group_name(%User{name: name}, _group_id) when is_binary(name) and name != "" do
    name
    |> String.replace(["\0", "\r", "\n"], " ")
    |> String.slice(0, @max_group_name)
  end

  defp group_name(_group, group_id), do: String.slice(group_id, 0, @max_group_name)
end

# end of nostr/lists.ex
