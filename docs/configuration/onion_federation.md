# Tor Onion Federation

Unfathomably can fetch ActivityPub resources from valid Tor v3 onion services
without routing ordinary HTTP traffic through Tor. It can also be exposed
through a separate onion address. These are independent configurations.

Neither configuration makes the host a Tor exit node or a public Tor relay.

## Outbound onion fetching

Run Tor as a client on the same host as the backend, or on a private host whose
SOCKS port is reachable only by the backend.

### Install Tor

On Debian or Ubuntu:

```sh
apt update
apt install tor
```

### Configure a client-only listener

Use a dedicated Tor configuration or add equivalent settings to the packaged
client instance:

```text
ClientOnly 1
SocksPort 127.0.0.1:9050 OnionTrafficOnly
SocksPolicy accept 127.0.0.1
SocksPolicy reject *
ORPort 0
DirPort 0
ControlPort 0
ExitRelay 0
ExitPolicy reject *:*
SafeLogging 1
Log notice syslog
```

`OnionTrafficOnly` ensures this listener cannot become a general clearnet
proxy. The reject-all exit policy and disabled OR/Dir ports prevent relay and
exit operation. Some packaged Tor services maintain a local Unix control
socket; that is not a network control port.

Validate and restart the packaged client:

```sh
tor --verify-config -f /etc/tor/torrc
systemctl restart tor@default.service
```

Confirm that Tor reaches 100 percent bootstrap and that the SOCKS listener is
bound only to loopback.

### Enable the dedicated backend adapter

```elixir
config :pleroma, Pleroma.HTTP.Onion,
  enabled: true,
  socks_port: 9050,
  connect_timeout: 15_000,
  recv_timeout: 30_000
```

Do not set the general `:http, :proxy_url` option to the Tor SOCKS listener.
The dedicated adapter validates Tor v3 hostnames and sends only valid
`.onion` requests through Tor. Ordinary federation, media, uploads, and
remote APIs continue to use their normal pools.

Restart the backend after enabling the adapter.

### Verify fail-closed behavior

Test a known official onion service through the loopback SOCKS listener:

```sh
curl --socks5-hostname 127.0.0.1:9050 \
  http://2gzyxa5ihm7nsggfxnu52ffnz4z2d55r3zjkue3sl7p3tqfdqj7m6iid.onion/
```

Then attempt a clearnet URL through the same listener. It should fail because
the listener is onion-only.

Inspect backend logs for malformed onion hostnames, timeouts, and TLS failures.
The backend should reject invalid v3 addresses before connecting and should
return normal error tuples rather than falling back to clearnet DNS.

## Inbound onion entrance

An inbound hidden service lets Tor users open the existing Unfathomably site
through an alternate onion address. ActivityPub IDs, OAuth callback origins,
and canonical links should remain on the configured public HTTPS origin unless
the entire instance is intentionally operated as onion-only.

Run the hidden service on the reverse-proxy host where possible:

```text
HiddenServiceDir /var/lib/tor/unfathomably
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:8099
```

Configure the listener on `127.0.0.1:8099` to proxy to the same backend as the
public virtual host. Preserve the original application host expected by the
backend and pass WebSocket upgrades. Do not expose the loopback listener to the
LAN.

Restart Tor and read the generated address:

```sh
systemctl restart tor@default.service
cat /var/lib/tor/unfathomably/hostname
```

Back up the hidden-service directory securely. Its private key controls the
onion address.

Test the onion entrance with Tor Browser:

1. Load public timelines and local profile pages.
2. Sign in and complete an OAuth redirect.
3. Open a streaming timeline and confirm that WebSockets remain connected.
4. Load local and proxied media.
5. Confirm that canonical links and federated IDs still use the public origin.

Do not disable Content-Security-Policy globally to make an onion entrance work.
Add only the minimum origin allowances required by a deliberately supported
alternate entrance.

## Security boundaries

| Boundary | Expected behavior |
| --- | --- |
| Public SOCKS exposure | None; the listener is loopback or private-host only |
| Tor relay ports | Disabled |
| Exit policy | Reject all |
| Clearnet through onion SOCKS | Rejected |
| Invalid onion hostname | Rejected before connection |
| DNS for onion requests | Resolved by Tor through SOCKS, not local DNS |
| Canonical ActivityPub identity | Remains the configured endpoint URL |
| Hidden-service private key | Root/Tor owned and backed up securely |

For the broader protocol setup sequence, see
[Optional Feature Enablement](../FEATURE_ENABLEMENT.md).

