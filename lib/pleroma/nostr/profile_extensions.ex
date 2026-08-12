# Unfathomably Nostr bridge
#
# File: profile_extensions.ex
# Purpose: Translate Nostr live statuses and profile badges.
# Responsibilities: Validate, resolve, publish, and present NIP-38/NIP-58 data.
# This file intentionally does not grant roles or perform ActivityPub authorization.

defmodule Pleroma.Nostr.ProfileExtensions do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection
  alias Pleroma.Nostr.RelayManager
  alias Pleroma.Nostr.Semantics
  alias Pleroma.Nostr.Store
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.MediaProxy

  @badge_award_kind 8
  @profile_badges_kind 10_008
  @legacy_profile_badges_kind 30_008
  @badge_definition_kind 30_009
  @status_kind 30_315
  @max_badges 8
  @max_statuses 8
  @max_status_bytes 1_000
  @max_status_type_bytes 64
  @max_badge_identifier_bytes 64
  @max_reference_fetch_ms 1_500
  @max_profile_scan 500
  @hex_key ~r/\A[0-9a-f]{64}\z/
  @status_type ~r/\A[a-zA-Z0-9._-]+\z/

  def validate(%{"kind" => @status_kind} = event) do
    status_type = Protocol.tag_value(event, "d")
    content = event["content"]

    cond do
      not valid_status_type?(status_type) ->
        invalid("user status requires one bounded d tag")

      not is_binary(content) or byte_size(content) > @max_status_bytes ->
        invalid("user status content is too large")

      true ->
        :ok
    end
  end

  def validate(%{"kind" => @badge_award_kind} = event) do
    coordinates = Protocol.tag_values(event, "a")
    recipients = Protocol.tag_values(event, "p")

    if length(coordinates) == 1 and valid_badge_coordinate?(hd(coordinates)) and
         recipients != [] and Enum.all?(recipients, &valid_pubkey?/1) do
      :ok
    else
      invalid("badge award requires one definition and at least one valid recipient")
    end
  end

  def validate(%{"kind" => @badge_definition_kind} = event) do
    if valid_badge_identifier?(Protocol.tag_value(event, "d")) do
      :ok
    else
      invalid("badge definition requires a bounded d tag")
    end
  end

  def validate(%{"kind" => @profile_badges_kind} = event), do: validate_profile_badges(event)

  def validate(%{"kind" => @legacy_profile_badges_kind} = event) do
    if Protocol.tag_value(event, "d") == "profile_badges" do
      validate_profile_badges(event)
    else
      :ok
    end
  end

  def validate(_event), do: :ok

  def import(%{"kind" => @status_kind} = event, relay_url, _importer),
    do: import_status(event, relay_url)

  def import(%{"kind" => kind} = event, relay_url, importer)
      when kind in [@profile_badges_kind, @legacy_profile_badges_kind] do
    if kind == @profile_badges_kind or Protocol.tag_value(event, "d") == "profile_badges" do
      with {:ok, _user} <- ensure_profile(event["pubkey"], relay_url) do
        fetch_missing_badge_events(event, relay_url, importer)
        refresh_badges(event["pubkey"])
      end
    else
      :ok
    end
  end

  def import(%{"kind" => @badge_award_kind} = event, _relay_url, _importer) do
    event
    |> Protocol.tag_values("p")
    |> Enum.uniq()
    |> Enum.take(32)
    |> Enum.each(&refresh_badges/1)

    :ok
  end

  def import(%{"kind" => @badge_definition_kind} = event, _relay_url, _importer) do
    refresh_profiles_referencing(badge_coordinate(event))
    :ok
  end

  def import(_event, _relay_url, _importer), do: :ok

  def presentation(%User{} = user) do
    extension = get_in(user.actor_extensions || %{}, ["nostr"]) || %{}

    %{
      badges: extension |> Map.get("badges", []) |> sanitize_presented_badges(),
      statuses: extension |> Map.get("statuses", %{}) |> active_statuses()
    }
  end

  def presentation(_user), do: %{badges: [], statuses: []}

  def status_payload(%{"kind" => @status_kind} = event) do
    status_type = Protocol.tag_value(event, "d")
    expiration = Semantics.expiration(event)

    if event["content"] == "" or Semantics.expired?(event) do
      {:clear, status_type}
    else
      {:set,
       %{
         "type" => status_type,
         "content" => event["content"],
         "url" => bounded_reference(Protocol.tag_value(event, "r")),
         "profile" => bounded_reference(Protocol.tag_value(event, "p")),
         "event" => bounded_reference(Protocol.tag_value(event, "e")),
         "address" => bounded_reference(Protocol.tag_value(event, "a")),
         "expires_at" => unix_iso8601(expiration),
         "created_at" => unix_iso8601(event["created_at"]),
         "event_id" => event["id"]
       }
       |> compact_map()}
    end
  end

  def status_payload(_event), do: {:error, :not_status}

  def publish_listen(%Activity{} = activity, %User{} = actor, publisher)
      when is_function(publisher, 6) do
    with visibility when visibility in ["public", "unlisted"] <-
           Visibility.get_visibility(activity),
         %Object{data: data} <- Object.normalize(activity, fetch: false),
         content when is_binary(content) and content != "" <- listen_content(data) do
      expiration = System.system_time(:second) + listen_duration(data)
      url = safe_http_url(data["externalLink"] || data["url"] || data["id"])

      tags =
        [["d", "music"], ["expiration", Integer.to_string(expiration)]] ++
          if(url, do: [["r", url]], else: [])

      relays = publication_relays()

      case publisher.(actor, @status_kind, tags, content, relays, ap_activity_id: activity.id) do
        :ok ->
          cache_local_status(actor, content, url, expiration, activity.id)

        error ->
          error
      end
    else
      _ -> :ok
    end
  end

  def publish_listen(_activity, _actor, _publisher), do: :ok

  def publish_local_badges(
        %User{local: true} = actor,
        %Entity{pubkey: pubkey},
        private_key,
        relays,
        publisher
      )
      when is_binary(private_key) and is_function(publisher, 3) do
    actor
    |> local_badge_slugs()
    |> Enum.reduce_while({:ok, []}, fn slug, {:ok, tags} ->
      coordinate = "#{@badge_definition_kind}:#{pubkey}:#{slug}"

      with :ok <- publish_badge_definition(slug, private_key, relays, publisher),
           {:ok, award_id} <-
             badge_award_id(coordinate, pubkey, private_key, relays, publisher) do
        {:cont, {:ok, tags ++ [["a", coordinate], ["e", award_id, List.first(relays) || ""]]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, profile_tags} ->
        publish_event(@profile_badges_kind, profile_tags, "", private_key, relays, publisher)

      error ->
        error
    end
  end

  def publish_local_badges(_actor, _entity, _private_key, _relays, _publisher), do: :ok

  defp invalid(message), do: {:error, "invalid", message}

  defp validate_profile_badges(event) do
    pairs = badge_pairs(event)

    if Enum.all?(pairs, fn {coordinate, award_id} ->
         valid_badge_coordinate?(coordinate) and valid_event_id?(award_id)
       end) do
      :ok
    else
      invalid("profile badge selection contains malformed references")
    end
  end

  defp import_status(event, relay_url) do
    with {:ok, _user} <- ensure_profile(event["pubkey"], relay_url) do
      Identity.update_nostr_extension(event["pubkey"], fn extension ->
        statuses = Map.get(extension, "statuses", %{})

        statuses =
          case status_payload(event) do
            {:set, status} -> put_bounded_status(statuses, status)
            {:clear, status_type} -> Map.delete(statuses, status_type)
            _ -> statuses
          end

        Map.put(extension, "statuses", statuses)
      end)
      |> normalize_update()
    end
  end

  defp ensure_profile(pubkey, relay_url) do
    Identity.resolve(%{type: :profile, pubkey: pubkey, relays: [relay_url]})
  end

  defp refresh_badges(pubkey) when is_binary(pubkey) do
    case Identity.get_profile(pubkey) do
      %Entity{} ->
        badges =
          pubkey
          |> latest_profile_badges_event()
          |> render_profile_badges(pubkey)

        Identity.update_nostr_extension(pubkey, &Map.put(&1, "badges", badges))
        |> normalize_update()

      _ ->
        :ok
    end
  end

  defp refresh_badges(_pubkey), do: :ok

  defp latest_profile_badges_event(pubkey) do
    Event
    |> where([event], event.pubkey == ^pubkey)
    |> where([event], event.kind in [@profile_badges_kind, @legacy_profile_badges_kind])
    |> order_by([event], desc: event.created_at)
    |> limit(20)
    |> Repo.all()
    |> Enum.find(fn event ->
      event.kind == @profile_badges_kind or
        Protocol.tag_value(event.data, "d") == "profile_badges"
    end)
  end

  defp render_profile_badges(nil, _pubkey), do: []

  defp render_profile_badges(%Event{data: event}, pubkey) do
    event
    |> badge_pairs()
    |> Enum.take(@max_badges)
    |> Enum.flat_map(fn {coordinate, award_id} ->
      case render_badge(coordinate, award_id, pubkey) do
        badge when is_map(badge) -> [badge]
        _ -> []
      end
    end)
  end

  defp render_badge(coordinate, award_id, profile_pubkey) do
    with {:ok, issuer, slug} <- parse_badge_coordinate(coordinate),
         %Event{kind: @badge_award_kind, pubkey: ^issuer, data: award} <- Store.get(award_id),
         true <- coordinate in Protocol.tag_values(award, "a"),
         true <- profile_pubkey in Protocol.tag_values(award, "p"),
         %Event{data: definition} <- badge_definition_event(issuer, slug) do
      image = safe_media_url(Protocol.tag_value(definition, "image"))
      thumbnail = definition |> Protocol.tag_values("thumb") |> Enum.find_value(&safe_media_url/1)

      %{
        "id" => coordinate,
        "name" => bounded_text(Protocol.tag_value(definition, "name") || humanize_slug(slug), 80),
        "description" => bounded_text(Protocol.tag_value(definition, "description"), 500),
        "image" => image,
        "thumbnail" => thumbnail || image,
        "issuer" => issuer,
        "award_event_id" => award_id
      }
      |> compact_map()
    else
      _ -> nil
    end
  end

  defp badge_definition_event(issuer, slug) do
    Event
    |> where([event], event.kind == @badge_definition_kind and event.pubkey == ^issuer)
    |> order_by([event], desc: event.created_at)
    |> limit(50)
    |> Repo.all()
    |> Enum.find(&(Protocol.tag_value(&1.data, "d") == slug))
  end

  defp fetch_missing_badge_events(event, relay_url, importer) when is_function(importer, 3) do
    # NIP-58 does not impose our local presentation limit on a signed profile
    # selection. Store the complete bounded event, but only resolve references
    # that can appear in the local profile view.
    pairs = event |> badge_pairs() |> Enum.take(@max_badges)

    missing_awards =
      pairs
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&is_nil(Store.get(&1)))
      |> Enum.uniq()

    definition_filters =
      pairs
      |> Enum.flat_map(fn {coordinate, _award_id} ->
        case parse_badge_coordinate(coordinate) do
          {:ok, issuer, slug} ->
            if badge_definition_event(issuer, slug), do: [], else: [{issuer, slug}]

          _ ->
            []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {issuer, slugs} ->
        %{
          "authors" => [issuer],
          "kinds" => [@badge_definition_kind],
          "#d" => Enum.uniq(slugs),
          "limit" => min(length(slugs), @max_badges)
        }
      end)

    filters =
      if(missing_awards == [],
        do: definition_filters,
        else: [%{"ids" => missing_awards, "limit" => length(missing_awards)} | definition_filters]
      )

    request_reference_events(relay_url, filters, importer)
  end

  defp request_reference_events(_relay_url, [], _importer), do: :ok

  defp request_reference_events(relay_url, filters, importer) do
    subscription_id = "unf-badges-#{System.unique_integer([:positive, :monotonic])}"
    RelayManager.ensure_connection(relay_url)

    case RelayConnection.request(
           relay_url,
           subscription_id,
           filters,
           self(),
           @max_reference_fetch_ms
         ) do
      :ok ->
        deadline = System.monotonic_time(:millisecond) + @max_reference_fetch_ms
        collect_reference_events(relay_url, subscription_id, filters, importer, deadline)

      _ ->
        :ok
    end
  end

  defp collect_reference_events(relay_url, subscription_id, filters, importer, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:nostr_relay_event, ^relay_url, ^subscription_id, raw_event} ->
        _ = importer.(raw_event, relay_url, {:nip58_reference, filters})
        collect_reference_events(relay_url, subscription_id, filters, importer, deadline)

      {:nostr_relay_eose, ^relay_url, ^subscription_id, _reason} ->
        :ok
    after
      remaining -> :ok
    end
  end

  defp refresh_profiles_referencing(nil), do: :ok

  defp refresh_profiles_referencing(coordinate) do
    Event
    |> where([event], event.kind in [@profile_badges_kind, @legacy_profile_badges_kind])
    |> order_by([event], desc: event.created_at)
    |> limit(@max_profile_scan)
    |> Repo.all()
    |> Enum.filter(fn event -> coordinate in Protocol.tag_values(event.data, "a") end)
    |> Enum.map(& &1.pubkey)
    |> Enum.uniq()
    |> Enum.each(&refresh_badges/1)
  end

  defp badge_coordinate(event) do
    with pubkey when is_binary(pubkey) <- event["pubkey"],
         slug when is_binary(slug) <- Protocol.tag_value(event, "d") do
      "#{@badge_definition_kind}:#{pubkey}:#{slug}"
    end
  end

  defp badge_pairs(event), do: event |> Map.get("tags", []) |> do_badge_pairs([])

  defp do_badge_pairs([["a", coordinate | _], ["e", award_id | _] | rest], pairs),
    do: do_badge_pairs(rest, [{coordinate, award_id} | pairs])

  defp do_badge_pairs([_tag | rest], pairs), do: do_badge_pairs(rest, pairs)
  defp do_badge_pairs([], pairs), do: Enum.reverse(pairs)
  defp do_badge_pairs(_tags, pairs), do: Enum.reverse(pairs)

  defp publish_badge_definition(slug, private_key, relays, publisher) do
    tags = [
      ["d", slug],
      ["name", humanize_slug(slug)],
      ["description", "Visible ActivityPub profile badge"]
    ]

    publish_event(@badge_definition_kind, tags, "", private_key, relays, publisher)
  end

  defp badge_award_id(coordinate, pubkey, private_key, relays, publisher) do
    case existing_badge_award(coordinate, pubkey) do
      %Event{id: id} ->
        {:ok, id}

      nil ->
        with {:ok, event} <-
               Protocol.sign_event(
                 @badge_award_kind,
                 [["a", coordinate], ["p", pubkey]],
                 "",
                 private_key
               ),
             :ok <- publisher.(event, relays, []) do
          {:ok, event["id"]}
        end
    end
  end

  defp existing_badge_award(coordinate, pubkey) do
    Event
    |> where([event], event.kind == @badge_award_kind and event.pubkey == ^pubkey)
    |> order_by([event], desc: event.created_at)
    |> limit(100)
    |> Repo.all()
    |> Enum.find(fn event ->
      coordinate in Protocol.tag_values(event.data, "a") and
        pubkey in Protocol.tag_values(event.data, "p")
    end)
  end

  defp publish_event(kind, tags, content, private_key, relays, publisher) do
    with {:ok, event} <- Protocol.sign_event(kind, tags, content, private_key),
         :ok <- publisher.(event, relays, []) do
      :ok
    end
  end

  defp publication_relays do
    [Nostr.relay_url() | Nostr.configured_relays()]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp cache_local_status(actor, content, url, expiration, activity_id) do
    case Identity.get_by_user(actor) do
      %Entity{pubkey: pubkey} ->
        Identity.update_nostr_extension(pubkey, fn extension ->
          statuses = Map.get(extension, "statuses", %{})

          status =
            %{
              "type" => "music",
              "content" => content,
              "url" => url,
              "expires_at" => unix_iso8601(expiration),
              "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "activity_id" => activity_id
            }
            |> compact_map()

          Map.put(extension, "statuses", put_bounded_status(statuses, status))
        end)
        |> normalize_update()

      _ ->
        :ok
    end
  end

  defp listen_content(data) do
    title = bounded_text(data["name"] || data["title"], 300)

    artist =
      case data["artist"] || data["attributedTo"] do
        %{"name" => name} when is_binary(name) ->
          bounded_text(name, 200)

        value when is_binary(value) ->
          if String.starts_with?(value, ["http://", "https://"]),
            do: nil,
            else: bounded_text(value, 200)

        _ ->
          nil
      end

    case {title, artist} do
      {nil, _} -> nil
      {title, nil} -> title
      {title, artist} -> "#{title} - #{artist}"
    end
  end

  defp listen_duration(data) do
    case data["duration"] do
      value when is_integer(value) and value in 1..86_400 -> value
      value when is_binary(value) -> parse_duration(value)
      _ -> 300
    end
  end

  defp parse_duration(value) do
    case Regex.run(~r/\APT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?\z/, value) do
      [_, hours, minutes, seconds] ->
        (duration_part(hours) * 3_600 + duration_part(minutes) * 60 + duration_part(seconds))
        |> max(1)
        |> min(86_400)

      _ ->
        case Integer.parse(value) do
          {seconds, ""} -> seconds |> max(1) |> min(86_400)
          _ -> 300
        end
    end
  end

  defp duration_part(""), do: 0
  defp duration_part(nil), do: 0
  defp duration_part(value), do: String.to_integer(value)

  defp local_badge_slugs(%User{tags: tags}) do
    tags
    |> List.wrap()
    |> Enum.flat_map(fn
      "badge:" <> slug -> if(valid_local_badge_slug?(slug), do: [slug], else: [])
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_badges)
  end

  defp active_statuses(statuses) when is_map(statuses) do
    statuses
    |> Map.values()
    |> Enum.filter(&active_status?/1)
    |> Enum.sort_by(&Map.get(&1, "created_at", ""), :desc)
    |> Enum.take(@max_statuses)
  end

  defp active_statuses(_statuses), do: []

  defp active_status?(%{"content" => content} = status)
       when is_binary(content) and content != "" do
    case Map.get(status, "expires_at") do
      nil ->
        true

      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, expires_at, _offset} -> DateTime.compare(expires_at, DateTime.utc_now()) == :gt
          _ -> false
        end

      _ ->
        false
    end
  end

  defp active_status?(_status), do: false

  defp sanitize_presented_badges(badges) when is_list(badges) do
    badges
    |> Enum.filter(&is_map/1)
    |> Enum.take(@max_badges)
  end

  defp sanitize_presented_badges(_badges), do: []

  defp put_bounded_status(statuses, %{"type" => status_type} = status) do
    statuses = if is_map(statuses), do: statuses, else: %{}
    statuses = Map.put(statuses, status_type, status)

    if map_size(statuses) <= @max_statuses do
      statuses
    else
      statuses
      |> Enum.sort_by(fn {_type, value} -> Map.get(value, "created_at", "") end, :desc)
      |> Enum.take(@max_statuses)
      |> Map.new()
    end
  end

  defp valid_status_type?(value) when is_binary(value) do
    byte_size(value) in 1..@max_status_type_bytes and Regex.match?(@status_type, value)
  end

  defp valid_status_type?(_value), do: false

  defp valid_local_badge_slug?(value) when is_binary(value) do
    valid_badge_identifier?(value) and Regex.match?(@status_type, value)
  end

  defp valid_local_badge_slug?(_value), do: false

  defp valid_badge_identifier?(value) when is_binary(value) do
    # NIP-58 uses the addressable event's d value as an opaque identifier.
    # Remote identifiers may contain spaces or Unicode, while local badge tags
    # retain the stricter slug rule above because administrators type them.
    byte_size(value) in 1..@max_badge_identifier_bytes and String.valid?(value) and
      Enum.all?(String.to_charlist(value), fn character ->
        character >= 0x20 and character != 0x7F
      end)
  end

  defp valid_badge_identifier?(_value), do: false

  defp valid_badge_coordinate?(coordinate),
    do: match?({:ok, _, _}, parse_badge_coordinate(coordinate))

  defp parse_badge_coordinate(coordinate) when is_binary(coordinate) do
    case String.split(coordinate, ":", parts: 3) do
      ["30009", issuer, slug] ->
        if valid_pubkey?(issuer) and valid_badge_identifier?(slug),
          do: {:ok, issuer, slug},
          else: :error

      _ ->
        :error
    end
  end

  defp parse_badge_coordinate(_coordinate), do: :error

  defp valid_pubkey?(value), do: is_binary(value) and Regex.match?(@hex_key, value)
  defp valid_event_id?(value), do: valid_pubkey?(value)

  defp safe_http_url(value) when is_binary(value) do
    if String.starts_with?(value, ["https://", "http://"]) and byte_size(value) <= 2_048,
      do: value
  end

  defp safe_http_url(_value), do: nil

  defp safe_media_url(value) do
    case safe_http_url(value) do
      nil -> nil
      url -> MediaProxy.url(url)
    end
  end

  defp bounded_reference(value) when is_binary(value) and byte_size(value) <= 2_048, do: value
  defp bounded_reference(_value), do: nil

  defp bounded_text(value, maximum) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: String.slice(value, 0, maximum)
  end

  defp bounded_text(_value, _maximum), do: nil

  defp humanize_slug(slug) do
    slug
    |> String.replace(~r/[-_.]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp unix_iso8601(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp unix_iso8601(_value), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_update({:ok, _user}), do: :ok
  defp normalize_update(:ok), do: :ok
  defp normalize_update(error), do: error
end

# end of profile_extensions.ex
