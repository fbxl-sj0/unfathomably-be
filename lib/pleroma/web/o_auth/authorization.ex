# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.OAuth.Authorization do
  use Ecto.Schema

  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.OAuth.App
  alias Pleroma.Web.OAuth.Authorization
  alias Pleroma.Web.OAuth.Token

  import Ecto.Changeset
  import Ecto.Query

  @type t :: %__MODULE__{}
  @derive {Inspect, except: [:token]}

  @pkce_value_regex ~r/\A[A-Za-z0-9\-._~]{43,128}\z/

  schema "oauth_authorizations" do
    field(:token, :string)
    field(:scopes, {:array, :string}, default: [])
    field(:valid_until, :naive_datetime_usec)
    field(:used, :boolean, default: false)
    field(:redirect_uri, :string)
    field(:code_challenge, :string)
    field(:code_challenge_method, :string)
    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)
    belongs_to(:app, App)

    timestamps()
  end

  @spec create_authorization(App.t(), User.t() | %{}, [String.t()] | nil, map()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def create_authorization(%App{} = app, %User{} = user, scopes \\ nil, attrs \\ %{}) do
    %{
      scopes: scopes || app.scopes,
      user_id: user.id,
      app_id: app.id,
      redirect_uri: attrs["redirect_uri"] || attrs[:redirect_uri],
      code_challenge: attrs["code_challenge"] || attrs[:code_challenge],
      code_challenge_method: attrs["code_challenge_method"] || attrs[:code_challenge_method]
    }
    |> create_changeset()
    |> Repo.insert()
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs \\ %{}) do
    %Authorization{}
    |> cast(attrs, [
      :user_id,
      :app_id,
      :scopes,
      :valid_until,
      :redirect_uri,
      :code_challenge,
      :code_challenge_method
    ])
    |> validate_required([:app_id, :scopes])
    |> validate_pkce()
    |> add_token()
    |> add_lifetime()
  end

  defp validate_pkce(changeset) do
    challenge = get_field(changeset, :code_challenge)
    method = get_field(changeset, :code_challenge_method)

    cond do
      is_nil(challenge) and is_nil(method) ->
        changeset

      is_nil(challenge) ->
        add_error(changeset, :code_challenge, "is required when a challenge method is supplied")

      not Regex.match?(@pkce_value_regex, challenge) ->
        add_error(changeset, :code_challenge, "must be a valid RFC 7636 challenge")

      is_nil(method) ->
        put_change(changeset, :code_challenge_method, "plain")

      method in ["plain", "S256"] ->
        changeset

      true ->
        add_error(changeset, :code_challenge_method, "must be plain or S256")
    end
  end

  @doc "Validates redirect URI and PKCE values before an authorization code is consumed."
  @spec validate_exchange(t(), map()) :: :ok | {:error, atom()}
  def validate_exchange(%Authorization{} = auth, params) do
    with :ok <- validate_redirect_uri(auth, params),
         :ok <- validate_code_verifier(auth, params) do
      :ok
    end
  end

  defp validate_redirect_uri(%Authorization{redirect_uri: nil}, _params), do: :ok

  defp validate_redirect_uri(%Authorization{redirect_uri: redirect_uri}, %{
         "redirect_uri" => redirect_uri
       }),
       do: :ok

  defp validate_redirect_uri(_auth, _params), do: {:error, :redirect_uri_mismatch}

  defp validate_code_verifier(%Authorization{code_challenge: nil}, _params), do: :ok

  defp validate_code_verifier(
         %Authorization{code_challenge: challenge, code_challenge_method: method},
         %{"code_verifier" => verifier}
       )
       when is_binary(verifier) do
    with true <- Regex.match?(@pkce_value_regex, verifier),
         {:ok, calculated} <- calculate_code_challenge(method, verifier),
         true <- byte_size(calculated) == byte_size(challenge),
         true <- Plug.Crypto.secure_compare(calculated, challenge) do
      :ok
    else
      _ -> {:error, :invalid_code_verifier}
    end
  end

  defp validate_code_verifier(_auth, _params), do: {:error, :invalid_code_verifier}

  defp calculate_code_challenge("plain", verifier), do: {:ok, verifier}

  defp calculate_code_challenge("S256", verifier) do
    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    {:ok, challenge}
  end

  defp calculate_code_challenge(_method, _verifier), do: {:error, :unsupported_method}

  defp add_token(changeset) do
    token = Pleroma.Crypto.Random.urlsafe(:high)
    put_change(changeset, :token, token)
  end

  defp add_lifetime(changeset) do
    lifespan = Token.lifespan()
    put_change(changeset, :valid_until, NaiveDateTime.add(NaiveDateTime.utc_now(), lifespan))
  end

  @spec use_changeset(Authorization.t(), map()) :: Ecto.Changeset.t()
  def use_changeset(%Authorization{} = auth, params) do
    auth
    |> cast(params, [:used])
    |> validate_required([:used])
  end

  @spec use_token(Authorization.t()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def use_token(%Authorization{used: false, valid_until: valid_until} = auth) do
    if NaiveDateTime.diff(NaiveDateTime.utc_now(), valid_until) < 0 do
      Repo.update(use_changeset(auth, %{used: true}))
    else
      {:error, "token expired"}
    end
  end

  def use_token(%Authorization{used: true}), do: {:error, "already used"}

  @spec delete_user_authorizations(User.t()) :: {integer(), any()}
  def delete_user_authorizations(%User{} = user) do
    user
    |> delete_by_user_query
    |> Repo.delete_all()
  end

  def delete_by_user_query(%User{id: user_id}) do
    from(a in __MODULE__, where: a.user_id == ^user_id)
  end

  @doc "gets auth for app by token"
  @spec get_by_token(App.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_by_token(%App{id: app_id} = _app, token) do
    from(t in __MODULE__, where: t.app_id == ^app_id and t.token == ^token)
    |> Repo.find_resource()
  end
end
