# Optional Feature Enablement

Unfathomably can participate in more than the baseline ActivityPub social
network. Some integrations are enabled by default, some require an operator
secret or an external service, and some require each user to link an account.
This guide collects those requirements in one place.

Follow the main [installation guide](INSTALLATION.MD) first. Enable optional
features only after the backend, database, reverse proxy, TLS certificate, and
frontend are working normally.

## Capability map

| Feature | Default source-install state | Required operator work |
| --- | --- | --- |
| ActivityPub accounts, groups, events, and Worlds | Enabled | Install the current Unfathomably FE and keep background jobs running |
| AT Protocol and Bluesky reading | Enabled in production | Keep the public AppView reachable and let users link identities |
| AT Protocol and Bluesky publishing | Per-user opt-in | Configure public OAuth metadata and link each user account |
| Nostr relay and bridge | Disabled | Set a permanent bridge secret, enable the relay, and review external relays |
| Diaspora federation | Enabled in production | Preserve WebFinger, h-card, and receive routes through the reverse proxy |
| Tor onion fetching | Disabled | Install a non-relay Tor client and enable the dedicated onion HTTP adapter |
| Tor onion entrance | Not created automatically | Configure a separate hidden service on the reverse-proxy host |
| RSS and Atom sources | Enabled | Keep the RSS ingest worker enabled and follow sources through the source UI |
| Worlds discovery catalogues | Enabled with conservative defaults | Add only reviewed indexes and create or follow local actors to seed useful data |
| Translation | No provider selected | Run OpenTranslate or a compatible service and select the provider |
| Meilisearch | Database search only | Install Meilisearch, configure its key, and build the indexes |
| Web push | Disabled until complete VAPID details exist | Generate and configure a VAPID keypair and subject |
| FASP services | Framework enabled | Review and approve each service registration in administration |

## Before enabling optional features

Use the same public HTTPS origin for the backend and frontend. OAuth callbacks,
WebFinger documents, ActivityPub identifiers, WebSocket URLs, and media links
all depend on the configured endpoint URL being externally correct.

Keep secrets out of tracked source files. Put them in the production secret
configuration, a root-owned environment file, or a root-owned password file.
Back up identity-defining secrets before restarting the service.

ConfigDB can override file configuration. If a feature remains disabled after
editing the production configuration, inspect the matching setting in AdminFE
or with the ConfigDB CLI tasks. Remove stale overrides rather than maintaining
two conflicting definitions.

Install a frontend release built for the same backend release. New protocol
support often includes settings pages, profile identifiers, native object
views, and streaming routes that an older frontend cannot expose.

Restart one backend instance after a configuration change and inspect its
startup logs before applying the same change to other nodes.

## AT Protocol and Bluesky

Unfathomably uses selective AT Protocol interoperability. It resolves linked
identities, followed handles, explicit links, replies, and requested records.
It does not ingest the Bluesky firehose or mirror the global network.

### Backend configuration

Production builds enable the integration by default. An explicit configuration
is easier to audit:

```elixir
config :pleroma, Pleroma.ATProto,
  enabled: true,
  appview_url: "https://public.api.bsky.app",
  request_timeout_ms: 10_000,
  identity_cache_seconds: 900,
  future_tolerance_seconds: 900
```

The AppView is used for public reads and identity resolution. Do not point it
at an untrusted service that can observe or manipulate private credentials.

The backend publishes OAuth client metadata at:

```text
https://social.example/api/v1/atproto/oauth/client-metadata.json
```

That URL and its callback must be publicly reachable over HTTPS. Preserve the
original host and scheme through the reverse proxy so generated OAuth URLs use
the public origin.

### Link a user

Open `/settings/atproto` while signed in and start the OAuth flow. OAuth with
PKCE and DPoP is preferred. The app-password form remains available for PDS
implementations that do not support the OAuth flow.

Account linking is per user. Enabling the integration globally does not grant
the server permission to publish for every local account.

After linking, verify that the settings page reports the expected DID, handle,
PDS, and write capability. Test a post, reply, like, repost, follow, and delete
with a disposable record before announcing the integration.

### Optional local PDS provisioning

Local provisioning is separate from the selective bridge. It requires a real
PDS service with an administrative API:

```elixir
config :pleroma, Pleroma.ATProto,
  local_pds_enabled: true,
  local_pds_url: "https://pds.example",
  local_handle_domain: "bsky.example",
  local_pds_admin_password_file: "/etc/pleroma/pds-admin-password"
```

The password file should be readable only by the backend service account.
Provisioning does not install, update, back up, or monitor the PDS itself.

## Nostr

