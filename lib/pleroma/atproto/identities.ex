# Unfathomably BE
# ----------------
#
# File: atproto/identities.ex
#
# Purpose:
#   Resolve AT Protocol identities into ordinary local account projections.
#
# Responsibilities:
#   - fetch bounded public profiles from the configured AppView
#   - create collision-resistant mirror users for stable DIDs
#   - update profile presentation while retaining DID identity
#   - expose account metadata without implying that a mirror is a local person
#
# This file intentionally does NOT store PDS credentials, ingest feeds, or
# publish repository records.

defmodule Pleroma.ATProto.Identities do
  import Ecto.Query

  alias Pleroma.ATProto.Client
  alias Pleroma.ATProto.Identity
  alias Pleroma.ATProto.URL
  alias Pleroma.Keys
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.Endpoint

  def resolve(identifier) when is_binary(identifier) do
    identifier = identifier |> String.trim() |> String.trim_leading("@") |> String.downcase()

    case cached_user(identifier) do
      %User{} = user ->
        {:ok, user}

      nil ->
        with true <- valid_identifier?(identifier),
             {:ok, profile} <- Client.get_profile(identifier),
             {:ok, user} <- upsert_profile(profile) do
          {:ok, user}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  def resolve(_identifier), do: {:error, :not_found}

  def upsert_profile(%{"did" => did} = profile) do
    with true <- valid_did?(did),
         handle <- verified_handle(did, profile["handle"]),
         {:ok, pds_url} <- optional_pds_url(did),
         attrs <- profile_attrs(profile, did, handle, pds_url) do
      case get_by_did(did) do
        %Identity{user: %User{} = user} = identity -> update_profile(identity, user, attrs)
        nil -> create_profile(did, attrs)
      end
    else
      _ -> {:error, :invalid_profile}
    end
  end

  def upsert_profile(_profile), do: {:error, :invalid_profile}

  def get_by_did(did) when is_binary(did) do
    Identity
    |> where(did: ^did)
    |> preload(:user)
    |> Repo.one()
  end

  def get_by_did(_did), do: nil

  def get_by_handle(handle) when is_binary(handle) do
    Identity
    |> where([identity], fragment("lower(?)", identity.handle) == ^String.downcase(handle))
    |> order_by([identity], desc: identity.updated_at)
    |> limit(1)
    |> preload(:user)
    |> Repo.one()
  end

  def get_by_handle(_handle), do: nil

  def get_by_user(%User{id: id}), do: get_by_user_id(id)
  def get_by_user(_user), do: nil

  def get_by_user_id(user_id) when not is_nil(user_id) do
    Identity
    |> where(user_id: ^user_id)
    |> preload(:user)
    |> Repo.one()
  end

  def get_by_user_id(_user_id), do: nil

  def mirror?(%User{} = user), do: match?(%Identity{}, get_by_user(user))
  def mirror?(_user), do: false

  def presentation(%User{actor_extensions: extensions}) do
    case atproto_extension(extensions) do
      %{} = extension ->
        %{
          did: extension["did"],
          handle: extension["handle"],
          pds: extension["pds"],
          profile_url: extension["profile_url"],
          mirror: extension["mirror"] == true
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _ ->
        nil
    end
  end

  def presentation(_user), do: nil

  def mark_synced(%Identity{} = identity) do
    identity
    |> Identity.changeset(%{last_synced_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp create_profile(did, attrs) do
    short_name = "atproto_" <> digest_fragment(did)
    ap_id = Endpoint.url() <> "/users/" <> short_name

    with {:ok, keys} <- Keys.generate_rsa_pem() do
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
            attrs.user
          )
        )

      Repo.transaction(fn ->
        with {:ok, user} <- Repo.insert(user),
             {:ok, identity} <-
               %Identity{}
               |> Identity.changeset(Map.put(attrs.identity, :user_id, user.id))
               |> Repo.insert() do
          {user, identity}
        else
          {:error, error} -> Repo.rollback(error)
        end
      end)
      |> case do
        {:ok, {user, _identity}} ->
          User.set_cache(user)
          {:ok, user}

        {:error, _error} ->
          fetch_winner(did)
      end
    end
  end

  defp update_profile(identity, user, attrs) do
    atproto_extension = get_in(attrs.user, [:actor_extensions, "atproto"])

    user_attrs =
      Map.put(
        attrs.user,
        :actor_extensions,
        Map.put(user.actor_extensions || %{}, "atproto", atproto_extension)
      )

    Repo.transaction(fn ->
      with {:ok, user} <- user |> Ecto.Changeset.change(user_attrs) |> Repo.update(),
           {:ok, _identity} <- identity |> Identity.changeset(attrs.identity) |> Repo.update() do
        user
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, user} ->
        User.set_cache(user)
        {:ok, user}

      {:error, error} ->
        {:error, error}
    end
  end

  defp profile_attrs(profile, did, handle, pds_url) do
    display_name = bounded_text(profile["displayName"], 100) || handle || String.slice(did, 0, 32)
    description = bounded_text(profile["description"], 5_000) || ""
    avatar = safe_image(profile["avatar"])
    banner = safe_image(profile["banner"])

    profile_url =
      if handle, do: "https://bsky.app/profile/#{handle}", else: "https://bsky.app/profile/#{did}"

    metadata =
      %{
        "display_name" => display_name,
        "description" => description,
        "avatar" => profile["avatar"],
        "banner" => profile["banner"],
        "followers_count" => bounded_count(profile["followersCount"]),
        "follows_count" => bounded_count(profile["followsCount"]),
        "posts_count" => bounded_count(profile["postsCount"]),
        "profile_url" => profile_url
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    extension = %{
      "did" => did,
      "handle" => handle,
      "pds" => pds_url,
      "profile_url" => profile_url,
      "mirror" => true
    }

    %{
      user: %{
        name: display_name,
        bio: plain_text_html(description),
        raw_bio: description,
        avatar: avatar,
        banner: banner,
        actor_type: "Person",
        actor_extensions: %{"atproto" => extension}
      },
      identity: %{
        did: did,
        handle: handle,
        pds_url: pds_url,
        metadata: metadata
      }
    }
  end

  defp atproto_extension(%{"atproto" => %{} = extension}), do: extension
  defp atproto_extension(%{atproto: %{} = extension}), do: extension
  defp atproto_extension(_extensions), do: nil

  defp optional_pds_url(did) do
    case Client.pds_url(did) do
      {:ok, pds_url} -> {:ok, pds_url}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp fetch_winner(did) do
    case get_by_did(did) do
      %Identity{user: %User{} = user} -> {:ok, user}
      _ -> {:error, :could_not_create_identity}
    end
  end

  defp valid_identifier?(identifier), do: valid_did?(identifier) or valid_handle?(identifier)

  defp valid_did?(did), do: Pleroma.ATProto.Validation.valid_did?(did)

  defp valid_handle?(handle), do: Pleroma.ATProto.Validation.valid_handle?(handle)

  defp normalized_handle(handle) when is_binary(handle) do
    handle = String.downcase(String.trim(handle))
    if valid_handle?(handle), do: handle
  end

  defp normalized_handle(_handle), do: nil

  defp cached_user(identifier) do
    identity =
      if valid_did?(identifier), do: get_by_did(identifier), else: get_by_handle(identifier)

    case identity do
      %Identity{user: %User{} = user} = identity ->
        if fresh_identity?(identity), do: user

      _identity ->
        nil
    end
  end

  defp verified_handle(did, handle) do
    handle = normalized_handle(handle)

    case {handle, get_by_did(did)} do
      {handle, %Identity{handle: handle} = identity} when is_binary(handle) ->
        if fresh_identity?(identity), do: handle, else: fetch_verified_handle(did, handle)

      {handle, _identity} when is_binary(handle) ->
        fetch_verified_handle(did, handle)

      _pair ->
        nil
    end
  end

  defp fetch_verified_handle(did, handle) do
    case Client.verified_handle(did, handle) do
      {:ok, verified} -> verified
      _error -> nil
    end
  end

  defp fresh_identity?(%Identity{updated_at: %DateTime{} = updated_at}) do
    maximum_age = Pleroma.Config.get([Pleroma.ATProto, :identity_cache_seconds], 900)

    is_integer(maximum_age) and maximum_age > 0 and
      DateTime.diff(DateTime.utc_now(), updated_at, :second) <= maximum_age
  end

  defp fresh_identity?(_identity), do: false

  defp safe_image(url) when is_binary(url) do
    if URL.public_https_url?(url), do: %{"url" => [%{"href" => url}]}
  end

  defp safe_image(_url), do: nil

  defp bounded_text(value, limit) when is_binary(value) do
    value = String.trim(value)
    if value != "" and String.valid?(value), do: String.slice(value, 0, limit)
  end

  defp bounded_text(_value, _limit), do: nil

  defp bounded_count(value) when is_integer(value) and value >= 0, do: min(value, 2_147_483_647)
  defp bounded_count(_value), do: nil

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

  defp digest_fragment(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 24)
  end
end

# end of atproto/identities.ex
