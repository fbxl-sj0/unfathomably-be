<!--
Unfathomably BE

File: FINAL_FEP_AUDIT_2026-08-12.md
Purpose: Compare finalized Fediverse Enhancement Proposals with the server.
Responsibilities: Record coverage, concrete defects, and implementation order.
This file intentionally does not claim support for draft or withdrawn FEPs.
-->

# Finalized FEP audit, 2026-08-12

This audit uses the [official finalized FEP index](https://fediverse.codeberg.page/fep/final/).
It separates working interoperability from fields that are merely preserved.

| FEP | Current status | Finding |
| --- | --- | --- |
| [FEP-8fcf](https://fediverse.codeberg.page/fep/fep/8fcf/) | Not implemented | Useful for repairing follower drift, but the digest and partial-collection protocol is safe only when its same-authority assumptions hold. |
| [FEP-f1d5](https://fediverse.codeberg.page/fep/fep/f1d5/) | Implemented | NodeInfo discovery publishes 2.1 and 2.0 documents. |
| [FEP-400e](https://fediverse.codeberg.page/fep/fep/400e/) | Partial | Specialized objects preserve target collection metadata, but there is no generic owner-authorized Add, Delete, and Move collection workflow. |
| [FEP-e232](https://fediverse.codeberg.page/fep/fep/e232/) | Partial | Incoming qualified Object Links and quote links are understood. General outgoing link tags are not yet a serialization invariant. |
| [FEP-1b12](https://fediverse.codeberg.page/fep/fep/1b12/) | Implemented | Group follows, audience association, Announce forwarding, moderator collections, and moderation activities are implemented and covered by the platform smoke matrix. |
| [FEP-521a](https://fediverse.codeberg.page/fep/fep/521a/) | Partial | Remote Ed25519 Multikey and JWK keys are accepted. Local actors continue to advertise RSA PEM keys and do not yet publish assertionMethod Multikey entries. |
| [FEP-67ff](https://fediverse.codeberg.page/fep/fep/67ff/) | Implemented in this audit | The repository now publishes a root FEDERATION.md capability document. |
| [FEP-d556](https://fediverse.codeberg.page/fep/fep/d556/) | Implemented in this audit | WebFinger now resolves the exact local server prefix to the service actor. |
| [FEP-ae0c](https://fediverse.codeberg.page/fep/fep/ae0c/) | Implemented | LitePub relay flows exist. This audit fixed ActivityPub actor requests that were incorrectly intercepted by the Nostr relay sharing /relay. |
| [FEP-0151](https://fediverse.codeberg.page/fep/fep/0151/) | Implemented with one follow-up | NodeInfo 2.1 metadata is published. One outbound compatibility branch still identifies Ibis by NodeInfo software name and should move to explicit or learned capability negotiation. |

## Repairs completed by this audit

1. Added FEP-d556 server-prefix WebFinger discovery with strict origin, port,
   path, query, and fragment validation.
2. Made the shared `/relay` endpoint route ActivityPub media types to the
   ActivityPub relay actor while preserving Nostr WebSocket and NIP-11 traffic.
3. Added a root FEP-67ff capability manifest that distinguishes full, partial,
   and absent support.

## Recommended implementation order

### 1. Make FEP-e232 output structural

Emit qualified Object Link tags whenever local content intentionally links an
ActivityPub object. Keep compatibility quote fields alongside the tag, but do
not require an operator to enable an MRF policy for standards-shaped output.

### 2. Replace software-name capability inference

FEP-0151 says software names and versions are opaque and must not select
protocol behavior. The Ibis Delete compatibility branch should use an actor
capability, an explicit per-domain override, or a cached fallback learned from
an actual delivery response. UI platform labels may remain informational, but
must not silently alter federation semantics.

### 3. Add a local FEP-521a key lifecycle

Generate a dedicated Ed25519 object-signing key, publish it as a Multikey in
`assertionMethod`, retain bounded key history for rotation, and keep the RSA
HTTP-signature key during migration. Publishing an unused Multikey would be
misleading, so schema output should follow actual signing support.

### 4. Prototype FEP-8fcf behind a deployment gate

Start with audit-only follower-drift reporting. Require HTTPS, exact
same-authority collection URLs, signed synchronization headers, bounded page
fetches, and conservative reconciliation. Enable mutation only after the dry
run demonstrates that remote collection behavior satisfies the FEP's security
assumptions.

### 5. Build FEP-400e only around a concrete workflow

Publicly appendable collections need owner authorization, Add verification,
moderation, deletion authority, and move handling. A generic database primitive
without a user-facing workflow would add attack surface without improving
interoperability. Offers, libraries, and project collections are plausible
first products because Unfathomably already understands their object shapes.

## Leading-edge conclusion

Unfathomably implements six of the ten finalized technical FEPs, partially
implements three, and deliberately defers one whose deployment assumptions are
not universally safe. The highest-value next work is not adding isolated JSON
fields. It is making Object Links structural, replacing product-name guesses
with capability negotiation, and introducing a real rotatable Ed25519 signing
identity.

<!-- end of FINAL_FEP_AUDIT_2026-08-12.md -->
