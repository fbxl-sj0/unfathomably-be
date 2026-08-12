# Unfathomably FASP registration
# ------------------------------
#
# File: registration.ex
#
# Purpose:
#   Store and review FASP trust-on-first-contact registration requests.
#
# Responsibilities:
#   - normalize the provider identity received over the registration API
#   - generate and encrypt a unique local identity for each provider
#   - make repeated identical signed registrations idempotent
#   - enforce explicit administrator approval before capabilities can be used
#
# This file intentionally does not activate capabilities, fetch provider
# information, send discovery data, or perform network requests.

defmodule Pleroma.FASP.Registration do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.FASP.Crypto
  alias Pleroma.Repo
  alias Pleroma.Web.Endpoint

  @states ~w[pending accepted rejected]
  @maximum_name_length 200
  @maximum_server_id_length 255

  schema "fasp_registrations" do
    field(:name, :string)
    field(:base_url, :string)
    field(:provider_server_id, :string)
    field(:provider_public_key, :binary)
    field(:fasp_id, :string)
    field(:local_public_key, :binary)
    field(:local_private_key_ciphertext, :string)
    field(:state, :string, default: "pending")
    field(:provider_info, :map, default: %{})
    field(:active_capabilities, {:array, :map}, default: [])
    field(:approved_at, :utc_datetime_usec)
    field(:rejected_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def enabled?, do: Config.get([:fasp, :enabled], false)

  def normalize(%{
        "name" => name,
        "baseUrl" => base_url,
        "serverId" => server_id,
        "publicKey" => encoded_public_key
      }) do
    with {:ok, name} <- normalize_name(name),
         {:ok, base_url} <- normalize_base_url(base_url),
         {:ok, server_id} <- normalize_server_id(server_id),
         {:ok, public_key} <- decode_public_key(encoded_public_key) do
      {:ok,
       %{
         name: name,
         base_url: base_url,
         provider_server_id: server_id,
         provider_public_key: public_key
       }}
    end
  end

  def normalize(_), do: {:error, :invalid_registration}

  def create(normalized) when is_map(normalized) do
    case Repo.get_by(__MODULE__, base_url: normalized.base_url) do
      nil -> create_new(normalized)
      %__MODULE__{} = registration -> existing_registration(registration, normalized)
    end
  end

  def list do
    __MODULE__
    |> order_by([registration],
      asc:
        fragment(
          "CASE ? WHEN 'pending' THEN 0 WHEN 'accepted' THEN 1 ELSE 2 END",
          registration.state
        ),
      desc: registration.inserted_at
    )
    |> Repo.all()
  end

  def accepted_with_capability(capability, version)
      when is_binary(capability) and is_binary(version) do
    __MODULE__
    |> where(state: "accepted")
    |> order_by([registration], asc: registration.id)
    |> Repo.all()
    |> Enum.filter(&capability_active?(&1, capability, version))
  end

  def accepted_with_capability(_, _), do: []

  def get(id) when is_integer(id), do: Repo.get(__MODULE__, id)

  def get(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> get(parsed)
      _ -> nil
    end
  end

  def get(_), do: nil

  def approve(%__MODULE__{state: "accepted"} = registration), do: {:ok, registration}
  def approve(%__MODULE__{state: "rejected"}), do: {:error, :rejected}

  def approve(%__MODULE__{} = registration) do
    registration
    |> state_changeset(%{
      state: "accepted",
      approved_at: current_time(),
      rejected_at: nil
    })
    |> Repo.update()
  end

  def reject(%__MODULE__{state: "rejected"} = registration), do: {:ok, registration}

  def reject(%__MODULE__{} = registration) do
    registration
    |> state_changeset(%{
      state: "rejected",
      approved_at: nil,
      rejected_at: current_time(),
      active_capabilities: []
    })
    |> Repo.update()
  end

  def delete_rejected(%__MODULE__{state: "rejected"} = registration) do
    Repo.delete(registration)
  end

  def delete_rejected(%__MODULE__{}), do: {:error, :not_rejected}

  def update_provider_info(%__MODULE__{state: "accepted"} = registration, provider_info)
      when is_map(provider_info) do
    registration
    |> change(provider_info: provider_info)
    |> Repo.update()
  end

  def update_provider_info(%__MODULE__{}, _provider_info), do: {:error, :not_accepted}

  def set_capability(
        %__MODULE__{state: "accepted"} = registration,
        capability,
        version,
        enabled
      )
      when is_binary(capability) and is_binary(version) and is_boolean(enabled) do
    selected = %{"id" => capability, "version" => version}

    active_capabilities =
      registration.active_capabilities
      |> Enum.reject(fn
        %{"id" => ^capability, "version" => ^version} -> true
        _ -> false
      end)
      |> then(fn capabilities ->
        if(enabled, do: [selected | capabilities], else: capabilities)
      end)
      |> Enum.sort_by(&{&1["id"], &1["version"]})

    registration
    |> change(active_capabilities: active_capabilities)
    |> Repo.update()
  end

  def set_capability(%__MODULE__{}, _capability, _version, _enabled),
    do: {:error, :not_accepted}

  def capability_active?(%__MODULE__{} = registration, capability, version) do
    Enum.any?(registration.active_capabilities, fn
      %{"id" => ^capability, "version" => ^version} -> true
      _ -> false
    end)
  end

  def provider_fingerprint(%__MODULE__{} = registration) do
    Crypto.fingerprint(registration.provider_public_key)
  end

  def local_fingerprint(%__MODULE__{} = registration) do
    Crypto.fingerprint(registration.local_public_key)
  end

  def completion_uri(%__MODULE__{} = registration) do
    Endpoint.url() <> "/pleroma/admin/fasps?registration=#{registration.id}"
  end

  def public_json(%__MODULE__{} = registration) do
    %{
      id: registration.id,
      name: registration.name,
      base_url: registration.base_url,
      provider_server_id: registration.provider_server_id,
      provider_public_key: Base.encode64(registration.provider_public_key),
      provider_fingerprint: provider_fingerprint(registration),
      fasp_id: registration.fasp_id,
      local_public_key: Base.encode64(registration.local_public_key),
      local_fingerprint: local_fingerprint(registration),
      state: registration.state,
      provider_info: registration.provider_info,
      active_capabilities: registration.active_capabilities,
      approved_at: registration.approved_at,
      rejected_at: registration.rejected_at,
      inserted_at: registration.inserted_at,
      updated_at: registration.updated_at
    }
  end

  defp create_new(normalized) do
    with :ok <- ensure_pending_capacity(),
         {:ok, local_public_key, local_private_key} <- Crypto.generate_keypair(),
         {:ok, ciphertext} <- Crypto.encrypt_private_key(local_private_key) do
      attrs =
        normalized
        |> Map.merge(%{
          fasp_id: generate_identifier(),
          local_public_key: local_public_key,
          local_private_key_ciphertext: ciphertext,
          state: "pending",
          provider_info: %{},
          active_capabilities: []
        })

      %__MODULE__{}
      |> registration_changeset(attrs)
      |> Repo.insert()
      |> resolve_insert_race(normalized)
    end
  end

  defp existing_registration(registration, normalized) do
    cond do
      registration.provider_server_id != normalized.provider_server_id ->
        {:error, :registration_conflict}

      registration.provider_public_key != normalized.provider_public_key ->
        {:error, :registration_conflict}

      registration.state == "rejected" ->
        {:error, :rejected}

      true ->
        {:ok, registration}
    end
  end

  defp resolve_insert_race({:ok, registration}, _normalized), do: {:ok, registration}

  defp resolve_insert_race({:error, %Ecto.Changeset{} = changeset}, normalized) do
    if changeset.errors[:base_url] || changeset.errors[:provider_server_id] do
      case Repo.get_by(__MODULE__, base_url: normalized.base_url) do
        %__MODULE__{} = registration -> existing_registration(registration, normalized)
        nil -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp registration_changeset(registration, attrs) do
    registration
    |> cast(attrs, [
      :name,
      :base_url,
      :provider_server_id,
      :provider_public_key,
      :fasp_id,
      :local_public_key,
      :local_private_key_ciphertext,
      :state,
      :provider_info,
      :active_capabilities
    ])
    |> validate_required([
      :name,
      :base_url,
      :provider_server_id,
      :provider_public_key,
      :fasp_id,
      :local_public_key,
      :local_private_key_ciphertext,
      :state
    ])
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:base_url)
    |> unique_constraint(:provider_server_id)
    |> unique_constraint(:fasp_id)
  end

  defp state_changeset(registration, attrs) do
    registration
    |> cast(attrs, [:state, :approved_at, :rejected_at, :active_capabilities])
    |> validate_required([:state])
    |> validate_inclusion(:state, @states)
  end

  defp normalize_name(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" && String.length(value) <= @maximum_name_length &&
         !String.match?(value, ~r/[\x00-\x1F\x7F]/) do
      {:ok, value}
    else
      {:error, :invalid_name}
    end
  end

  defp normalize_name(_), do: {:error, :invalid_name}

  defp normalize_base_url(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        query: nil,
        fragment: nil
      } = uri
      when is_binary(host) and byte_size(host) > 0 ->
        normalized =
          uri
          |> Map.put(:host, String.downcase(host))
          |> Map.update!(:path, &normalize_path/1)
          |> URI.to_string()
          |> String.trim_trailing("/")

        if byte_size(normalized) <= 2_048,
          do: {:ok, normalized},
          else: {:error, :invalid_base_url}

      _ ->
        {:error, :invalid_base_url}
    end
  rescue
    URI.Error -> {:error, :invalid_base_url}
  end

  defp normalize_base_url(_), do: {:error, :invalid_base_url}

  defp normalize_path(path) when path in [nil, "", "/"], do: ""
  defp normalize_path(path), do: "/" <> (path |> String.trim() |> String.trim("/"))

  defp normalize_server_id(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" && String.length(value) <= @maximum_server_id_length &&
         String.match?(value, ~r/\A[A-Za-z0-9._:@\/-]+\z/) do
      {:ok, value}
    else
      {:error, :invalid_server_id}
    end
  end

  defp normalize_server_id(_), do: {:error, :invalid_server_id}

  defp decode_public_key(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, public_key} when byte_size(public_key) == 32 -> {:ok, public_key}
      _ -> {:error, :invalid_public_key}
    end
  end

  defp decode_public_key(_), do: {:error, :invalid_public_key}

  defp ensure_pending_capacity do
    maximum = Config.get([:fasp, :max_pending_registrations], 100)

    pending =
      Repo.aggregate(
        from(registration in __MODULE__, where: registration.state == "pending"),
        :count
      )

    if is_integer(maximum) && maximum > 0 && pending < maximum do
      :ok
    else
      {:error, :too_many_pending}
    end
  end

  defp generate_identifier do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp current_time do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end
end

# end of registration.ex
