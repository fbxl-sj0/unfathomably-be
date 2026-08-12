# Unfathomably BE
# ----------------
#
# File: nostr/moderation.ex
#
# Purpose:
#   Translate NIP-56 reports at the ActivityPub moderation boundary.
#
# Responsibilities:
#   - validate bounded NIP-56 report references and report types
#   - create ordinary local Flag activities for locally actionable reports
#   - derive NIP-56 tags from local reports about Nostr identities or events
#
# This file intentionally does NOT automatically moderate users or content,
# trust arbitrary remote reports, or forward reports without a Nostr target.

defmodule Pleroma.Nostr.Moderation do
  alias Pleroma.Activity
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  @report_types ~w(nudity malware profanity illegal spam impersonation other)
  @max_comment_bytes 5_000
  @max_references 32

  def validate(%{"kind" => 1_984, "content" => content} = event)
      when is_binary(content) and byte_size(content) <= @max_comment_bytes do
    pubkeys = tagged_values(event, "p", 64)
    event_ids = tagged_values(event, "e", 64)

    cond do
      pubkeys == [] ->
        invalid("reports require a target pubkey")

      length(pubkeys) > @max_references or length(event_ids) > @max_references ->
        invalid("report reference limit exceeded")

      not Enum.all?(pubkeys, &hex_identifier?/1) ->
        invalid("report contains an invalid pubkey")

      not Enum.all?(event_ids, &hex_identifier?/1) ->
        invalid("report contains an invalid event id")

      report_type(event) == nil ->
        invalid("reports require a supported report type")

      true ->
        :ok
    end
  end

  def validate(%{"kind" => 1_984}), do: invalid("report content must be bounded text")
  def validate(_event), do: invalid("invalid report event")

  def import_report(event, stored, relay_url) do
    with {:ok, reporter} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         {:ok, account, status_events} <- report_targets(event),
         true <- locally_actionable?(account, status_events),
         {:ok, %Activity{} = activity} <-
           CommonAPI.report(reporter, %{
             account_id: account.id,
             status_ids: status_ids(status_events),
             comment: report_comment(event),
             forward: false
           }) do
      Store.map_activity(stored.id, activity.id, nil)
    else
      # Reports about content merely observed on another relay remain valid
      # relay data, but must not be able to flood this server's admin queue.
      false -> :ok
      _error -> :ok
    end
  end

  def outbound(%Activity{data: %{"type" => "Flag"} = data}) do
    references = data |> Map.get("object", []) |> List.wrap() |> Enum.take(@max_references)
    events = references |> Enum.map(&event_for_reference/1) |> Enum.reject(&is_nil/1)
    entities = references |> Enum.map(&entity_for_reference/1) |> Enum.reject(&is_nil/1)
    type = outbound_report_type(data)

    pubkeys =
      (Enum.map(events, & &1.pubkey) ++ Enum.map(entities, & &1.pubkey))
      |> Enum.filter(&hex_identifier?/1)
      |> Enum.uniq()

    event_tags = Enum.map(events, &["e", &1.id, type])
    pubkey_tags = Enum.map(pubkeys, &["p", &1, type])

    relays =
      (Enum.map(events, & &1.relay_url) ++
         Enum.flat_map(entities, fn entity ->
           case entity.user do
             %User{} = user -> Identity.relays_for_user(user, :read)
             _user -> List.wrap(entity.relay_url)
           end
         end))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if pubkey_tags == [] do
      {:error, :not_nostr_report}
    else
      {:ok, Enum.uniq(event_tags) ++ pubkey_tags, relays, report_content(data)}
    end
  end

  def outbound(_activity), do: {:error, :not_nostr_report}

  defp report_targets(event) do
    status_events =
      event
      |> tagged_values("e", 64)
      |> Enum.map(&Store.get/1)
      |> Enum.reject(&is_nil/1)

    entity =
      event
      |> Protocol.tag_value("p")
      |> profile_entity()
      |> case do
        %Entity{} = entity -> entity
        nil -> status_events |> List.first() |> event_author_entity()
      end

    case entity do
      %Entity{user: %User{} = account} -> {:ok, account, status_events}
      _entity -> {:error, :unknown_target}
    end
  end

  defp profile_entity(pubkey) when is_binary(pubkey), do: Identity.get_profile(pubkey)
  defp profile_entity(_pubkey), do: nil

  defp event_author_entity(%{pubkey: pubkey}), do: profile_entity(pubkey)
  defp event_author_entity(_event), do: nil

  defp locally_actionable?(account, status_events) do
    case Identity.get_by_user(account) do
      %Entity{kind: kind} when kind in ["local_actor", "local_group"] ->
        true

      _entity ->
        Enum.any?(status_events, fn event ->
          event.local == true or event.relay_url == Nostr.relay_url()
        end)
    end
  end

  defp status_ids(events) do
    events
    |> Enum.map(& &1.ap_activity_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp report_comment(event) do
    type = report_type(event) || "other"
    detail = event["content"] |> to_string() |> String.slice(0, @max_comment_bytes)

    case String.trim(detail) do
      "" -> "Nostr #{type} report"
      detail -> "Nostr #{type} report\n\n#{detail}"
    end
  end

  defp report_content(data) do
    data
    |> Map.get("content", "")
    |> to_string()
    |> Pleroma.HTML.strip_tags()
    |> String.slice(0, @max_comment_bytes)
  end

  defp report_type(event) do
    event
    |> Map.get("tags", [])
    |> Enum.find_value(fn
      [key, _value, type | _rest] when key in ["p", "e", "x"] and type in @report_types ->
        type

      _tag ->
        nil
    end)
  end

  defp outbound_report_type(data) do
    case data["category"] do
      type when type in @report_types -> type
      _type -> "other"
    end
  end

  defp tagged_values(event, key, expected_length) do
    event
    |> Map.get("tags", [])
    |> Enum.flat_map(fn
      [^key, value | _rest] when is_binary(value) and byte_size(value) == expected_length ->
        [value]

      _tag ->
        []
    end)
    |> Enum.uniq()
  end

  defp event_for_reference(%{"id" => id}), do: event_for_reference(id)

  defp event_for_reference(id) when is_binary(id) do
    Store.get_by_ap_object_id(id) || Store.get_by_ap_activity_uri(id)
  end

  defp event_for_reference(_reference), do: nil

  defp entity_for_reference(%{"id" => id}), do: entity_for_reference(id)

  defp entity_for_reference(ap_id) when is_binary(ap_id) do
    case User.get_cached_by_ap_id(ap_id) do
      %User{} = user -> Identity.get_by_user(user)
      _user -> nil
    end
  end

  defp entity_for_reference(_reference), do: nil

  defp hex_identifier?(value) do
    is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)
  end

  defp invalid(reason), do: {:error, "invalid", reason}
end

# end of nostr/moderation.ex
