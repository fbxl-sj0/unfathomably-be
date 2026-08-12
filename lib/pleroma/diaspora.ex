# Unfathomably BE
# ----------------
#
# File: diaspora.ex
#
# Purpose:
#   Define the public boundary for optional diaspora* interoperability.
#
# Responsibilities:
#   - expose deterministic local diaspora* identity information
#   - append diaspora* discovery links to local WebFinger documents
#   - enqueue committed activities for asynchronous native delivery
#
# This file intentionally does NOT parse XML, perform delivery, or map remote
# identities.

defmodule Pleroma.Diaspora do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Diaspora.Identities
  alias Pleroma.Keys
  alias Pleroma.User
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.WebFinger
  alias Pleroma.Workers.DiasporaPublishWorker

  def enabled?, do: Config.get([__MODULE__, :enabled], false) == true

  def instance_metadata do
    if enabled?() do
      %{
        enabled: true,
        storage: "selective",
        retained_objects: ["followed", "direct_interaction"],
        actions: ["post", "reply", "like", "repost", "delete"]
      }
    end
  end

  def resolve("diaspora:" <> identifier), do: resolve(identifier)

  def resolve(identifier) when is_binary(identifier) do
    if enabled?() and String.contains?(identifier, "@") do
      Identities.resolve(identifier)
    else
      {:error, :not_found}
    end
  end

  def resolve(_identifier), do: {:error, :not_found}

  def diaspora_id(%User{nickname: nickname}) when is_binary(nickname) do
    "#{nickname}@#{WebFinger.domain()}"
  end

  def guid(%User{id: id}) when not is_nil(id), do: to_string(id)

  def guid(%User{ap_id: ap_id}) when is_binary(ap_id) do
    :sha256 |> :crypto.hash(ap_id) |> Base.encode16(case: :lower) |> String.slice(0, 32)
  end

  def public_key_pem(%User{keys: keys}) when is_binary(keys) do
    with {:ok, _private_key, public_key} <- Keys.keys_from_pem(keys) do
      :RSAPublicKey
      |> :public_key.pem_entry_encode(public_key)
      |> then(&:public_key.pem_encode([&1]))
      |> String.trim_trailing()
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def public_key_pem(_user), do: nil

  def presentation(%User{local: true} = user) do
    if foreign_protocol_mirror?(user.actor_extensions) do
      Identities.presentation(user)
    else
      Identities.presentation(user) ||
        if(enabled?(),
          do: %{
            id: diaspora_id(user),
            guid: guid(user),
            pod: Endpoint.url(),
            profile_url: user.ap_id,
            mirror: false
          }
        )
    end
  end

  def presentation(%User{} = user), do: Identities.presentation(user)
  def presentation(_user), do: nil

  def webfinger_links(%User{local: true} = user) do
    if enabled?() and not Identities.mirror?(user) and
         not foreign_protocol_mirror?(user.actor_extensions) do
      base = Endpoint.url()

      [
        %{
          "rel" => "http://microformats.org/profile/hcard",
          "type" => "text/html",
          "href" => "#{base}/hcard/users/#{URI.encode(user.nickname)}"
        },
        %{"rel" => "http://joindiaspora.com/seed_location", "href" => base},
        %{
          "rel" => "http://joindiaspora.com/receive",
          "href" => "#{base}/receive/users/#{guid(user)}"
        }
      ]
    else
      []
    end
  end

  def webfinger_links(_user), do: []

  def maybe_enqueue_activity(%Activity{local: true} = activity, meta) do
    if enabled?() and not Keyword.get(meta, :diaspora_ingest, false) do
      DiasporaPublishWorker.enqueue_activity(activity.id)
    end

    :ok
  end

  def maybe_enqueue_activity(_activity, _meta), do: :ok

  def maybe_enqueue_unfollow(%Activity{} = activity, %User{} = follower, %User{} = unfollowed) do
    if enabled?() and activity.local and Identities.mirror?(unfollowed) do
      DiasporaPublishWorker.enqueue_unfollow(activity.id, follower.id, unfollowed.id)
    end

    :ok
  end

  def maybe_enqueue_unfollow(_activity, _follower, _unfollowed), do: :ok

  defp foreign_protocol_mirror?(extensions) do
    protocol_mirror?(extensions, "atproto", :atproto) or
      protocol_mirror?(extensions, "nostr", :nostr)
  end

  defp protocol_mirror?(extensions, string_key, atom_key) when is_map(extensions) do
    case Map.get(extensions, string_key) || Map.get(extensions, atom_key) do
      %{} = extension -> (extension["mirror"] || extension[:mirror]) == true
      _ -> false
    end
  end

  defp protocol_mirror?(_extensions, _string_key, _atom_key), do: false
end

# end of diaspora.ex
