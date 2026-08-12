# Unfathomably BE
# ----------------
#
# File: atproto/links.ex
#
# Purpose:
#   Manage authorized links between local users and AT Protocol accounts.
#
# Responsibilities:
#   - exchange a one-time app password for a PDS session
#   - complete OAuth authorization without exposing tokens to the browser
#   - provision an optional local PDS identity for a local user
#   - encrypt session tokens before persistence
#   - refresh expired access tokens under a database lock
#   - expose non-secret link state to the API and publisher
#
# This file intentionally does NOT retain account passwords, expose raw session
# tokens, host repositories, or subscribe to an AT Protocol firehose.

defmodule Pleroma.ATProto.Links do
  import Ecto.Query

  alias Pleroma.ATProto.Client
  alias Pleroma.ATProto.Crypto
  alias Pleroma.ATProto.Link
  alias Pleroma.ATProto.OAuth
  alias Pleroma.ATProto.URL
  alias Pleroma.Config
  alias Pleroma.Repo
  alias Pleroma.User

  @max_email_bytes 254
  @max_handle_label_bytes 63
  @generated_password_bytes 24

  def connect(%User{local: true} = user, identifier, password)
      when is_binary(identifier) and is_binary(password) do
    identifier = identifier |> String.trim() |> String.trim_leading("@") |> String.downcase()

    with :ok <- may_replace_link(user),
         {:ok, did} <- resolve_did(identifier),
         {:ok, pds_url} <- Client.pds_url(did),
         {:ok, session} <- Client.create_session(pds_url, identifier, password),
         true <- session["did"] == did,
         {:ok, handle} <- Client.verified_handle(did, session["handle"]),
         access when is_binary(access) <- session["accessJwt"],
         refresh when is_binary(refresh) <- session["refreshJwt"],
         {:ok, access_ciphertext} <- Crypto.encrypt(access),
         {:ok, refresh_ciphertext} <- Crypto.encrypt(refresh),
         {:ok, link} <-
           upsert_link(
             user,
             did,
             handle,
             pds_url,
             access_ciphertext,
             refresh_ciphertext,
             false,
             password_auth_attrs()
           ) do
      put_user_extension(user, link)
      {:ok, public_state(link)}
    else
      false -> {:error, :identity_mismatch}
      {:error, {:http, 401, _body}} -> {:error, :invalid_credentials}
      {:error, {:http, 400, _body}} -> {:error, :invalid_credentials}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_session}
    end
  end

  def connect(_user, _identifier, _password), do: {:error, :invalid_credentials}

  def start_oauth(%User{local: true} = user, identifier) when is_binary(identifier) do
    with :ok <- may_replace_link(user) do
      OAuth.start(user, identifier)
    end
  end

  def start_oauth(_user, _identifier), do: {:error, :invalid_identifier}

  def finish_oauth(params) when is_map(params) do
    with {:ok, credentials} <- OAuth.finish(params),
         %User{local: true} = user <- User.get_by_id(credentials.user_id),
         :ok <- may_replace_link(user),
         {:ok, access_ciphertext} <- Crypto.encrypt(credentials.access_token),
         {:ok, refresh_ciphertext} <- Crypto.encrypt(credentials.refresh_token),
         {:ok, dpop_key_ciphertext} <- Crypto.encrypt(credentials.dpop_key),
         {:ok, link} <-
           upsert_link(
             user,
             credentials.did,
             credentials.handle,
             credentials.pds_url,
             access_ciphertext,
             refresh_ciphertext,
             false,
             %{
               auth_method: "oauth",
               oauth_issuer: credentials.issuer,
               oauth_scope: credentials.scope,
               oauth_token_endpoint: credentials.token_endpoint,
               dpop_key_ciphertext: dpop_key_ciphertext,
               auth_dpop_nonce: credentials.authorization_dpop_nonce,
               pds_dpop_nonce: nil
             }
           ) do
      put_user_extension(user, link)
      {:ok, public_state(link)}
    else
      nil -> {:error, :user_not_found}
      error -> error
    end
  end

  def provision_local(%User{local: true} = user) do
    :global.trans({__MODULE__, {:provision_local, user.id}}, fn ->
      case get(user) do
        %Link{} = link -> {:ok, public_state(link)}
        nil -> do_provision_local(user)
      end
    end)
  end

  def provision_local(_user), do: {:error, :not_local}

  def disconnect(%User{id: user_id}) do
    case Repo.get_by(Link, user_id: user_id) do
      %Link{managed: true} ->
        {:error, :managed_identity}

      _ ->
        Link
        |> where(user_id: ^user_id)
        |> Repo.delete_all()

        case User.get_by_id(user_id) do
          %User{} = user -> delete_user_extension(user)
          nil -> :ok
        end

        :ok
    end
  end

  def state(%User{id: user_id} = user) do
    case Repo.get_by(Link, user_id: user_id) do
      %Link{} = link ->
        public_state(link)

      nil ->
        %{
          connected: false,
          oauth_available: true,
          provisioning_available: provisioning_available?(),
          suggested_handle: suggested_handle(user)
        }
    end
  end

  def get(%User{id: user_id}), do: Repo.get_by(Link, user_id: user_id)
  def get(_user), do: nil

  def linked?(%User{} = user), do: match?(%Link{}, get(user))
  def linked?(_user), do: false

  def with_session(%User{} = user, operation) when is_function(operation, 1) do
    with %Link{} = link <- get(user),
         {:ok, session} <- decrypt_session(link) do
      case operation.(session) do
        result ->
          if expired_session?(result), do: refresh_and_retry(link, operation), else: result
      end
    else
      nil -> {:error, :not_linked}
      error -> error
    end
  end

  def with_session(_user, _operation), do: {:error, :not_linked}

  defp refresh_and_retry(link, operation) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "atproto-link:#{link.id}"
      ])

      current = Repo.get!(Link, link.id)

      with {:ok, attrs} <- refreshed_session_attrs(current),
           {:ok, current} <-
             current
             |> Link.changeset(attrs)
             |> Repo.update() do
        current
      else
        error -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, refreshed} ->
        with {:ok, session} <- decrypt_session(refreshed), do: operation.(session)

      {:error, error} ->
        {:error, error}
    end
  end

  defp expired_session?({:error, {:http, status, %{"error" => error}}})
       when status in [400, 401] and error in ["ExpiredToken", "InvalidToken"],
       do: true

  defp expired_session?({:error, {:http, 401, _body}}), do: true
  defp expired_session?(_result), do: false

  defp decrypt_session(link) do
    with {:ok, access_token} <- Crypto.decrypt(link.access_token_ciphertext),
         {:ok, refresh_token} <- Crypto.decrypt(link.refresh_token_ciphertext) do
      session = %{
        did: link.did,
        handle: link.handle,
        pds_url: link.pds_url,
        access_token: access_token,
        refresh_token: refresh_token,
        auth_method: link.auth_method || "password"
      }

      decrypt_authorization(session, link, access_token)
    end
  end

  defp decrypt_authorization(session, %Link{auth_method: "oauth"} = link, access_token) do
    with {:ok, key_json} <- Crypto.decrypt(link.dpop_key_ciphertext) do
      {:ok,
       Map.put(
         session,
         :authorization,
         {:dpop, access_token, key_json, link.pds_dpop_nonce, pds_nonce_callback(link.id)}
       )}
    end
  end

  defp decrypt_authorization(session, _link, access_token) do
    {:ok, Map.put(session, :authorization, access_token)}
  end

  defp refreshed_session_attrs(%Link{auth_method: "oauth"} = link) do
    with {:ok, refresh_token} <- Crypto.decrypt(link.refresh_token_ciphertext),
         {:ok, key_json} <- Crypto.decrypt(link.dpop_key_ciphertext),
         {:ok, token} <-
           OAuth.refresh(
             link.oauth_token_endpoint,
             refresh_token,
             key_json,
             link.auth_dpop_nonce,
             auth_nonce_callback(link.id)
           ),
         true <- is_nil(token["sub"]) or token["sub"] == link.did,
         access when is_binary(access) <- token["access_token"],
         refresh when is_binary(refresh) <- token["refresh_token"],
         {:ok, access_ciphertext} <- Crypto.encrypt(access),
         {:ok, refresh_ciphertext} <- Crypto.encrypt(refresh) do
      {:ok,
       %{
         access_token_ciphertext: access_ciphertext,
         refresh_token_ciphertext: refresh_ciphertext,
         oauth_scope: token["scope"],
         auth_dpop_nonce: token["authorization_dpop_nonce"],
         session_updated_at: DateTime.utc_now()
       }}
    else
      false -> {:error, :oauth_identity_mismatch}
      error -> error
    end
  end

  defp refreshed_session_attrs(link) do
    with {:ok, refresh_token} <- Crypto.decrypt(link.refresh_token_ciphertext),
         {:ok, session} <- Client.refresh_session(link.pds_url, refresh_token),
         true <- session["did"] == link.did,
         {:ok, handle} <- Client.verified_handle(link.did, session["handle"]),
         access when is_binary(access) <- session["accessJwt"],
         refresh when is_binary(refresh) <- session["refreshJwt"],
         {:ok, access_ciphertext} <- Crypto.encrypt(access),
         {:ok, refresh_ciphertext} <- Crypto.encrypt(refresh) do
      {:ok,
       %{
         access_token_ciphertext: access_ciphertext,
         refresh_token_ciphertext: refresh_ciphertext,
         handle: handle,
         session_updated_at: DateTime.utc_now()
       }}
    else
      false -> {:error, :identity_mismatch}
      error -> error
    end
  end

  defp do_provision_local(user) do
    with {:ok, config} <- local_provisioning_config(),
         {:ok, email} <- local_email(user),
         {:ok, handle} <- local_handle(user, config.handle_domain),
         {:ok, %{"code" => invite_code}} <-
           Client.create_invite_code(config.pds_url, config.admin_password),
         password <- generated_password(),
         {:ok, session} <-
           Client.create_account(config.pds_url, handle, email, password, invite_code),
         did when is_binary(did) <- session["did"],
         ^handle <- session["handle"],
         access when is_binary(access) <- session["accessJwt"],
         refresh when is_binary(refresh) <- session["refreshJwt"],
         {:ok, access_ciphertext} <- Crypto.encrypt(access),
         {:ok, refresh_ciphertext} <- Crypto.encrypt(refresh),
         {:ok, link} <-
           upsert_link(
             user,
             did,
             handle,
             config.pds_url,
             access_ciphertext,
             refresh_ciphertext,
             true,
             password_auth_attrs()
           ) do
      put_user_extension(user, link)

      {:ok,
       public_state(link)
       |> Map.put(:account_password, password)
       |> Map.put(:password_shown_once, true)}
    else
      %{"code" => _code} -> {:error, :invalid_invite_response}
      nil -> {:error, :invalid_session}
      error -> error
    end
  end

  defp upsert_link(
         user,
         did,
         handle,
         pds_url,
         access_ciphertext,
         refresh_ciphertext,
         managed,
         auth_attrs
       ) do
    attrs =
      %{
        user_id: user.id,
        did: did,
        handle: String.downcase(handle),
        pds_url: pds_url,
        access_token_ciphertext: access_ciphertext,
        refresh_token_ciphertext: refresh_ciphertext,
        session_updated_at: DateTime.utc_now(),
        managed: managed
      }
      |> Map.merge(auth_attrs)

    case Repo.get_by(Link, user_id: user.id) do
      %Link{} = link -> link |> Link.changeset(attrs) |> Repo.update()
      nil -> %Link{} |> Link.changeset(attrs) |> Repo.insert()
    end
  end

  defp resolve_did("did:" <> _rest = did) do
    case Client.did_document(did) do
      {:ok, %{"id" => ^did}} -> {:ok, did}
      _ -> {:error, :identity_not_found}
    end
  end

  defp resolve_did(handle) do
    case Client.resolve_handle(handle) do
      {:ok, %{"did" => did}} when is_binary(did) -> {:ok, did}
      _ -> {:error, :identity_not_found}
    end
  end

  defp public_state(link) do
    %{
      connected: true,
      did: link.did,
      handle: link.handle,
      pds: link.pds_url,
      managed: link.managed,
      auth_method: link.auth_method || "password",
      oauth_scope: link.oauth_scope,
      updated_at: link.session_updated_at
    }
  end

  defp put_user_extension(user, link) do
    extension = %{
      "did" => link.did,
      "handle" => link.handle,
      "pds" => link.pds_url,
      "profile_url" => "https://bsky.app/profile/#{link.handle}",
      "managed" => link.managed,
      "mirror" => false
    }

    update_user_extensions(user, Map.put(user.actor_extensions || %{}, "atproto", extension))
  end

  defp delete_user_extension(user) do
    update_user_extensions(user, Map.delete(user.actor_extensions || %{}, "atproto"))
  end

  defp update_user_extensions(user, extensions) do
    case user |> Ecto.Changeset.change(actor_extensions: extensions) |> Repo.update() do
      {:ok, updated} -> User.set_cache(updated)
      _ -> :ok
    end
  end

  defp may_replace_link(user) do
    case get(user) do
      %Link{managed: true} -> {:error, :managed_identity}
      _ -> :ok
    end
  end

  defp provisioning_available? do
    match?({:ok, _config}, local_provisioning_config())
  end

  defp suggested_handle(user) do
    with {:ok, %{handle_domain: domain}} <- local_provisioning_config(),
         {:ok, handle} <- local_handle(user, domain) do
      handle
    else
      _ -> nil
    end
  end

  defp local_provisioning_config do
    with true <- Config.get([Pleroma.ATProto, :local_pds_enabled], false),
         pds_url when is_binary(pds_url) <-
           Config.get([Pleroma.ATProto, :local_pds_url]),
         {:ok, pds_url} <- URL.normalize_origin(pds_url),
         handle_domain when is_binary(handle_domain) <-
           Config.get([Pleroma.ATProto, :local_handle_domain]),
         handle_domain <-
           handle_domain |> String.trim() |> String.trim_leading(".") |> String.downcase(),
         true <- URL.public_host?(handle_domain),
         {:ok, admin_password} <- local_pds_admin_password() do
      {:ok,
       %{
         pds_url: pds_url,
         handle_domain: handle_domain,
         admin_password: admin_password
       }}
    else
      _ -> {:error, :provisioning_unavailable}
    end
  end

  defp local_pds_admin_password do
    case Config.get([Pleroma.ATProto, :local_pds_admin_password]) do
      password when is_binary(password) and byte_size(password) > 0 ->
        {:ok, password}

      _ ->
        read_admin_password_file(Config.get([Pleroma.ATProto, :local_pds_admin_password_file]))
    end
  end

  defp read_admin_password_file(path) when is_binary(path) do
    with {:ok, password} <- File.read(path),
         password <- String.trim(password),
         true <- byte_size(password) > 0 do
      {:ok, password}
    else
      _ -> {:error, :provisioning_unavailable}
    end
  end

  defp read_admin_password_file(_path), do: {:error, :provisioning_unavailable}

  defp local_email(%User{email: email})
       when is_binary(email) and byte_size(email) in 3..@max_email_bytes,
       do: {:ok, email}

  defp local_email(_user), do: {:error, :email_required}

  defp local_handle(%User{nickname: nickname, id: user_id}, domain)
       when is_binary(nickname) and is_binary(domain) do
    label =
      nickname
      |> String.normalize(:nfkd)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/u, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
      |> bounded_handle_label(user_id)

    if byte_size(label) in 1..@max_handle_label_bytes do
      {:ok, available_local_handle(label, domain, user_id)}
    else
      {:error, :invalid_local_nickname}
    end
  end

  defp local_handle(_user, _domain), do: {:error, :invalid_local_nickname}

  defp bounded_handle_label(label, _user_id)
       when byte_size(label) <= @max_handle_label_bytes,
       do: label

  defp bounded_handle_label(label, user_id) do
    collision_safe_handle_label(label, user_id)
  end

  defp available_local_handle(label, domain, user_id) do
    handle = "#{label}.#{domain}"

    case Repo.get_by(Link, handle: handle) do
      nil -> handle
      %Link{user_id: ^user_id} -> handle
      %Link{} -> "#{collision_safe_handle_label(label, user_id)}.#{domain}"
    end
  end

  defp collision_safe_handle_label(label, user_id) do
    suffix =
      :crypto.hash(:sha256, to_string(user_id))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 10)

    prefix = label |> binary_part(0, 52) |> String.trim_trailing("-")
    prefix <> "-" <> suffix
  end

  defp generated_password do
    @generated_password_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp password_auth_attrs do
    %{
      auth_method: "password",
      oauth_issuer: nil,
      oauth_scope: nil,
      oauth_token_endpoint: nil,
      dpop_key_ciphertext: nil,
      pds_dpop_nonce: nil,
      auth_dpop_nonce: nil
    }
  end

  defp pds_nonce_callback(link_id) do
    fn nonce ->
      Link
      |> where(id: ^link_id)
      |> Repo.update_all(set: [pds_dpop_nonce: nonce])

      :ok
    end
  end

  defp auth_nonce_callback(link_id) do
    fn nonce ->
      Link
      |> where(id: ^link_id)
      |> Repo.update_all(set: [auth_dpop_nonce: nonce])

      :ok
    end
  end
end

# end of atproto/links.ex
