# Unfathomably BE
# ----------------
#
# File: nostr/private_messages.ex
#
# Purpose:
#   Project native Nostr private messages into the existing ActivityPub chat
#   model without exposing plaintext or private keys to browser clients.
#
# Responsibilities:
#   - validate NIP-17, NIP-44, and NIP-59 message envelopes
#   - publish server-side gift wraps for local ActivityPub actors
#   - decrypt gift wraps addressed to local actors
#   - retain NIP-17 private-message relay preferences
#   - map accepted messages into normal ChatMessage activities
#
# This file intentionally does NOT expose private keys, bridge attachments
# without encryption, or turn private messages into public status objects.

defmodule Pleroma.Nostr.PrivateMessages do
  require Logger

  alias Nostr.Event, as: NostrEvent
  alias Nostr.NIP17
  alias Nostr.NIP44
  alias Nostr.Tag, as: NostrTag
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Nostr, as: NostrBridge
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Keys
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  @gift_wrap_kind 1_059
  @seal_kind 13
  @message_kind 14
  @relay_list_kind 10_050
  @max_ciphertext_bytes 131_072
  @max_message_bytes 16_384
  @max_subject_bytes 256
  @max_relay_count 16
  @max_relay_metadata_tags 4
  @max_tag_count 64
  @max_tag_value_bytes 2_048
  @default_history_seconds 30 * 24 * 60 * 60

  def validate(%{"kind" => @gift_wrap_kind, "tags" => [["p", recipient]]} = event) do
    with {:ok, _validated_event} <- Protocol.validate_event(event),
         true <- valid_pubkey?(recipient),
         true <- bounded_binary?(event["content"], 1, @max_ciphertext_bytes) do
      :ok
    else
      _ -> invalid("NIP-59 gift wraps require one valid recipient and bounded ciphertext")
    end
  end

  def validate(%{"kind" => @relay_list_kind, "content" => content, "tags" => tags})
      when is_list(tags) do
    # NIP-31 and NIP-89 metadata is commonly attached to otherwise standard
    # events. It describes the event or client and must never become a relay
    # destination, so relay and metadata limits are counted independently.
    relay_count = Enum.count(tags, &match?(["relay", _relay_url], &1))
    metadata_count = length(tags) - relay_count

    if content == "" and relay_count <= @max_relay_count and
         metadata_count <= @max_relay_metadata_tags and
         Enum.all?(tags, &valid_relay_list_tag?/1) do
      :ok
    else
      invalid("NIP-17 relay lists may contain only bounded relay and metadata tags")
    end
  end

  def validate(_event), do: invalid("unsupported private-message event")

  def validate_outbound(%User{} = sender, %User{} = recipient, content, opts) do
    case Identity.get_by_user(recipient) do
      %Entity{kind: "mirror_profile"} ->
        if sender.local and not opts[:nostr_ingest] do
          cond do
            opts[:media_id] ->
              {:error, "Encrypted attachments are not yet supported for native Nostr chats"}

            not bounded_binary?(content, 1, @max_message_bytes) ->
              {:error, "Native Nostr chats require a non-empty text message"}

            true ->
              :ok
          end
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  def validate_outbound(_sender, _recipient, _content, _opts), do: :ok

  def publish_chat_message(
        %Activity{} = activity,
        %User{} = sender,
        %User{} = recipient,
        content,
        publisher
      )
      when is_function(publisher, 3) do
    with true <- NostrBridge.bridge_enabled?(),
         true <- sender.local,
         false <- Identity.mirror?(sender),
         %Entity{kind: "mirror_profile", pubkey: recipient_pubkey} = entity <-
           Identity.get_by_user(recipient),
         true <- bounded_binary?(content, 1, @max_message_bytes),
         {:ok, private_key} <- Keys.private_key("actor:#{sender.id}"),
         {:ok, gift_wraps} <- NIP17.send_dm(private_key, [recipient_pubkey], content),
         :ok <-
           publish_gift_wraps(
             gift_wraps,
             recipient_pubkey,
             recipient_relays(recipient, entity),
             sender_relays(),
             activity_mapping(activity),
             publisher
           ) do
      :ok
    else
      false -> :ok
      nil -> :ok
      {:error, _reason} = error -> error
      _other -> :ok
    end
  end

  def publish_chat_message(_activity, _sender, _recipient, _content, _publisher), do: :ok

  def publish_relay_list(
        %User{local: true},
        %Entity{},
        private_key,
        relays,
        publisher
      )
      when is_binary(private_key) and is_list(relays) and is_function(publisher, 3) do
    advertised_relays = sender_relays(relays)
    tags = Enum.map(advertised_relays, &["relay", &1])

    with {:ok, event} <- Protocol.sign_event(@relay_list_kind, tags, "", private_key),
         :ok <- publisher.(event, advertised_relays, []) do
      :ok
    end
  end

  def publish_relay_list(_actor, _entity, _private_key, _relays, _publisher), do: :ok

  def import_relay_list(%{"pubkey" => pubkey} = event, _relay_url) do
    with :ok <- validate(event),
         relays <- relay_tags(event),
         {:ok, _user} <-
           Identity.update_nostr_extension(pubkey, fn extension ->
             Map.put(extension, "dm_relays", relays)
           end) do
      :ok
    else
      _other -> :ok
    end
  end

  def import_relay_list(_event, _relay_url), do: :ok

  def import(%{"id" => event_id} = event, stored, relay_url) do
    result =
      with :ok <- validate(event),
           %Entity{kind: "local_actor", user: %User{} = recipient} <- local_recipient(event),
           true <- recipient.is_active,
           true <- recipient.accepts_chat_messages != false,
           {:ok, private_key} <- Keys.private_key("actor:#{recipient.id}"),
           {:ok, message} <- decode_message(event, private_key, recipient_pubkey(event)),
           {:ok, sender} <-
             Identity.resolve(%{
               type: :profile,
               pubkey: message.sender_pubkey,
               relays: [relay_url]
             }),
           {:ok, activity} <-
             CommonAPI.post_chat_message(sender, recipient, message.content,
               local: false,
               nostr_ingest: true,
               nostr_event_id: event_id,
               published: message.created_at,
               idempotency_key: "nostr-dm:#{event_id}"
             ) do
        object = Object.normalize(activity, fetch: false)
        object_id = object && object.data["id"]
        claim_projection(stored, activity, object_id)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("Discarding invalid or unauthorized Nostr private message",
          relay: relay_url,
          event_id: event_id,
          reason: inspect(reason)
        )

        :ok

      _other ->
        :ok
    end
  end

  def import(_event, _stored, _relay_url), do: :ok

  def decode_message(event, private_key, expected_recipient)
      when is_map(event) and is_binary(private_key) and is_binary(expected_recipient) do
    with :ok <- validate(event),
         {:ok, seal_json} <- safe_decrypt(event["content"], private_key, event["pubkey"]),
         {:ok, seal} <- decode_json_object(seal_json),
         :ok <- validate_seal(seal),
         {:ok, rumor_json} <- safe_decrypt(seal["content"], private_key, seal["pubkey"]),
         {:ok, rumor} <- decode_json_object(rumor_json),
         :ok <- validate_rumor(rumor, seal["pubkey"], expected_recipient) do
      {:ok,
       %{
         content: rumor["content"],
         created_at: DateTime.from_unix!(rumor["created_at"]),
         receivers: tag_values(rumor, "p"),
         reply_to: tag_values(rumor, "e") |> List.first(),
         sender_pubkey: rumor["pubkey"],
         subject: tag_values(rumor, "subject") |> List.first()
       }}
    end
  rescue
    _error -> {:error, :invalid_private_message}
  catch
    :exit, _reason -> {:error, :invalid_private_message}
  end

  def decode_message(_event, _private_key, _expected_recipient),
    do: {:error, :invalid_private_message}

  def subscription_since do
    seconds =
      case Config.get([NostrBridge, :private_message_history_seconds], @default_history_seconds) do
        value when is_integer(value) and value >= 300 and value <= 90 * 24 * 60 * 60 -> value
        _other -> @default_history_seconds
      end

    System.system_time(:second) - seconds
  end

  defp publish_gift_wraps(
         gift_wraps,
         recipient_pubkey,
         recipient_relays,
         sender_relays,
         mapping,
         publisher
       ) do
    Enum.reduce_while(gift_wraps, :ok, fn gift_wrap, :ok ->
      relays =
        if gift_wrap.recipient == recipient_pubkey, do: recipient_relays, else: sender_relays

      case publisher.(wire_event(gift_wrap.event), relays, mapping) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, other}}
      end
    end)
  end

  defp wire_event(%NostrEvent{} = event) do
    %{
      "id" => event.id,
      "pubkey" => event.pubkey,
      "kind" => event.kind,
      "tags" => Enum.map(event.tags, &wire_tag/1),
      "created_at" => DateTime.to_unix(event.created_at),
      "content" => event.content,
      "sig" => event.sig
    }
  end

  defp wire_tag(%NostrTag{type: type, data: nil}), do: [Atom.to_string(type)]

  defp wire_tag(%NostrTag{type: type, data: data, info: info}),
    do: [Atom.to_string(type), data | info]

  defp activity_mapping(activity) do
    object = Object.normalize(activity, fetch: false)

    [
      ap_activity_id: activity.id,
      ap_object_id: object && object.data["id"]
    ]
  end

  defp claim_projection(%{id: event_id}, activity, object_id) do
    case Store.claim_activity(event_id, activity.id, object_id) do
      {:ok, _claim} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp claim_projection(_stored, _activity, _object_id), do: :ok

  defp local_recipient(event) do
    event
    |> recipient_pubkey()
    |> Identity.get_profile()
  end

  defp recipient_pubkey(event), do: Protocol.tag_value(event, "p")

  defp recipient_relays(recipient, entity) do
    configured =
      case recipient.actor_extensions do
        %{"nostr" => %{"dm_relays" => relays}} -> List.wrap(relays)
        %{nostr: %{dm_relays: relays}} -> List.wrap(relays)
        _other -> []
      end

    candidates = configured ++ Identity.relay_urls(entity, :write)

    case allowed_relays(candidates) do
      [] ->
        allowed_relays(
          Identity.relay_urls(entity, :both) ++ NostrBridge.profile_discovery_relays()
        )

      relays ->
        relays
    end
  end

  defp sender_relays(extra_relays \\ []) do
    allowed_relays([
      NostrBridge.relay_url()
      | extra_relays ++ NostrBridge.profile_discovery_relays()
    ])
  end

  defp allowed_relays(relays) do
    relays
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&NostrBridge.allowed_relay?/1)
    |> Enum.uniq()
    |> Enum.take(@max_relay_count)
  end

  defp relay_tags(event) do
    event
    |> Protocol.tag_values("relay")
    |> allowed_relays()
  end

  defp safe_decrypt(payload, private_key, pubkey) do
    case NIP44.decrypt(payload, private_key, pubkey) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      _other -> {:error, :decrypt_failed}
    end
  rescue
    _error -> {:error, :decrypt_failed}
  catch
    :exit, _reason -> {:error, :decrypt_failed}
  end

  defp decode_json_object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = object} -> {:ok, object}
      _other -> {:error, :invalid_encrypted_json}
    end
  end

  defp validate_seal(%{"kind" => @seal_kind, "tags" => []} = seal) do
    case Protocol.validate_event(seal) do
      {:ok, _validated_seal} -> :ok
      _other -> {:error, :invalid_seal}
    end
  end

  defp validate_seal(_seal), do: {:error, :invalid_seal}

  defp validate_rumor(
         %{
           "id" => id,
           "pubkey" => pubkey,
           "kind" => @message_kind,
           "tags" => tags,
           "created_at" => created_at,
           "content" => content
         } = rumor,
         seal_pubkey,
         expected_recipient
       )
       when is_list(tags) and is_integer(created_at) do
    receivers = tag_values(rumor, "p")
    now = System.system_time(:second)

    cond do
      pubkey != seal_pubkey -> {:error, :sender_mismatch}
      not valid_pubkey?(pubkey) -> {:error, :invalid_sender}
      id != Protocol.compute_id(rumor) -> {:error, :invalid_rumor_id}
      created_at > now + 600 -> {:error, :future_message}
      not bounded_binary?(content, 1, @max_message_bytes) -> {:error, :invalid_content}
      length(tags) > @max_tag_count -> {:error, :too_many_tags}
      not Enum.all?(tags, &valid_message_tag?/1) -> {:error, :invalid_message_tag}
      expected_recipient not in receivers -> {:error, :recipient_mismatch}
      true -> :ok
    end
  end

  defp validate_rumor(_rumor, _seal_pubkey, _expected_recipient),
    do: {:error, :invalid_rumor}

  defp tag_values(%{"tags" => tags}, name) when is_list(tags) do
    Enum.flat_map(tags, fn
      [^name, value | _rest] when is_binary(value) -> [value]
      _other -> []
    end)
  end

  defp tag_values(_event, _name), do: []

  defp valid_message_tag?(["p", pubkey | rest]) do
    valid_pubkey?(pubkey) and valid_tag_tail?(rest)
  end

  defp valid_message_tag?(["e", event_id | rest]) do
    valid_hex_id?(event_id) and valid_tag_tail?(rest)
  end

  defp valid_message_tag?(["q", event_id | rest]) do
    valid_hex_id?(event_id) and valid_tag_tail?(rest)
  end

  defp valid_message_tag?(["subject", subject]) do
    bounded_binary?(subject, 0, @max_subject_bytes)
  end

  defp valid_message_tag?(_tag), do: false

  defp valid_tag_tail?(values) when is_list(values) do
    Enum.all?(values, &bounded_binary?(&1, 0, @max_tag_value_bytes))
  end

  defp valid_relay_list_tag?(["relay", relay_url]) when is_binary(relay_url) do
    is_binary(Protocol.normalize_relay_url(relay_url))
  end

  defp valid_relay_list_tag?(["alt", description]) do
    bounded_binary?(description, 1, @max_tag_value_bytes)
  end

  defp valid_relay_list_tag?(["client", identifier | rest]) do
    bounded_binary?(identifier, 1, @max_tag_value_bytes) and valid_tag_tail?(rest)
  end

  defp valid_relay_list_tag?(_tag), do: false

  defp valid_pubkey?(value), do: valid_hex_id?(value)

  defp valid_hex_id?(value) when is_binary(value),
    do: Regex.match?(~r/^[0-9a-f]{64}$/, value)

  defp valid_hex_id?(_value), do: false

  defp bounded_binary?(value, minimum, maximum) when is_binary(value) do
    byte_size(value) >= minimum and byte_size(value) <= maximum
  end

  defp bounded_binary?(_value, _minimum, _maximum), do: false

  defp invalid(message), do: {:error, "invalid", message}
end

# end of nostr/private_messages.ex