Nostr identities are deterministically derived from one permanent bridge
secret. Changing that secret changes every derived local Nostr identity, so
treat it like a signing key rather than an ordinary cache secret.

### Create and store the bridge secret

```sh
install -o root -g pleroma -m 0640 /dev/null /etc/pleroma/nostr.env
printf 'NOSTR_BRIDGE_SECRET=%s\n' "$(openssl rand -hex 32)" \
  > /etc/pleroma/nostr.env
```

Add the environment file to the systemd service:

```ini
[Service]
EnvironmentFile=/etc/pleroma/nostr.env
```

The value must contain at least 32 bytes of stable secret material. Back up the
file securely before enabling the bridge.

### Enable and review the relay configuration

```elixir
config :pleroma, Pleroma.Nostr,
  enabled: true,
  relay_path: "/relay",
  relay_url: "wss://social.example/relay",
  external_relays: [
    "wss://relay.nostr.com",
    "wss://nostr.mom",
    "wss://relay.primal.net"
  ],
  response_relays: [
    "wss://relay.snort.social",
    "wss://nos.lol",
    "wss://relay.damus.io"
  ],
  allow_user_relays: false,
  publish_public_posts: true
```

External relays are read and write dependencies. Review their policies,
availability, retention, and jurisdiction. A short diverse list is preferable
to broadcasting every event to an unbounded relay list.

Response relays are read-only bridge dependencies used to find replies,
reactions, reposts, and deletions that Nostr clients publish away from the
original post's relay. Their subscriptions are limited to events tagging local
Nostr identities, replay at most seven days after a reconnect, and still require
a signed reference to an event exported by this server before import.

Unknown response authors are initially projected with a deterministic local
placeholder, then hydrated from signed kind-0 metadata on their approved native
relay and the configured response-relay pool. A bounded periodic sweep retries
older placeholders once per day, while content history remains disabled until
a genuine local account follows them.

Keep `allow_user_relays` disabled unless operators deliberately want users to
add arbitrary outbound destinations. Dedicated discovery, group, profile, and
search relay lists can be configured when those workloads should use different
relays.

The reverse proxy must pass WebSocket upgrades for `/relay`. Verify the NIP-11
document and then connect with a small independent client:

```sh
curl -H 'Accept: application/nostr+json' https://social.example/relay
```

Check that replies retain root and parent tags, media URLs are public, profile
metadata is present, and reactions arrive as Nostr reactions rather than
standalone text.

## Diaspora

Diaspora interoperability is selective and does not turn Unfathomably into a
full Diaspora pod. Production builds enable the supported path by default:

```elixir
config :pleroma, Pleroma.Diaspora,
  enabled: true
```

The public reverse proxy must preserve these routes:

| Route | Purpose |
| --- | --- |
| `/.well-known/webfinger` | Account discovery |
| `/hcard/users/:nickname` | Diaspora profile document |
| `/receive/users/:nickname` | User delivery endpoint |
| `/receive/public` | Public delivery endpoint |

Confirm that a local account's WebFinger response includes Diaspora links and
that h-card URLs use the public HTTPS host. Do not cache POST requests to the
receive endpoints.

## Tor

Tor has two independent modes:

| Mode | Result |
| --- | --- |
| Outbound onion fetching | The backend can fetch valid `.onion` ActivityPub resources through a loopback SOCKS client |
| Inbound onion entrance | Tor users can reach the existing public service through an alternate hidden-service address |

Neither mode makes the server a Tor exit node. Outbound support does not create
an onion address, and an inbound onion address does not change canonical
ActivityPub IDs away from the configured clearnet origin.

Follow [Tor onion federation](configuration/onion_federation.md) for the
complete client-only and hidden-service procedures.

## Worlds, native objects, and discovery

Worlds presents specialized federated objects such as books, reviews, events,
videos, audio, software projects, issues, marketplace listings, mutual-aid
requests, routes, chess games, and 3D models.

The feature intentionally does not crawl every compatible network. Useful
local data appears when users create an object, follow a compatible actor,
resolve a known URL or handle, import a source, or use a reviewed catalogue.
This keeps disk use and remote traffic bounded.

### Install the matching frontend

The backend APIs alone are not a usable Worlds workflow. Install the matching
Unfathomably FE so native object pages, create forms, profile tabs, discovery
views, post-shaped entries, and WebSocket updates are available.

### Review discovery sources

The source defaults in `config/config.exs` include conservative lists for
PeerTube, Mobilizon, Gancio, BookWyrm, NeoDB, Funkwhale, Castling.club,
ForgeFed, Manyfold, Flohmarkt, Wanderer, Owncast, community catalogues, and
Bonfire-style communities.

