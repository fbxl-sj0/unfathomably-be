<!--
Unfathomably BE

File: FEDERATION.md
Purpose: Publish the protocols and finalized FEPs supported by version 3.5.
Responsibilities: Give peer implementers a concise capability manifest.
This file intentionally does not replace the detailed test matrix.
-->

# Unfathomably federation support

Unfathomably is an ActivityPub server derived from Pleroma and Rebased. It also
provides bounded interoperability with Nostr, AT Protocol, and diaspora*. This
document describes the version 3.5 implementation. Runtime features can be
further restricted by instance configuration and moderation policy.

The detailed compatibility matrix, stock-peer limitations, and smoke-test
instructions are in [FEDERATION_TESTING.md](FEDERATION_TESTING.md).

## Core protocols

- ActivityPub server-to-server and client-to-server federation
- ActivityStreams 2.0 JSON-LD
- WebFinger, including server-level actor discovery
- HTTP Signatures, including legacy Cavage signatures and RFC 9421 signatures
- NodeInfo 2.1 and 2.0
- LitePub-compatible ActivityPub relays

## Finalized FEP support

### Implemented

- FEP-f1d5: NodeInfo discovery and documents
- FEP-0151: NodeInfo 2.1 publishing
- FEP-1b12: group federation
- FEP-67ff: this federation capability document
- FEP-d556: server-level actor discovery using WebFinger
- FEP-ae0c: LitePub-compatible relay participation
- FEP-e232: outgoing quoted objects carry a structural ActivityStreams `Link`
  tag with the canonical ActivityPub media type
- FEP-521a: local actors publish their existing RSA HTTP-signature key as an
  `assertionMethod` `Multikey` using the registered `rsa-pub` multicodec
- FEP-400e: local actors expose an appendable wall whose contributed objects
  require an owner-matching target and a signed `Add` confirmation before they
  become visible

### Deployment-gated

- FEP-8fcf: follower collection synchronization is implemented but disabled by
  default. It requires an operator-configured managed origin that exactly
  matches the endpoint origin. Eligible deployments use signed synchronization
  headers, requester-origin partial collections, and verified collection
  digests.

The deployment constraint and completed engineering work are documented in
[the finalized FEP gap report](docs/FINALIZED_FEP_GAPS_2026-08-12.md). The
[earlier audit](docs/FINAL_FEP_AUDIT_2026-08-12.md) records the state before
those gaps were closed.

## Protocol bridges

### Nostr

Nostr support is optional and disabled by default. When configured, the server
can operate its local relay, use administrator-approved external relays, map
profiles and public conversations, and preserve locally relevant reactions,
reposts, deletes, lists, communities, and selected Nostr extensions. Private
messages use the NIP-17 path. The bridge does not crawl an unrestricted relay
graph.

### AT Protocol and Bluesky

AT Protocol support uses selective storage. It resolves explicitly opened
Bluesky posts, follows linked or locally followed identities, hydrates directly
relevant threads, and publishes supported actions for linked local accounts. It
does not consume the firehose, run a relay or AppView, or mirror repositories.

### diaspora*

The diaspora* bridge verifies native envelopes and maps locally relevant public
statuses, comments, likes, reshares, retractions, profiles, and contact changes.
Public traffic must be relevant to a local relationship or conversation.
Private delivery is limited to representable contact changes; private aspect
messages are not imported.

## Auxiliary discovery

An instance can accept signed FASP registrations and use administrator-approved
providers for bounded account search. Unapproved providers are not queried, and
FASP results do not bypass ordinary account validation or moderation.

## Safety and compatibility rules

- Discovery screens do not trigger an unrestricted crawl of remote networks.
- Imported records pass through the canonical local validation, visibility,
  and moderation paths.
- A bridge declines traffic whose privacy or audience cannot be represented
  safely.
- Peer-specific limitations are recorded as unsupported or untested in the
  smoke matrix instead of being presented as successful interoperability.

<!-- end of FEDERATION.md -->
