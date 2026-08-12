# Unfathomably BE
# ----------------
#
# File: diaspora/identities.ex
#
# Purpose:
#   Project discovered diaspora* identities into ordinary local accounts.
#
# Responsibilities:
#   - create one collision-resistant mirror user per diaspora* GUID
#   - retain verified delivery and RSA-key metadata
#   - expose protocol presentation without treating a mirror as a local person
#
# This file intentionally does NOT receive envelopes or publish entities.

defmodule Pleroma.Diaspora.Identities do
  import Ecto.Query

  alias Pleroma.Diaspora.Discovery
  alias Pleroma.Diaspora.Entity
  alias Pleroma.Keys
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.Endpoint

  def resolve(identifier) when is_binary(identifier) do
    identifier =
      identifier |> String.trim() |> String.trim_leading("diaspora:") |> String.trim_leading("@")

    case get_by_diaspora_id(identifier) do
      %Entity{user: %User{} = user} -> {:ok, user}
      nil -> with {:ok, profile} <- Discovery.discover(identifier), do: upsert(profile)
    end
  end

  def resolve(_identifier), do: {:error, :not_found}

  def upsert(%{diaspora_id: diaspora_id, guid: guid} = profile) do
    case get_by_diaspora_id(diaspora_id) || get_by_guid(guid) do
      %Entity{user: %User{} = user} = entity -> update_profile(entity, user, profile)
      nil -> create_profile(profile)
    end
  end

  def upsert(_profile), do: {:error, :invalid_profile}

  def get_by_diaspora_id(id) when is_binary(id) do
    Entity |> where(diaspora_id: ^String.downcase(id)) |> preload(:user) |> Repo.one()
  end

  def get_by_diaspora_id(_id), do: nil

  def get_by_guid(guid) when is_binary(guid) do
    Entity |> where(guid: ^guid) |> preload(:user) |> Repo.one()
  end

  def get_by_guid(_guid), do: nil

  def get_by_user(%User{id: id}) do
    Entity |> where(user_id: ^id) |> preload(:user) |> Repo.one()
  end

  def get_by_user(_user), do: nil
  def mirror?(%User{} = user), do: match?(%Entity{}, get_by_user(user))
  def mirror?(_user), do: false

  def presentation(%User{actor_extensions: extensions}) do
    case extensions && (extensions["diaspora"] || extensions[:diaspora]) do
      %{} = extension -> atom_presentation(extension)
      _ -> nil
    end
  end

  def presentation(_user), do: nil

  def apply_entity_profile(%{"author" => author} = data) do
    case get_by_diaspora_id(author) do
      %Entity{user: %User{} = user} = entity ->
        attrs = entity_profile_user_attrs(user, data)
        metadata = entity_profile_metadata(entity.metadata || %{}, data)

        Repo.transaction(fn ->
          with {:ok, user} <- user |> Ecto.Changeset.change(attrs) |> Repo.update(),
               {:ok, _entity} <-
                 entity |> Entity.changeset(%{metadata: metadata}) |> Repo.update() do
            User.set_cache(user)
            user
          else
            {:error, error} -> Repo.rollback(error)
          end
        end)
        |> case do
          {:ok, _user} -> :ok
          {:error, error} -> {:error, error}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def apply_entity_profile(_data), do: {:error, :invalid_profile}

  defp create_profile(profile) do
    nickname = "diaspora_" <> digest_fragment(profile.guid)
    ap_id = Endpoint.url() <> "/users/" <> nickname

    with {:ok, keys} <- Keys.generate_rsa_pem() do
      user =
        struct(User, %{
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
          nickname: nickname,
          outbox_address: ap_id <> "/outbox",
          shared_inbox: Endpoint.url() <> "/inbox",
          uri: ap_id
        })

      Repo.transaction(fn ->
        with {:ok, user} <- user |> Ecto.Changeset.change(user_attrs(profile)) |> Repo.insert(),
             {:ok, entity} <-
               %Entity{}
               |> Entity.changeset(Map.put(entity_attrs(profile), :user_id, user.id))
               |> Repo.insert() do
          User.set_cache(user)
          {user, entity}
        else
          {:error, error} -> Repo.rollback(error)
        end
      end)
      |> case do
        {:ok, {user, _entity}} -> {:ok, user}
        {:error, _error} -> fetch_winner(profile)
      end
    end
  end

  defp update_profile(entity, user, profile) do
    attrs = user_attrs(profile)
    extension = get_in(attrs, [:actor_extensions, "diaspora"])

    attrs =
      Map.put(
        attrs,
        :actor_extensions,
        Map.put(user.actor_extensions || %{}, "diaspora", extension)
      )

    Repo.transaction(fn ->
      with {:ok, user} <- user |> Ecto.Changeset.change(attrs) |> Repo.update(),
           {:ok, _entity} <- entity |> Entity.changeset(entity_attrs(profile)) |> Repo.update() do
        User.set_cache(user)
        user
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, error} -> {:error, error}
    end
  end

  defp user_attrs(profile) do
    extension = %{
      "id" => profile.diaspora_id,
      "guid" => profile.guid,
      "pod" => profile.pod_url,
      "profile_url" => profile.profile_url,
      "mirror" => true
    }

    %{
      name: profile.name || profile.nickname || profile.diaspora_id,
      bio: "",
      raw_bio: "",
      avatar: if(profile.avatar_url, do: %{"url" => [%{"href" => profile.avatar_url}]}),
      actor_type: "Person",
      actor_extensions: %{"diaspora" => extension}
    }
  end

  defp entity_profile_user_attrs(user, data) do
    extension =
      (user.actor_extensions || %{})
      |> Map.get("diaspora", %{})
      |> Map.put("profile", entity_profile_metadata(%{}, data))

    %{
      actor_extensions: Map.put(user.actor_extensions || %{}, "diaspora", extension)
    }
    |> maybe_put(:name, profile_name(data))
    |> maybe_put(:avatar, profile_avatar(data))
    |> maybe_put_public_bio(data)
    |> maybe_put_boolean(:is_discoverable, data["searchable"])
    |> maybe_put_boolean(:is_indexable, data["searchable"])
  end

  defp entity_profile_metadata(existing, data) do
    base = %{
      "full_name" => data["full_name"],
      "first_name" => data["first_name"],
      "last_name" => data["last_name"],
      "image_url" => profile_image_url(data),
      "searchable" => data["searchable"],
      "nsfw" => data["nsfw"],
      "tag_string" => data["tag_string"],
      "edited_at" => data["edited_at"]
    }

    extended =
      if public_profile?(data) do
        %{
          "bio" => data["bio"],
          "birthday" => data["birthday"],
          "location" => data["location"]
        }
      else
        %{}
      end

    existing =
      if data["public"] in [false, "false"] do
        Map.drop(existing, ["bio", "birthday", "location"])
      else
        existing
      end

    existing
    |> Map.merge(base)
    |> Map.merge(extended)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp profile_name(data) do
    case data["full_name"] ||
           Enum.join(Enum.filter([data["first_name"], data["last_name"]], &is_binary/1), " ") do
      name when is_binary(name) and name != "" -> String.slice(name, 0, 100)
      _ -> nil
    end
  end

  defp profile_avatar(data) do
    case profile_image_url(data) do
      url when is_binary(url) -> %{"url" => [%{"href" => url}]}
      _ -> nil
    end
  end

  defp profile_image_url(data) do
    url = data["image_url"] || data["image_url_medium"] || data["image_url_small"]

    if Pleroma.ATProto.URL.public_https_url?(url), do: url
  end

  defp maybe_put_public_bio(attrs, data) do
    if public_profile?(data) and is_binary(data["bio"]) do
      bio =
        Pleroma.Web.CommonAPI.Utils.format_input(data["bio"], "text/markdown",
          mentions_format: :full
        )

      attrs
      |> Map.put(:raw_bio, data["bio"])
      |> Map.put(:bio, bio)
    else
      if data["public"] in [false, "false"] do
        attrs |> Map.put(:raw_bio, "") |> Map.put(:bio, "")
      else
        attrs
      end
    end
  end

  defp maybe_put_boolean(attrs, key, value) when value in [true, "true"],
    do: Map.put(attrs, key, true)

  defp maybe_put_boolean(attrs, key, value) when value in [false, "false"],
    do: Map.put(attrs, key, false)

  defp maybe_put_boolean(attrs, _key, _value), do: attrs

  defp public_profile?(data), do: data["public"] in [true, "true"]

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp entity_attrs(profile) do
    %{
      diaspora_id: String.downcase(profile.diaspora_id),
      guid: profile.guid,
      pod_url: profile.pod_url,
      profile_url: profile.profile_url,
      receive_url: profile.receive_url,
      public_key: profile.public_key,
      metadata: %{
        "name" => profile.name,
        "nickname" => profile.nickname,
        "avatar_url" => profile.avatar_url
      }
    }
  end

  defp fetch_winner(profile) do
    case get_by_diaspora_id(profile.diaspora_id) || get_by_guid(profile.guid) do
      %Entity{user: %User{} = user} -> {:ok, user}
      _ -> {:error, :could_not_create_identity}
    end
  end

  defp atom_presentation(extension) do
    %{
      id: extension["id"] || extension[:id],
      guid: extension["guid"] || extension[:guid],
      pod: extension["pod"] || extension[:pod],
      profile_url: extension["profile_url"] || extension[:profile_url],
      mirror: (extension["mirror"] || extension[:mirror]) == true
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp digest_fragment(value) do
    :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower) |> String.slice(0, 24)
  end

  def refresh(identifier) when is_binary(identifier) do
    identifier =
      identifier |> String.trim() |> String.trim_leading("diaspora:") |> String.trim_leading("@")

    case get_by_diaspora_id(identifier) do
      %Entity{updated_at: updated_at, user: %User{} = user}
      when not is_nil(updated_at) ->
        if refreshed_recently?(updated_at) do
          {:ok, user}
        else
          discover_and_upsert(identifier)
        end

      _ ->
        discover_and_upsert(identifier)
    end
  end

  def refresh(_identifier), do: {:error, :invalid_identifier}

  defp refreshed_recently?(%DateTime{} = updated_at),
    do: DateTime.diff(DateTime.utc_now(), updated_at) < 300

  defp refreshed_recently?(%NaiveDateTime{} = updated_at),
    do: NaiveDateTime.diff(NaiveDateTime.utc_now(), updated_at) < 300

  defp refreshed_recently?(_updated_at), do: false

  defp discover_and_upsert(identifier) do
    with {:ok, attrs} <- Discovery.discover(identifier),
         {:ok, %User{} = user} <- upsert(attrs) do
      {:ok, user}
    end
  end
end

# end of diaspora/identities.ex