Override only endpoints whose acceptable-use policy permits discovery traffic.
Prefer official APIs, public indexes, and operator-approved peers. Leave a list
empty when an ecosystem has no suitable public directory. Do not substitute a
generic domain-name search for native object discovery.

### RSS and Atom sources

RSS and Atom sources are synthetic source actors and must be refreshed by the
RSS worker rather than by ActivityPub actor refresh:

```elixir
config :pleroma, Pleroma.Workers.Cron.RssSourceIngestWorker,
  enabled: true,
  source_limit: 200,
  item_limit: 20,
  source_min_interval_ms: 300_000
```

Keep the minimum interval respectful of publishers. Raise it for large source
sets rather than increasing worker concurrency without bounds.

### Marketplace and service connectors

Marketplace connectors and similar service actors can relay structured objects
between communities. Approve connectors administratively and establish the
required follow relationship before expecting catalogue items to appear.
Review each remote service as infrastructure, not as an ordinary user account.

### FASP services

FASP support provides a standard service-registration path. Enabling the
framework does not mean every requesting service should be trusted. Review the
service identity, capabilities, callback URL, data access, and retention policy
before approval.

## Translation

Run OpenTranslate or another compatible provider, then select it:

```elixir
config :pleroma, Pleroma.Language.Translation,
  provider: Pleroma.Language.Translation.Opentranslate,
  allow_unauthenticated: false,
  allow_remote: true

config :pleroma, Pleroma.Language.Translation.Opentranslate,
  base_url: "http://127.0.0.1:5000",
  api_key: nil
```

Keep the provider on a private network when possible. Translation requests
contain post text. See [Translation](configuration/translation.md) for service
installation and model details.

## Meilisearch

Database search works without an external service. Meilisearch adds a dedicated
index for larger installations:

```elixir
config :pleroma, Pleroma.Search,
  module: Pleroma.Search.Meilisearch

config :pleroma, Pleroma.Search.Meilisearch,
  url: "http://127.0.0.1:7700/",
  private_key: "replace-with-a-private-key"
```

Set up and populate the indexes only after the service is reachable:

```sh
MIX_ENV=prod mix pleroma.search.meilisearch create
MIX_ENV=prod mix pleroma.search.meilisearch index
```

See [External search](configuration/search.md) for maintenance commands.

## Web push and VAPID

Generate a keypair once:

```sh
MIX_ENV=prod mix web_push.gen.keypair
```

Configure all three values. Partial VAPID configuration remains disabled:

```elixir
config :web_push_encryption, :vapid_details,
  subject: "mailto:admin@example.com",
  public_key: "generated-public-key",
  private_key: "generated-private-key"
```

The subject should identify a monitored operator contact. Keep the private key
secret and stable so existing browser subscriptions remain usable.

## Operational verification

After enabling a feature:

1. Restart the backend and confirm that startup contains no missing-secret,
   invalid-module, or stale ConfigDB warnings.
2. Load the public instance metadata and confirm the expected feature is
   advertised.
3. Exercise its public discovery endpoint without authentication.
4. Exercise its authenticated workflow with a disposable test account.
5. Confirm WebSocket updates arrive without polling or repeated reconnects.
6. Inspect Oban for repeated retries, uniqueness conflicts, and terminal jobs.
7. Inspect PostgreSQL growth and query latency before raising any ingest limit.
8. Re-run the relevant smoke harness from
   [Federation testing](../FEDERATION_TESTING.md).

Do not hide recurring remote errors by lowering their log level until the
payload, protocol assumption, retry policy, and terminal classification have
been reviewed. Federation noise is often the first evidence of a compatibility
gap.

## Common setup mistakes

| Symptom | Likely cause |
| --- | --- |
| Feature remains disabled | ConfigDB overrides the file setting |
| Bluesky reads work but writes do not | The local user has not completed account linking |
| Nostr identities change after restart | The bridge secret was missing or replaced |
| Nostr connects locally but not publicly | The reverse proxy did not pass the WebSocket upgrade |
| Onion fetches use clearnet or fail open | A global proxy was used instead of `Pleroma.HTTP.Onion` |
| Onion address is missing | Only outbound Tor support was configured |
| Worlds pages are empty | No local actor, followed source, imported URL, or approved catalogue has seeded data |
| RSS sources stop updating | The RSS worker is disabled or the source was incorrectly treated as ActivityPub |
| Translation button is absent | No provider is selected or the post language metadata does not make it eligible |
| Push warning appears at boot | VAPID subject, public key, or private key is missing |
| New UI is absent | The backend and frontend releases are not aligned |
