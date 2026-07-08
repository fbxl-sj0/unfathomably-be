# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Auth.LDAPAuthenticator do
  alias Pleroma.User

  require Logger

  import Pleroma.Web.Auth.Helpers, only: [fetch_credentials: 1, fetch_user: 1]

  @behaviour Pleroma.Web.Auth.Authenticator
  @base Pleroma.Web.Auth.PleromaAuthenticator

  @connection_timeout 10_000
  @search_timeout 10_000

  defdelegate get_registration(conn), to: @base
  defdelegate create_from_registration(conn, registration), to: @base
  defdelegate handle_error(conn, error), to: @base
  defdelegate auth_template, to: @base
  defdelegate oauth_consumer_template, to: @base

  def get_user(%Plug.Conn{} = conn) do
    with {:ldap, true} <- {:ldap, Pleroma.Config.get([:ldap, :enabled])},
         {:ok, {name, password}} <- fetch_credentials(conn),
         %User{} = user <- ldap_user(name, password) do
      {:ok, user}
    else
      {:ldap, _} ->
        @base.get_user(conn)

      error ->
        Logger.error("Could not authenticate LDAP user: #{inspect(error)}")
        {:error, {:ldap_bind_error, error}}
    end
  end

  def change_password(user, password, new_password, new_password) do
    case ldap_change_password(user.nickname, password, new_password) do
      :ok -> {:ok, user}
      error -> error
    end
  end

  def change_password(_, _, _, _), do: {:error, :password_confirmation}

  defp ldap_user(name, password) do
    ldap = Pleroma.Config.get(:ldap, [])

    with_ldap_connection(ldap, fn connection ->
      bind_user(connection, ldap, name, password)
    end)
  end

  defp ldap_change_password(name, password, new_password) do
    ldap = Pleroma.Config.get(:ldap, [])

    with_ldap_connection(ldap, fn connection ->
      dn = make_dn(ldap, name)

      with :ok <- :eldap.simple_bind(connection, dn, password) do
        :eldap.modify_password(connection, dn, to_charlist(new_password), to_charlist(password))
      end
    end)
  end

  defp with_ldap_connection(ldap, fun) do
    host = Keyword.get(ldap, :host, "localhost")
    port = Keyword.get(ldap, :port, 389)
    ssl = Keyword.get(ldap, :ssl, false)
    tls = Keyword.get(ldap, :tls, false)
    cacertfile = Keyword.get(ldap, :cacertfile) || CAStore.file_path()

    if ssl or tls do
      :application.ensure_all_started(:ssl)
    end

    default_secure_opts = [
      verify: :verify_peer,
      cacerts: decode_certfile(cacertfile),
      customize_hostname_check: [
        fqdn_fun: fn _ -> to_charlist(host) end
      ]
    ]

    sslopts = Keyword.merge(default_secure_opts, Keyword.get(ldap, :sslopts, []))
    tlsopts = Keyword.merge(default_secure_opts, Keyword.get(ldap, :tlsopts, []))

    options = [{:port, port}, {:ssl, ssl}, {:timeout, @connection_timeout}]
    options = if ssl, do: [{:sslopts, sslopts} | options], else: options

    case :eldap.open([to_charlist(host)], options) do
      {:ok, connection} ->
        try do
          case maybe_start_tls(connection, tls, tlsopts) do
            :ok ->
              fun.(connection)

            error ->
              Logger.error("Could not start TLS: #{inspect(error)}")
              error
          end
        after
          :eldap.close(connection)
        end

      {:error, error} ->
        Logger.error("Could not open LDAP connection: #{inspect(error)}")
        {:error, {:ldap_connection_error, error}}
    end
  end

  defp maybe_start_tls(_connection, false, _tlsopts), do: :ok

  defp maybe_start_tls(connection, true, tlsopts) do
    :eldap.start_tls(connection, tlsopts, @connection_timeout)
  end

  defp bind_user(connection, ldap, name, password) do
    case :eldap.simple_bind(connection, make_dn(ldap, name), password) do
      :ok ->
        case fetch_user(name) do
          %User{} = user ->
            user

          _ ->
            uid = Keyword.get(ldap, :uid, "cn")
            base = Keyword.get(ldap, :base)

            register_user(connection, base, uid, name)
        end

      error ->
        error
    end
  end

  defp register_user(connection, base, uid, name) do
    ldap = Pleroma.Config.get(:ldap, [])
    mail_attribute = Keyword.get(ldap, :mail) || "mail"

    case :eldap.search(connection, [
           {:base, to_charlist(base)},
           {:filter, :eldap.equalityMatch(to_charlist(uid), to_charlist(name))},
           {:scope, :eldap.wholeSubtree()},
           {:timeout, @search_timeout}
         ]) do
      # OTP 24.3 added a controls field to the :eldap_search_result record.
      # Accept both shapes so automatic LDAP account registration keeps working
      # across Erlang/OTP release trains.
      {:ok, {:eldap_search_result, [{:eldap_entry, _, attributes}], _}} ->
        try_register(name, attributes, mail_attribute)

      {:ok, {:eldap_search_result, [{:eldap_entry, _, attributes}], _, _}} ->
        try_register(name, attributes, mail_attribute)

      error ->
        Logger.error("Could not register LDAP user #{name}: #{inspect(error)}")
        {:error, {:ldap_search_error, error}}
    end
  end

  defp try_register(name, attributes, mail_attribute) do
    params = %{
      name: name,
      nickname: name,
      password: nil
    }

    params =
      case List.keyfind(attributes, to_charlist(mail_attribute), 0) do
        {_, [mail]} -> Map.put_new(params, :email, :erlang.list_to_binary(mail))
        _ -> params
      end

    changeset = User.register_changeset_ldap(%User{}, params)

    case User.register(changeset) do
      {:ok, user} -> user
      error -> error
    end
  end

  defp decode_certfile(file) do
    with {:ok, data} <- File.read(file) do
      data
      |> :public_key.pem_decode()
      |> Enum.map(fn {_, cert, _} -> cert end)
    else
      _ ->
        Logger.error("Unable to read LDAP certfile: #{file}")
        []
    end
  end

  defp make_dn(ldap, name) do
    uid = Keyword.get(ldap, :uid, "cn")
    base = Keyword.get(ldap, :base)
    "#{uid}=#{name},#{base}"
  end
end
