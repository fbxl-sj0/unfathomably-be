# Unfathomably BE
# ----------------
#
# File: nostr/identity.ex
#
# Purpose:
#   Present Nostr profiles and relay-scoped groups through ordinary User APIs.
#
# Responsibilities:
#   - create collision-resistant bridge mirror users
#   - update profile and NIP-29 metadata from verified events
#   - derive local ActivityPub actor Nostr identities
#   - expose protocol classification and relay lookup helpers
#
# This file intentionally does NOT authenticate Nostr events, perform follows,
# or publish timeline activities.

defmodule Pleroma.Nostr.Identity do
  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Keys
  alias Pleroma.Nostr.NIP05
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayManager
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.WebFinger

  @profile_metadata_keys ~w(name display_name displayName username about picture banner nip05 website lud16 lud06 bot birthday)
  @external_identity_providers ~w(github twitter mastodon telegram)
  @max_external_identities 16
  @max_profile_emojis 64
  @max_group_directory_members 500

  def resolve(%{type: :profile, pubkey: pubkey} = identity) do
    with true <- valid_pubkey?(pubkey) do
      case get_profile(pubkey) do
        %Entity{user: %User{} = user} ->
          maybe_add_relay(identity, user)
          {:ok, user}

        _ ->
          create_profile(pubkey, allowed_relays(identity.relays))
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve(%{type: :group, group_id: group_id, pubkey: pubkey} = identity) do
    relays = allowed_group_relays(identity.relays)

    with true <- valid_group_id?(group_id),
         true <- valid_pubkey?(pubkey),
         [relay_url | _rest] <- relays do
      case get_group(relay_url, group_id) do
        %Entity{user: %User{} = user} ->
          {:ok, user}

        _ ->
          create_group(pubkey, relay_url, group_id)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve(_identity), do: {:error, :not_found}

  def get_profile(pubkey) do
    Entity
    |> where(pubkey: ^pubkey)
    |> where([entity], is_nil(entity.group_id))
    |> preload(:user)
    |> Repo.one()
  end

  def get_group(_relay_url, group_id) when not is_binary(group_id) or group_id == "", do: nil

  def get_group(relay_url, group_id) do
    Entity
    |> where(relay_url: ^relay_url, group_id: ^group_id)
    |> preload(:user)
    |> Repo.one()
  end

  def get_by_user(%User{id: id}), do: get_by_user_id(id)
  def get_by_user(_user), do: nil

  def get_by_user_id(nil), do: nil

  def get_by_user_id(user_id) do
    Entity
    |> where(user_id: ^user_id)
    |> preload(:user)
    |> Repo.one()
  end

  def nostr?(%User{} = user), do: match?(%Entity{}, get_by_user(user))
  def nostr?(_user), do: false

  def nostr_group?(%User{} = user) do
    match?(%Entity{kind: "mirror_group"}, get_by_user(user))
  end

  def nostr_group?(_user), do: false

  def mirror?(%User{} = user) do
    case get_by_user(user) do
      %Entity{kind: kind} when kind in ["mirror_profile", "mirror_group"] -> true
      _ -> false
    end
  end

  def mirror?(_user), do: false

  def local_actor(%User{} = user) do
    case get_by_user(user) do
      %Entity{kind: "local_actor"} = entity ->
        {:ok, entity}

      %Entity{kind: "local_group"} = entity ->
        {:ok, entity}

      %Entity{kind: kind} when kind in ["mirror_profile", "mirror_group"] ->
        {:error, :mirror_identity}

      nil ->
        create_local_actor(user)
    end
  end

  def local_group(%User{local: true, actor_type: "Group"} = group) do
    case get_by_user(group) do
      %Entity{kind: "local_group"} = entity ->
        {:ok, entity}

      nil ->
        create_local_group(group)

      _ ->
        {:error, :identity_conflict}
    end
  end

  def local_group(_group), do: {:error, :not_local_group}

  def local_nip05(%User{local: true, nickname: nickname}) when is_binary(nickname) do
    name =
      nickname
      |> String.split("@", parts: 2)
      |> List.first()
      |> String.downcase()

    identifier = "#{name}@#{String.downcase(WebFinger.domain())}"

    case NIP05.parse_identifier(identifier) do
      {:ok, %{display: display}} -> display
      _ -> nil
    end
  end

  def local_nip05(_user), do: nil

  def update_profile(event, relay_url) do
    with {:ok, user} <- resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         {:ok, metadata} <- decode_profile_metadata(event["content"]),
         %Entity{} = entity <- get_by_user(user) do
      metadata =
        metadata
        |> normalize_profile_metadata()
        |> Map.put("emojis", profile_emojis(event))
        |> validate_nip05(event["pubkey"])

      merged_metadata = Map.merge(entity.metadata || %{}, metadata)

      presentation_entity = %{
        entity
        | relay_url: preferred_profile_relay(entity.relay_url, relay_url)
      }

      attrs = profile_user_attrs(merged_metadata, event["pubkey"], presentation_entity, user)

      with {:ok, user} <- update_user(user, attrs),
           {:ok, _entity} <-
             update_entity(entity, metadata, event["id"], relay_url) do
        {:ok, user}
      end
    else
      _ -> {:error, :invalid_metadata}
    end
  end

  def update_external_identities(event, relay_url) do
    with {:ok, user} <-
           resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         %Entity{} = entity <- get_by_user(user) do
      snapshot = %{"external_identities" => external_identities(event)}
      metadata = Map.merge(entity.metadata || %{}, snapshot)

      presentation_entity = %{
        entity
        | relay_url: preferred_profile_relay(entity.relay_url, relay_url)
      }

      attrs = profile_user_attrs(metadata, event["pubkey"], presentation_entity, user)

      with {:ok, user} <- update_user(user, attrs),
           {:ok, _entity} <- update_entity(entity, snapshot, event["id"], relay_url) do
        {:ok, user}
      end
    else
      _ -> {:error, :invalid_external_identities}
    end
  end

  def update_relay_list(event, relay_url) do
    with {:ok, user} <-
           resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         %Entity{} = entity <- get_by_user(user) do
      metadata =
        Map.put(
          entity.metadata || %{},
          "relay_list",
          relay_list_from_event(event)
        )

      with {:ok, entity} <- update_entity(entity, metadata, event["id"], relay_url) do
        RelayManager.sync_now()
        {:ok, entity}
      end
    else
      _ -> {:error, :invalid_relay_list}
    end
  end

  def promote_native_relay(%{"pubkey" => pubkey}, relay_url) do
    with false <- Nostr.compatibility_relay?(relay_url),
         %Entity{kind: "mirror_profile", user: %User{} = user} = entity <-
           get_profile(pubkey),
         preferred when preferred != entity.relay_url <-
           preferred_profile_relay(entity.relay_url, relay_url) do
      presentation_entity = %{entity | relay_url: preferred}

      nostr_extension =
        (get_in(user.actor_extensions || %{}, ["nostr"]) || %{})
        |> Map.put("pubkey", pubkey)
        |> Map.put("relay", preferred)
        |> Map.put("relays", relay_urls(presentation_entity, :both))
        |> Map.put("mirror", true)

      with {:ok, _entity} <-
             entity
             |> Entity.changeset(%{relay_url: preferred})
             |> Repo.update(),
           {:ok, _user} <-
             update_user(user, %{
               actor_extensions: Map.put(user.actor_extensions || %{}, "nostr", nostr_extension)
             }) do
        :ok
      else
        _ -> :ok
      end
    else
      _ -> :ok
    end
  end

  def promote_native_relay(_event, _relay_url), do: :ok

  def update_group(event, relay_url) do
    group_id = Protocol.tag_value(event, "d")

    with %Entity{pubkey: expected_pubkey, user: %User{} = group} = entity <-
           get_group(relay_url, group_id),
         true <- expected_pubkey == event["pubkey"],
         metadata <- group_metadata(event),
         {:ok, group} <- update_user(group, group_user_attrs(metadata, group)),
         {:ok, _entity} <- update_entity(entity, metadata, event["id"], relay_url) do
      {:ok, group}
    else
      _ -> {:error, :unknown_group}
    end
  end

  def upsert_discovered_group(event, relay_url, standard, activity_metadata)
      when standard in ["nip29", "nip72"] and is_map(activity_metadata) do
    group_id = discovered_group_id(event, standard)

    with true <- valid_group_id?(group_id),
         true <- valid_pubkey?(event["pubkey"]),
         {:ok, group} <- find_or_create_discovered_group(event, relay_url, group_id, standard),
         %Entity{pubkey: expected_pubkey} = entity <- get_by_user(group),
         true <- expected_pubkey == event["pubkey"],
         metadata <-
           event
           |> discovered_group_metadata(standard)
           |> Map.merge(activity_metadata)
           |> Map.put("community_standard", standard),
         merged_metadata <- Map.merge(entity.metadata || %{}, metadata),
         {:ok, group} <- update_user(group, group_user_attrs(merged_metadata, group)),
         {:ok, _entity} <- update_entity(entity, metadata, event["id"], relay_url) do
      {:ok, group}
    else
      _ -> {:error, :invalid_discovered_group}
    end
  end

  def upsert_discovered_group(_event, _relay_url, _standard, _activity_metadata),
    do: {:error, :invalid_discovered_group}

  def update_group_directory(%{"kind" => kind} = event, relay_url)
      when kind in [39_001, 39_002, 39_003] do
    group_id = Protocol.tag_value(event, "d")

    with %Entity{pubkey: expected_pubkey, user: %User{} = group} = entity <-
           get_group(relay_url, group_id),
         true <- expected_pubkey == event["pubkey"],
         snapshot <- group_directory_metadata(event),
         metadata <- Map.merge(entity.metadata || %{}, snapshot),
         {:ok, group} <- update_user(group, group_user_attrs(metadata, group)),
         {:ok, _entity} <- update_entity(entity, snapshot, event["id"], relay_url) do
      {:ok, group}
    else
      _ -> {:error, :unknown_group}
    end
  end

  def update_group_directory(_event, _relay_url), do: {:error, :invalid_group_directory}

  def relays_for_user(user, mode \\ :write)

  def relays_for_user(%User{} = user, mode) do
    case get_by_user(user) do
      %Entity{} = entity -> relay_urls(entity, mode)
      _ -> []
    end
  end

  def relays_for_user(_user, _mode), do: []

  def relay_urls(entity, mode \\ :both)

  def relay_urls(%Entity{} = entity, mode) when mode in [:read, :write, :both] do
    primary = List.wrap(entity.relay_url)

    relay_list =
      entity.metadata
      |> relay_list()

    listed =
      relay_list
      |> Enum.filter(fn relay ->
        mode == :both or Map.get(relay, Atom.to_string(mode), false) == true
      end)
      |> Enum.map(& &1["url"])

    nip05 =
      (entity.metadata || %{})
      |> Map.get("nip05_relays", [])
      |> List.wrap()

    relays =
      cond do
        mode == :both -> primary ++ listed ++ nip05
        relay_list != [] -> listed
        true -> primary ++ nip05
      end

    relays
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&Nostr.allowed_relay?/1)
    |> Enum.uniq()
  end

  def relay_urls(_entity, _mode), do: []

  def all_relay_urls do
    direct_relay_urls =
      Entity
      |> where([entity], not is_nil(entity.relay_url))
      |> distinct(true)
      |> select([entity], entity.relay_url)
      |> Repo.all()
      |> Enum.flat_map(fn relay_url ->
        relay_urls(%Entity{relay_url: relay_url, metadata: %{}}, :both)
      end)

    listed_relay_urls =
      Entity
      |> where([entity], not is_nil(fragment("?->'relay_list'", entity.metadata)))
      |> select([entity], entity.metadata)
      |> Repo.all()
      |> Enum.flat_map(fn metadata ->
        entity = %Entity{metadata: metadata || %{}}
        relay_urls(entity, :both)
      end)

    direct_relay_urls
    |> Kernel.++(listed_relay_urls)
    |> Enum.uniq()
  end

  # Nostr mirrors carry this marker when they are created. Avoid a database
  # lookup for every ordinary remote ActivityPub account rendered in a feed.
  def update_nostr_extension(pubkey, updater)
      when is_binary(pubkey) and is_function(updater, 1) do
    with %Entity{user: %User{} = user} <- get_profile(pubkey),
         %User{} = user <- Repo.get(User, user.id),
         extension <- get_in(user.actor_extensions || %{}, ["nostr"]) || %{},
         updated when is_map(updated) <- updater.(extension) do
      update_user(user, %{
        actor_extensions: Map.put(user.actor_extensions || %{}, "nostr", updated)
      })
    else
      _ -> {:error, :unknown_profile}
    end
  rescue
    _ -> {:error, :invalid_profile_extension}
  end

  def update_nostr_extension(_pubkey, _updater), do: {:error, :invalid_profile_extension}

  def presentation(%User{id: nil}), do: nil

  def presentation(%User{local: false, actor_extensions: extensions} = user) do
    if nostr_extension?(extensions) and not foreign_protocol_mirror?(extensions),
      do: render_presentation(user)
  end

  def presentation(%User{actor_extensions: extensions} = user) do
    if not foreign_protocol_mirror?(extensions), do: render_presentation(user)
  end

  def presentation(_user), do: nil

  defp render_presentation(user) do
    entity = get_by_user(user) || provision_local_actor(user)

    case entity do
      %Entity{} = entity ->
        metadata = entity.metadata || %{}
        relays = relay_urls(entity, :both)

        %{
          pubkey: entity.pubkey,
          npub: encode_npub(entity.pubkey),
          nprofile: encode_nprofile(entity.pubkey, relays),
          relay: entity.relay_url,
          relays: relays,
          group_id: entity.group_id,
          kind: entity.kind,
          nip05: presentation_nip05(user, entity, metadata),
          website: metadata["website"],
          lud16: metadata["lud16"],
          lud06: metadata["lud06"],
          birthday: metadata["birthday"],
          external_identities: metadata["external_identities"]
        }
        |> Map.merge(Pleroma.Nostr.ProfileExtensions.presentation(user))
        |> maybe_put_group_directory(entity, metadata)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _ ->
        nil
    end
  end

  defp nostr_extension?(%{"nostr" => value}) when is_map(value), do: true
  defp nostr_extension?(%{nostr: value}) when is_map(value), do: true
  defp nostr_extension?(_extensions), do: false

  defp foreign_protocol_mirror?(extensions) do
    protocol_mirror?(extensions, "atproto", :atproto) or
      protocol_mirror?(extensions, "diaspora", :diaspora)
  end

  defp protocol_mirror?(extensions, string_key, atom_key) when is_map(extensions) do
    case Map.get(extensions, string_key) || Map.get(extensions, atom_key) do
      %{} = extension -> (extension["mirror"] || extension[:mirror]) == true
      _ -> false
    end
  end

  defp protocol_mirror?(_extensions, _string_key, _atom_key), do: false

  defp provision_local_actor(%User{local: true, actor_type: actor_type} = user)
       when actor_type != "Group" do
    if Nostr.enabled?() do
      case local_actor(user) do
        {:ok, entity} -> entity
        _ -> nil
      end
    end
  end

  defp provision_local_actor(_user), do: nil

  defp presentation_nip05(user, %Entity{kind: "local_actor"}, _metadata),
    do: local_nip05(user)

  defp presentation_nip05(_user, _entity, metadata), do: metadata["nip05"]

  defp maybe_put_group_directory(presentation, %Entity{kind: "mirror_group"}, metadata) do
    [
      members_count: metadata["members_count"],
      moderators_count: metadata["moderators_count"],
      administrators: metadata["administrators"],
      roles: metadata["roles"],
      owner_pubkey: metadata["owner_pubkey"],
      community_standard: metadata["community_standard"],
      activity_30d: metadata["activity_30d"],
      active_authors_30d: metadata["active_authors_30d"],
      last_activity_at: metadata["last_activity_at"],
      community_coordinate: metadata["community_coordinate"]
    ]
    |> Enum.reduce(presentation, fn
      {_key, nil}, result -> result
      {key, value}, result -> Map.put(result, key, value)
    end)
  end

  defp maybe_put_group_directory(presentation, _entity, _metadata), do: presentation

  defp create_profile(pubkey, relays) do
    relay_url = List.first(relays)
    short_name = "nostr_" <> String.slice(pubkey, 0, 24)
    display_name = "Nostr " <> String.slice(pubkey, 0, 12)

    create_mirror(
      short_name,
      %{
        actor_type: "Person",
        name: display_name,
        bio: "",
        raw_bio: "",
        is_locked: false,
        actor_extensions: %{
          "nostr" => %{"pubkey" => pubkey, "relay" => relay_url, "mirror" => true}
        }
      },
      %{
        kind: "mirror_profile",
        pubkey: pubkey,
        relay_url: relay_url,
        metadata: %{}
      }
    )
  end

  defp create_group(pubkey, relay_url, group_id),
    do: create_group(pubkey, relay_url, group_id, "nip29")

  defp create_group(pubkey, relay_url, group_id, standard) do
    digest = digest_fragment("#{relay_url}\n#{group_id}")
    short_name = "nostr_group_" <> digest
    standard_label = if standard == "nip72", do: "NIP-72 moderated", else: "NIP-29"

    create_mirror(
      short_name,
      %{
        actor_type: "Group",
        name: humanize_group_id(group_id),
        bio: "#{standard_label} community on #{relay_url}",
        raw_bio: "#{standard_label} community on #{relay_url}",
        is_locked: false,
        actor_extensions: %{
          "nostr" => %{
            "pubkey" => pubkey,
            "relay" => relay_url,
            "group_id" => group_id,
            "community_standard" => standard,
            "mirror" => true
          }
        }
      },
      %{
        kind: "mirror_group",
        pubkey: pubkey,
        relay_url: relay_url,
        group_id: group_id,
        metadata: %{"community_standard" => standard}
      }
    )
  end

  defp find_or_create_discovered_group(event, relay_url, group_id, standard) do
    case get_group(relay_url, group_id) do
      %Entity{user: %User{} = group} -> {:ok, group}
      nil -> create_group(event["pubkey"], relay_url, group_id, standard)
    end
  end

  defp discovered_group_id(event, "nip29"), do: Protocol.tag_value(event, "d")

  defp discovered_group_id(event, "nip72") do
    case Protocol.tag_value(event, "d") do
      identifier when is_binary(identifier) and identifier != "" ->
        "34550:#{event["pubkey"]}:#{identifier}"

      _ ->
        nil
    end
  end

  defp discovered_group_metadata(event, "nip29"), do: group_metadata(event)

  defp discovered_group_metadata(event, "nip72") do
    coordinate = discovered_group_id(event, "nip72")

    %{
      "name" => Protocol.tag_value(event, "name") || Protocol.tag_value(event, "d"),
      "about" => Protocol.tag_value(event, "description") || "",
      "picture" => Protocol.tag_value(event, "image"),
      "owner_pubkey" => event["pubkey"],
      "community_coordinate" => coordinate,
      "moderator_pubkeys" =>
        event["tags"]
        |> List.wrap()
        |> Enum.flat_map(fn
          ["p", pubkey, _relay, "moderator" | _rest] -> [pubkey]
          _tag -> []
        end)
        |> then(&Enum.uniq([event["pubkey"] | &1]))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp create_mirror(short_name, user_attrs, entity_attrs) do
    ap_id = Endpoint.url() <> "/users/" <> short_name

    with {:ok, keys} <- Pleroma.Keys.generate_rsa_pem() do
      user =
        struct(
          User,
          Map.merge(
            %{
              ap_id: ap_id,
              email: nil,
              featured_address: ap_id <> "/collections/featured",
              follower_address: ap_id <> "/followers",
              following_address: ap_id <> "/following",
              inbox: ap_id <> "/inbox",
              invisible: false,
              is_active: true,
              is_approved: true,
              is_confirmed: true,
              is_discoverable: true,
              is_indexable: true,
              keys: keys,
              last_refreshed_at: NaiveDateTime.utc_now(),
              local: true,
              nickname: short_name,
              outbox_address: ap_id <> "/outbox",
              shared_inbox: Endpoint.url() <> "/inbox",
              uri: ap_id
            },
            user_attrs
          )
        )

      Repo.transaction(fn ->
        with {:ok, user} <- Repo.insert(user),
             {:ok, entity} <-
               %Entity{}
               |> Entity.changeset(Map.put(entity_attrs, :user_id, user.id))
               |> Repo.insert() do
          {user, entity}
        else
          {:error, error} -> Repo.rollback(error)
        end
      end)
      |> case do
        {:ok, {user, _entity}} ->
          User.set_cache(user)
          RelayManager.sync_now()
          {:ok, user}

        {:error, _error} ->
          fetch_identity_winner(entity_attrs)
      end
    end
  end

  defp create_local_actor(%User{} = user) do
    with {:ok, pubkey} <- Keys.public_key("actor:#{user.id}") do
      insert_local_entity(user, "local_actor", pubkey, nil)
    end
  end

  defp create_local_group(%User{} = group) do
    with {:ok, pubkey} <- Keys.public_key("relay") do
      group_id = local_group_id(group)
      insert_local_entity(group, "local_group", pubkey, group_id)
    end
  end

  defp insert_local_entity(user, kind, pubkey, group_id) do
    metadata =
      case {kind, local_nip05(user)} do
        {"local_actor", identifier} when is_binary(identifier) -> %{"nip05" => identifier}
        _ -> %{}
      end

    attrs = %{
      user_id: user.id,
      kind: kind,
      pubkey: pubkey,
      relay_url: Nostr.relay_url(),
      group_id: group_id,
      metadata: metadata
    }

    case %Entity{} |> Entity.changeset(attrs) |> Repo.insert() do
      {:ok, entity} -> {:ok, %{entity | user: user}}
      {:error, _changeset} -> fetch_local_entity(user)
    end
  end

  defp fetch_local_entity(user) do
    case get_by_user(user) do
      %Entity{} = entity -> {:ok, entity}
      nil -> {:error, :could_not_create_identity}
    end
  end

  defp fetch_identity_winner(%{group_id: group_id, relay_url: relay_url})
       when is_binary(group_id) do
    case get_group(relay_url, group_id) do
      %Entity{user: %User{} = user} -> {:ok, user}
      _ -> {:error, :could_not_create_identity}
    end
  end

  defp fetch_identity_winner(%{pubkey: pubkey}) do
    case get_profile(pubkey) do
      %Entity{user: %User{} = user} -> {:ok, user}
      _ -> {:error, :could_not_create_identity}
    end
  end

  defp update_user(user, attrs) do
    user
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
    |> case do
      {:ok, user} ->
        User.set_cache(user)
        {:ok, user}

      error ->
        error
    end
  end

  defp update_entity(entity, metadata, event_id, relay_url) do
    entity
    |> Entity.changeset(%{
      metadata: Map.merge(entity.metadata || %{}, metadata),
      latest_metadata_event_id: event_id,
      relay_url: preferred_profile_relay(entity.relay_url, relay_url)
    })
    |> Repo.update()
  end

  defp preferred_profile_relay(current, candidate) do
    cond do
      Nostr.compatibility_relay?(current) and not Nostr.compatibility_relay?(candidate) ->
        candidate

      is_binary(current) ->
        current

      true ->
        candidate
    end
  end

  defp profile_user_attrs(metadata, pubkey, entity, user) do
    display_name =
      metadata["display_name"] || metadata["displayName"] || metadata["name"] ||
        metadata["username"] || "Nostr #{String.slice(pubkey, 0, 12)}"

    raw_bio = metadata["about"] || ""
    fields = profile_fields(metadata)
    birthday = birthday_date(metadata["birthday"])

    nostr_extension =
      %{
        "pubkey" => pubkey,
        "relay" => entity.relay_url,
        "relays" => relay_urls(entity, :both),
        "nip05" => metadata["nip05"],
        "website" => metadata["website"],
        "lud16" => metadata["lud16"],
        "lud06" => metadata["lud06"],
        "birthday" => metadata["birthday"],
        "external_identities" => metadata["external_identities"],
        "mirror" => true
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      name: String.slice(display_name, 0, 100),
      bio: raw_bio |> String.slice(0, 5_000) |> plain_text_html(),
      raw_bio: String.slice(raw_bio, 0, 5_000),
      avatar: image_map(metadata["picture"]),
      banner: image_map(metadata["banner"]),
      actor_type: if(metadata["bot"] == true, do: "Service", else: "Person"),
      birthday: birthday,
      show_birthday: not is_nil(birthday),
      emoji: metadata["emojis"] || %{},
      fields: fields,
      raw_fields: fields,
      actor_extensions: Map.put(user.actor_extensions || %{}, "nostr", nostr_extension)
    }
  end

  defp group_user_attrs(metadata, group) do
    name = metadata["name"] || group.name
    bio = metadata["about"] || group.bio || ""

    %{
      name: String.slice(name, 0, 100),
      bio: String.slice(bio, 0, 5_000),
      raw_bio: String.slice(bio, 0, 5_000),
      avatar: image_map(metadata["picture"]),
      banner: image_map(metadata["banner"]),
      is_locked: metadata["closed"] == true,
      posting_restricted_to_mods: false,
      is_discoverable: metadata["hidden"] != true,
      invisible: metadata["hidden"] == true,
      actor_extensions:
        Map.update(group.actor_extensions || %{}, "nostr", metadata, &Map.merge(&1, metadata))
    }
  end

  defp group_metadata(event) do
    %{
      "name" => Protocol.tag_value(event, "name"),
      "about" => Protocol.tag_value(event, "about"),
      "picture" => Protocol.tag_value(event, "picture"),
      "banner" => Protocol.tag_value(event, "banner"),
      "closed" => has_tag?(event, "closed"),
      "restricted" => has_tag?(event, "restricted"),
      "private" => has_tag?(event, "private"),
      "hidden" => has_tag?(event, "hidden")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp group_directory_metadata(%{"kind" => 39_001} = event) do
    administrators = group_administrators(event)

    %{
      "administrators" => administrators,
      "moderators_count" => length(administrators)
    }
    |> maybe_put_owner_pubkey(administrators)
  end

  defp group_directory_metadata(%{"kind" => 39_002} = event) do
    pubkeys = group_pubkeys(event)

    %{
      "members_count" => length(pubkeys),
      "member_pubkeys" => Enum.take(pubkeys, @max_group_directory_members)
    }
  end

  defp group_directory_metadata(%{"kind" => 39_003} = event) do
    roles =
      event
      |> Map.get("tags", [])
      |> Enum.flat_map(fn
        ["role", name, description | _rest]
        when is_binary(name) and name != "" and is_binary(description) ->
          [
            %{
              "name" => String.slice(name, 0, 64),
              "description" => String.slice(description, 0, 500)
            }
          ]

        ["role", name | _rest] when is_binary(name) and name != "" ->
          [%{"name" => String.slice(name, 0, 64), "description" => ""}]

        _tag ->
          []
      end)
      |> Enum.uniq_by(& &1["name"])
      |> Enum.take(32)

    %{"roles" => roles}
  end

  defp group_administrators(event) do
    event
    |> Map.get("tags", [])
    |> Enum.flat_map(fn
      ["p", pubkey | roles] when is_binary(pubkey) ->
        if valid_pubkey?(pubkey) do
          roles =
            roles
            |> Enum.filter(&(is_binary(&1) and &1 != ""))
            |> Enum.map(&String.slice(&1, 0, 64))
            |> Enum.uniq()
            |> Enum.take(8)

          [%{"pubkey" => pubkey, "roles" => roles}]
        else
          []
        end

      _tag ->
        []
    end)
    |> Enum.uniq_by(& &1["pubkey"])
    |> Enum.take(64)
  end

  defp group_pubkeys(event) do
    event
    |> Map.get("tags", [])
    |> Enum.flat_map(fn
      ["p", pubkey | _rest] when is_binary(pubkey) ->
        if valid_pubkey?(pubkey), do: [pubkey], else: []

      _tag ->
        []
    end)
    |> Enum.uniq()
  end

  defp maybe_put_owner_pubkey(metadata, administrators) do
    owner =
      Enum.find(administrators, fn administrator ->
        Enum.any?(administrator["roles"], &(&1 in ["owner", "admin", "king"]))
      end) || List.first(administrators)

    case owner do
      %{"pubkey" => pubkey} -> Map.put(metadata, "owner_pubkey", pubkey)
      _ -> metadata
    end
  end

  defp has_tag?(event, name) do
    Enum.any?(event["tags"], fn
      [^name | _rest] -> true
      _tag -> false
    end)
  end

  defp decode_profile_metadata(content) do
    case Jason.decode(content) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      _ -> {:error, :invalid_metadata}
    end
  end

  defp normalize_profile_metadata(metadata) do
    Map.new(@profile_metadata_keys, fn key ->
      {key, normalize_profile_value(key, Map.get(metadata, key))}
    end)
  end

  defp normalize_profile_value("bot", value) when is_boolean(value), do: value
  defp normalize_profile_value("birthday", value), do: normalize_birthday(value)

  defp normalize_profile_value(key, value)
       when key in ["picture", "banner", "website"] and is_binary(value) do
    value = bounded_text(value, 2_048)
    if valid_http_url?(value), do: value
  end

  defp normalize_profile_value("about", value), do: bounded_text(value, 5_000)

  defp normalize_profile_value(key, value)
       when key in ["nip05", "lud16"] do
    bounded_text(value, 320)
  end

  defp normalize_profile_value("lud06", value), do: bounded_text(value, 2_048)
  defp normalize_profile_value(_key, value), do: bounded_text(value, 100)

  defp normalize_birthday(%{} = birthday) do
    birthday
    |> Map.take(["year", "month", "day"])
    |> Enum.flat_map(fn
      {"year", value} when is_integer(value) and value in 1..9_999 -> [{"year", value}]
      {"month", value} when is_integer(value) and value in 1..12 -> [{"month", value}]
      {"day", value} when is_integer(value) and value in 1..31 -> [{"day", value}]
      _entry -> []
    end)
    |> Map.new()
    |> case do
      birthday when map_size(birthday) > 0 -> birthday
      _birthday -> nil
    end
  end

  defp normalize_birthday(_birthday), do: nil

  defp birthday_date(%{"year" => year, "month" => month, "day" => day}) do
    case Date.new(year, month, day) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp birthday_date(_birthday), do: nil

  defp bounded_text(value, limit) when is_binary(value) do
    value
    |> String.replace("\0", "")
    |> String.slice(0, limit)
  end

  defp bounded_text(_value, _limit), do: nil

  # NIP-30 profile emoji are references, not downloaded files. Keep only a
  # bounded map of conservative shortcodes and HTTP(S) URLs for normal account
  # rendering and ActivityPub profile export.
  defp profile_emojis(event) do
    event
    |> Map.get("tags", [])
    |> Enum.flat_map(fn
      ["emoji", shortcode, url | _rest] when is_binary(shortcode) and is_binary(url) ->
        if valid_emoji_shortcode?(shortcode) and valid_http_url?(url) do
          [{shortcode, String.slice(url, 0, 2_048)}]
        else
          []
        end

      _tag ->
        []
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.take(@max_profile_emojis)
    |> Map.new()
  end

  defp external_identities(event) do
    event
    |> Map.get("tags", [])
    |> Enum.flat_map(fn
      ["i", identifier, proof | _rest] when is_binary(identifier) and is_binary(proof) ->
        case String.split(identifier, ":", parts: 2) do
          [provider, identity] when provider in @external_identity_providers ->
            if safe_identity_part?(identity) and safe_identity_part?(proof) do
              [
                %{
                  "platform" => provider,
                  "identity" => String.slice(identity, 0, 255),
                  "proof" => String.slice(proof, 0, 512)
                }
              ]
            else
              []
            end

          _identity ->
            []
        end

      _tag ->
        []
    end)
    |> Enum.uniq_by(&{&1["platform"], &1["identity"]})
    |> Enum.take(@max_external_identities)
  end

  defp profile_fields(metadata) do
    website_fields =
      case metadata["website"] do
        website when is_binary(website) -> [profile_link_field("Website", website)]
        _website -> []
      end

    lightning_fields =
      case metadata["lud16"] do
        lud16 when is_binary(lud16) -> [profile_text_field("Lightning", lud16)]
        _lud16 -> []
      end

    identity_fields =
      metadata
      |> Map.get("external_identities", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"platform" => provider, "identity" => identity}
        when provider in @external_identity_providers and is_binary(identity) ->
          [profile_text_field(String.capitalize(provider), identity)]

        _identity ->
          []
      end)

    (website_fields ++ lightning_fields ++ identity_fields)
    |> Enum.take(profile_field_limit())
  end

  defp profile_field_limit do
    case Config.get([:instance, :max_remote_account_fields], 0) do
      limit when is_integer(limit) and limit > 0 -> min(limit, 16)
      _limit -> 0
    end
  end

  defp profile_link_field(name, url) do
    escaped_url = html_escape(url)

    %{
      "name" => name,
      "value" =>
        ~s(<a href="#{escaped_url}" rel="nofollow noopener noreferrer" target="_blank">#{escaped_url}</a>),
      "verified_at" => nil
    }
  end

  defp profile_text_field(name, value) do
    %{
      "name" => String.slice(name, 0, 64),
      "value" => value |> String.slice(0, 255) |> html_escape(),
      "verified_at" => nil
    }
  end

  defp plain_text_html(value) do
    value
    |> html_escape()
    |> String.replace("\n", "<br>")
  end

  defp html_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp safe_identity_part?(value) do
    is_binary(value) and byte_size(value) in 1..512 and
      not String.contains?(value, ["\0", "\r", "\n"])
  end

  defp valid_emoji_shortcode?(shortcode) do
    byte_size(shortcode) in 1..64 and Regex.match?(~r/^[A-Za-z0-9_]+$/, shortcode)
  end

  defp valid_http_url?(url) when is_binary(url) and byte_size(url) <= 2_048 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _uri ->
        false
    end
  end

  defp valid_http_url?(_url), do: false

  defp validate_nip05(metadata, pubkey) do
    case metadata["nip05"] do
      identifier when is_binary(identifier) and identifier != "" ->
        case NIP05.verify(identifier, pubkey) do
          {:ok, %{identifier: verified, relays: relays}} ->
            metadata
            |> Map.put("nip05", verified)
            |> Map.put("nip05_valid", true)
            |> Map.put("nip05_relays", relays)

          {:error, _reason} ->
            metadata
            |> Map.put("nip05_claim", identifier)
            |> Map.put("nip05", nil)
            |> Map.put("nip05_valid", false)
            |> Map.put("nip05_relays", [])
        end

      _ ->
        metadata
        |> Map.put("nip05", nil)
        |> Map.delete("nip05_claim")
        |> Map.put("nip05_valid", false)
        |> Map.put("nip05_relays", [])
    end
  end

  defp relay_list_from_event(event) do
    event
    |> Map.get("tags", [])
    |> Enum.flat_map(fn
      ["r", relay_url] -> relay_entry(relay_url, true, true)
      ["r", relay_url, "read"] -> relay_entry(relay_url, true, false)
      ["r", relay_url, "write"] -> relay_entry(relay_url, false, true)
      _tag -> []
    end)
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(8)
  end

  defp relay_entry(relay_url, read?, write?) do
    relay_url = Protocol.normalize_relay_url(relay_url)

    if Nostr.allowed_relay?(relay_url) do
      [%{"url" => relay_url, "read" => read?, "write" => write?}]
    else
      []
    end
  end

  defp relay_list(%{} = metadata) do
    metadata
    |> Map.get("relay_list", [])
    |> List.wrap()
    |> Enum.filter(fn
      %{"url" => url} when is_binary(url) -> true
      _entry -> false
    end)
  end

  defp relay_list(_metadata), do: []

  defp image_map(url) when is_binary(url) and url != "" do
    if valid_http_url?(url), do: %{"url" => [%{"href" => url}]}
  end

  defp image_map(_url), do: nil

  defp encode_npub(pubkey) do
    with {:ok, binary} <- Base.decode16(pubkey, case: :mixed) do
      Bechamel.encode("npub", binary)
    end
  rescue
    _error -> nil
  end

  defp encode_nprofile(pubkey, relays) do
    case Elixir.Nostr.NIP19.encode_nprofile(pubkey, Enum.take(relays, 8)) do
      {:ok, encoded} when is_binary(encoded) -> encoded
      _encoded -> nil
    end
  rescue
    _error -> nil
  end

  defp maybe_add_relay(%{relays: relays}, user) do
    case get_by_user(user) do
      %Entity{relay_url: nil} = entity ->
        case allowed_relays(relays) do
          [relay_url | _rest] ->
            entity |> Entity.changeset(%{relay_url: relay_url}) |> Repo.update()
            RelayManager.sync_now()

          [] ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp allowed_relays(relays) do
    relays
    |> List.wrap()
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&Nostr.allowed_relay?/1)
    |> Enum.uniq()
    |> case do
      [] -> Nostr.configured_relays()
      allowed -> allowed
    end
  end

  defp allowed_group_relays(relays) do
    relays
    |> List.wrap()
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&Nostr.allowed_relay?/1)
    |> Enum.uniq()
  end

  defp local_group_id(group) do
    group.nickname
    |> to_string()
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp valid_pubkey?(pubkey), do: is_binary(pubkey) and Regex.match?(~r/^[0-9a-f]{64}$/, pubkey)

  defp valid_group_id?(group_id) do
    is_binary(group_id) and byte_size(group_id) in 1..512 and
      not String.contains?(group_id, ["\0", "\r", "\n"])
  end

  defp digest_fragment(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 24)
  end

  defp humanize_group_id(group_id) do
    group_id
    |> String.replace(~r/[-_]+/, " ")
    |> String.trim()
    |> case do
      "" -> "Nostr community"
      name -> String.capitalize(name)
    end
  end
end

# end of nostr/identity.ex
