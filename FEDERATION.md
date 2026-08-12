<!--
Unfathomably BE

File: FEDERATION.md
Purpose: Publish federation protocols and finalized FEP support.
Responsibilities: Give peer implementers a concise capability manifest.
This file intentionally does not replace the detailed test matrix.
-->

# Unfathomably federation support

Unfathomably is an ActivityPub server derived from Pleroma and Rebased. It
also provides bounded interoperability with Nostr, AT Protocol, and Diaspora.

The detailed live compatibility matrix and smoke-test instructions are in
[FEDERATION_TESTING.md](FEDERATION_TESTING.md).

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

### Partially implemented

- FEP-e232: incoming Object Link tags are understood; outgoing quote links can
  be emitted through the quote-link MRF policy
- FEP-521a: incoming Ed25519 Multikey and JWK actor keys are supported; local
  actors still publish their established RSA HTTP-signature key
- FEP-400e: target collection metadata is preserved and used by specialized
  group workflows; generic publicly appendable collections are not exposed

### Not implemented

- FEP-8fcf: followers collection synchronization. Its authority and digest
  assumptions require a deployment-gated implementation rather than a global
  compatibility default.

The latest finalized-FEP engineering audit is in
[docs/FINAL_FEP_AUDIT_2026-08-12.md](docs/FINAL_FEP_AUDIT_2026-08-12.md).

<!-- end of FEDERATION.md -->
