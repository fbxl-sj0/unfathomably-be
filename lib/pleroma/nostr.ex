# Unfathomably BE
# ----------------
#
# File: nostr.ex
#
# Purpose:
#   Define the public boundary for optional Nostr interoperability.
#
# Responsibilities:
#   - expose runtime feature and relay metadata
#   - constrain relay selection to administrator policy
#   - route NIP-19 identifiers into the bridge identity layer
#   - enqueue post-transaction ActivityPub export work
#
# This file intentionally does NOT parse relay frames, persist events, or
# translate activities.

defmodule Pleroma.Nostr do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Keys
  alias Pleroma.Nostr.Protocol
  alias Pleroma.User
  alias Pleroma.Workers.NostrProxyReconcileWorker
  alias Pleroma.Workers.NostrPublishWorker

  @supported_nips [
    1,
    2,
    5,
    9,
    10,
    11,
    17,
    18,
    19,
    21,
    22,
    23,
    24,
    25,
    27,
    29,
    30,
    36,
    38,
    39,
    40,
    42,
    44,
    45,
    48,
    50,
    51,
    52,
    53,
    56,
    58,
    59,
    65,
    70,
    72,
    73,
    88,
    92
  ]

  def enabled?, do: Config.get([__MODULE__, :enabled], false) == true

  def bridge_enabled? do
    enabled?() and match?({:ok, _private_key}, Keys.private_key("relay"))
  end

  def supported_nips, do: @supported_nips

  def relay_path do
    case Config.get([__MODULE__, :relay_path], "/relay") do
      "/" <> _rest = path -> path
      _invalid -> "/relay"
    end
  end

  def relay_url do
    configured = Config.get([__MODULE__, :relay_url])

    if is_binary(configured) and configured != "" do
      Protocol.normalize_relay_url(configured)
    else
      endpoint_relay_url()
    end
  end

  def instance_metadata do
    if bridge_enabled?() do
      {:ok, pubkey} = Keys.public_key("relay")

      %{
        enabled: true,
        pubkey: pubkey,
        relay: relay_url(),
        supported_nips: @supported_nips,
        nip29: %{subgroups: false}
      }
    end
  end

  def configured_relays do
    [
      Config.get([__MODULE__, :external_relays], []),
      Config.get([__MODULE__, :discovery_relays], []),
      response_relays(),
      group_relays()
    ]
    |> List.flatten()
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&compatibility_relay?/1)
    |> Enum.uniq()
  end

  def response_relays do
    Config.get([__MODULE__, :response_relays], [])
    |> List.wrap()
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&compatibility_relay?/1)
    |> Enum.reject(&(&1 == relay_url()))
    |> Enum.uniq()
  end

  def profile_discovery_relays do
    configured = configured_profile_discovery_relays()

    relays = if configured == [], do: configured_profile_fallback_relays(), else: configured
    group_relays = group_relays()

    relays
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&compatibility_relay?/1)
    |> Enum.reject(&(&1 == relay_url()))
    |> Enum.reject(&(&1 in group_relays))
    |> Enum.uniq()
  end

  @doc "Returns approved public write destinations with configured fallback relays."
  def public_relay_destinations(primary_relays) do
    (List.wrap(primary_relays) ++ profile_discovery_relays())
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&allowed_relay?/1)
    |> Enum.reject(&(&1 == relay_url()))
    |> Enum.uniq()
  end

  def group_relays do
    Config.get([__MODULE__, :group_relays], [])
    |> List.wrap()
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&compatibility_relay?/1)
    |> Enum.reject(&(&1 == relay_url()))
    |> Enum.uniq()
  end

  def search_relays do
    Config.get([__MODULE__, :search_relays], [])
    |> List.wrap()
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&compatibility_relay?/1)
    |> Enum.reject(&(&1 == relay_url()))
    |> Enum.uniq()
  end

  defp configured_profile_fallback_relays do
    [
      Config.get([__MODULE__, :external_relays], []),
      Config.get([__MODULE__, :discovery_relays], []),
      group_relays()
    ]
    |> List.flatten()
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&compatibility_relay?/1)
    |> Enum.uniq()
  end

  defp configured_profile_discovery_relays do
    Config.get([__MODULE__, :profile_discovery_relays], [])
    |> List.wrap()
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  def compatibility_relay?(relay_url) when is_binary(relay_url) do
    with relay_url when is_binary(relay_url) <- Protocol.normalize_relay_url(relay_url),
         %URI{host: host} when is_binary(host) <- URI.parse(relay_url) do
      normalized_host = String.downcase(host)

      Config.get([__MODULE__, :mostr_hosts], ["mostr.pub"])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.any?(fn allowed_host ->
        normalized_host == allowed_host or
          String.ends_with?(normalized_host, "." <> allowed_host)
      end)
    else
      _ -> false
    end
  rescue
    URI.Error -> false
  end

  def compatibility_relay?(_relay_url), do: false

  def allowed_relay?(relay_url) do
    relay_url = Protocol.normalize_relay_url(relay_url)

    is_binary(relay_url) and not compatibility_relay?(relay_url) and
      (relay_url == relay_url() or relay_url in configured_relays() or
         relay_url in configured_profile_discovery_relays() or
         relay_url in search_relays() or
         Config.get([__MODULE__, :allow_user_relays], false) == true)
  end

  def resolve(identifier, requested_kind \\ :any)

  def resolve(identifier, requested_kind) when is_binary(identifier) do
    if enabled?() do
      with {:ok, identity} <- Protocol.decode_identifier(identifier),
           {:ok, user} <- Identity.resolve(identity),
           true <- requested_kind in [:any, identity.kind] do
        {:ok, user}
      else
        _ -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  def resolve(_identifier, _requested_kind), do: {:error, :not_found}

  def maybe_enqueue_activity(%Activity{} = activity, meta) do
    nostr_ingest? = Keyword.get(meta, :nostr_ingest, false)

    cond do
      bridge_enabled?() and activity.local and not nostr_ingest? ->
        NostrPublishWorker.enqueue_activity(activity.id)

      bridge_enabled?() and not activity.local and not nostr_ingest? ->
        NostrProxyReconcileWorker.enqueue_activity(activity)

      true ->
        :ok
    end

    :ok
  end

  def maybe_enqueue_activity(_activity, _meta), do: :ok

  def maybe_enqueue_unfollow(
        %Activity{} = activity,
        %User{} = follower,
        %User{} = unfollowed
      ) do
    if bridge_enabled?() and activity.local and Identity.mirror?(unfollowed) do
      NostrPublishWorker.enqueue_unfollow(activity.id, follower.id, unfollowed.id)
    end

    :ok
  end

  def maybe_enqueue_unfollow(_activity, _follower, _unfollowed), do: :ok

  defp endpoint_relay_url do
    case Pleroma.Web.Endpoint.url() |> URI.parse() do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        ws_scheme = if scheme == "https", do: "wss", else: "ws"
        default_port? = (ws_scheme == "wss" and port == 443) or (ws_scheme == "ws" and port == 80)
        authority = if is_integer(port) and not default_port?, do: "#{host}:#{port}", else: host
        "#{ws_scheme}://#{authority}#{relay_path()}"

      _invalid ->
        nil
    end
  end
end

# end of nostr.ex
