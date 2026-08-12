# Unfathomably BE
# ----------------
#
# File: nostr/poll.ex
#
# Purpose:
#   Translate NIP-88 polls and responses into existing ActivityPub polls.
#
# Responsibilities:
#   - validate poll options, expiration, and response references
#   - add inbound poll parameters consumed by CommonAPI
#   - derive kind 1068 and kind 1018 publication destinations
#   - submit received responses through CommonAPI vote authorization
#
# This file intentionally does NOT count votes independently, bypass local poll
# limits, or treat relay events as trusted database updates.

defmodule Pleroma.Nostr.Poll do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Web.CommonAPI

  @max_option_id_bytes 64

  def validate(%{"kind" => 1_068} = event) do
    case inbound_params(event) do
      {:ok, _params} -> :ok
      {:error, reason} -> invalid(reason)
    end
  end

  def validate(_event), do: invalid("invalid poll event")

  def validate_response(%{"kind" => 1_018} = event) do
    poll_id = Protocol.tag_value(event, "e")
    responses = Protocol.tag_values(event, "response") |> Enum.uniq()

    cond do
      not hex_identifier?(poll_id) ->
        invalid("poll response requires a valid poll id")

      responses == [] ->
        invalid("poll response requires a choice")

      length(responses) > max_options() ->
        invalid("poll response has too many choices")

      not Enum.all?(responses, &valid_option_id?/1) ->
        invalid("poll response has an invalid choice")

      true ->
        :ok
    end
  end

  def validate_response(_event), do: invalid("invalid poll response")

  def inbound_params(event) do
    options = poll_options(event)
    option_ids = Enum.map(options, &elem(&1, 0))
    labels = Enum.map(options, &elem(&1, 1))
    expires_in = poll_expiration(event)

    cond do
      options == [] ->
        {:error, "poll requires options"}

      length(options) > max_options() ->
        {:error, "poll has too many options"}

      length(Enum.uniq(option_ids)) != length(option_ids) ->
        {:error, "poll option ids must be unique"}

      length(Enum.uniq(labels)) != length(labels) ->
        {:error, "poll option labels must be unique"}

      not Enum.all?(option_ids, &valid_option_id?/1) ->
        {:error, "poll option id is invalid"}

      not Enum.all?(labels, &valid_option_label?/1) ->
        {:error, "poll option label is invalid"}

      not is_integer(expires_in) ->
        {:error, "poll expiration is missing or invalid"}

      true ->
        {:ok,
         %{
           options: labels,
           expires_in: max(expires_in, 1),
           multiple: Protocol.tag_value(event, "polltype") == "multiplechoice"
         }}
    end
  end

  def put_inbound_params(params, %{"kind" => 1_068} = event) when is_map(params) do
    case inbound_params(event) do
      {:ok, poll} -> Map.put(params, :poll, poll)
      {:error, _reason} -> params
    end
  end

  def put_inbound_params(params, _event), do: params

  def put_object_metadata(object, %{"kind" => 1_068} = event) when is_map(object) do
    case poll_closed_at(event) do
      closed_at when is_binary(closed_at) -> Map.put(object, "closed", closed_at)
      _closed_at -> object
    end
  end

  def put_object_metadata(object, _event), do: object

  def outbound_destination(%{"type" => "Question"} = object, destination) do
    poll_destination(object, destination)
  end

  def outbound_destination(%{"type" => "Answer"} = object, destination) do
    response_destination(object, destination)
  end

  def outbound_destination(_object, destination), do: destination

  def import_response(event, stored, relay_url) do
    with {:ok, actor} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         poll_id when is_binary(poll_id) <- Protocol.tag_value(event, "e"),
         %Event{kind: 1_068, ap_object_id: object_id} = poll <- Store.get(poll_id),
         %Object{data: %{"type" => "Question"}} = object <-
           Object.get_cached_by_ap_id(object_id),
         {:ok, choices} <- response_choices(event, poll.data),
         {:ok, activities, _object} <- CommonAPI.vote(object, actor, choices),
         %Activity{} = activity <- List.first(activities) do
      Store.map_activity(stored.id, activity.id, object_id)
    else
      # The relay still retains a valid event when the AP poll is unavailable
      # or its one-vote policy has already accepted an earlier response.
      _error -> :ok
    end
  end

  defp poll_destination(object, {default_kind, default_tags, default_relays}) do
    options = object_options(object)
    ends_at = object_ends_at(object)

    if options != [] and is_integer(ends_at) do
      option_tags =
        options
        |> Enum.with_index()
        |> Enum.map(fn {label, index} -> ["option", Integer.to_string(index), label] end)

      polltype = if is_list(object["anyOf"]), do: "multiplechoice", else: "singlechoice"
      relay_tags = default_relays |> normalize_relays() |> Enum.map(&["relay", &1])

      {1_068,
       default_tags ++
         option_tags ++ relay_tags ++ [["polltype", polltype], ["endsAt", to_string(ends_at)]],
       default_relays}
    else
      {default_kind, default_tags, default_relays}
    end
  end

  defp response_destination(object, destination) do
    with parent_id when is_binary(parent_id) <- object["inReplyTo"],
         %Event{kind: 1_068} = poll <- Store.get_by_ap_object_id(parent_id),
         [_response | _rest] = response_ids <- response_ids_for_actor(object, poll.data) do
      relays =
        (Protocol.tag_values(poll.data, "relay") ++ destination_relays(destination))
        |> normalize_relays()

      tags = [["e", poll.id]] ++ Enum.map(response_ids, &["response", &1])
      {1_018, tags, relays}
    else
      _error -> destination
    end
  end

  defp response_choices(event, poll_event) do
    option_ids = poll_options(poll_event) |> Enum.map(&elem(&1, 0))

    choices =
      event
      |> Protocol.tag_values("response")
      |> Enum.uniq()
      |> Enum.flat_map(fn response_id ->
        case Enum.find_index(option_ids, &(&1 == response_id)) do
          nil -> []
          index -> [index]
        end
      end)

    polltype = Protocol.tag_value(poll_event, "polltype") || "singlechoice"
    choices = if polltype == "singlechoice", do: Enum.take(choices, 1), else: choices

    if choices == [], do: {:error, :invalid_choices}, else: {:ok, choices}
  end

  defp response_ids_for_actor(object, poll_event) do
    option_lookup = Map.new(poll_options(poll_event), fn {id, label} -> {label, id} end)
    actor = object["actor"] || object["attributedTo"]
    parent_id = object["inReplyTo"]

    answer_names =
      Object
      |> where([answer], fragment("?->>'type' = ?", answer.data, "Answer"))
      |> where([answer], fragment("?->>'actor' = ?", answer.data, ^actor))
      |> where([answer], fragment("?->>'inReplyTo' = ?", answer.data, ^parent_id))
      |> select([answer], fragment("?->>'name'", answer.data))
      |> Repo.all()
      |> Kernel.++([object["name"]])

    answer_names
    |> Enum.map(&Map.get(option_lookup, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(max_options())
  end

  defp poll_options(event) do
    event
    |> Map.get("tags", [])
    |> Enum.flat_map(fn
      ["option", id, label | _rest] when is_binary(id) and is_binary(label) -> [{id, label}]
      _tag -> []
    end)
  end

  defp object_options(object) do
    (object["anyOf"] || object["oneOf"] || [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) and name != "" ->
        [String.slice(name, 0, max_option_chars())]

      _option ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(max_options())
  end

  defp object_ends_at(%{"closed" => closed}) when is_binary(closed) do
    case DateTime.from_iso8601(closed) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _datetime -> nil
    end
  end

  defp object_ends_at(_object), do: nil

  defp poll_expiration(event) do
    with value when is_binary(value) <- Protocol.tag_value(event, "endsAt"),
         {ends_at, ""} <- Integer.parse(value) do
      ends_at - System.system_time(:second)
    else
      _value -> nil
    end
  end

  defp poll_closed_at(event) do
    with value when is_binary(value) <- Protocol.tag_value(event, "endsAt"),
         {ends_at, ""} <- Integer.parse(value),
         {:ok, datetime} <- DateTime.from_unix(ends_at) do
      DateTime.to_iso8601(datetime)
    else
      _value -> nil
    end
  end

  defp valid_option_id?(value) do
    is_binary(value) and byte_size(value) in 1..@max_option_id_bytes and
      Regex.match?(~r/^[A-Za-z0-9]+$/, value)
  end

  defp valid_option_label?(value) do
    is_binary(value) and String.length(value) in 1..max_option_chars() and
      not String.contains?(value, ["\0", "\r", "\n"])
  end

  defp destination_relays({_kind, _tags, relays}), do: List.wrap(relays)

  defp normalize_relays(relays) do
    relays
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&Nostr.allowed_relay?/1)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp poll_limits do
    Config.get([:instance, :poll_limits], %{
      max_options: 20,
      max_option_chars: 200
    })
  end

  defp max_options, do: Map.get(poll_limits(), :max_options, 20)
  defp max_option_chars, do: Map.get(poll_limits(), :max_option_chars, 200)

  defp hex_identifier?(value) do
    is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)
  end

  defp invalid(reason), do: {:error, "invalid", reason}
end

# end of nostr/poll.ex
