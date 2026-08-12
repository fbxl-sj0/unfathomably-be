# Finalized FEP gap implementation, 2026-08-12

## Implemented

- FEP-e232: outbound quoted objects always carry a structural ActivityStreams
  `Link` tag with the canonical ActivityPub media type.
- FEP-521a: local actors publish their existing RSA HTTP-signature public key
  as an `assertionMethod` `Multikey` using the registered `rsa-pub` multicodec.
- FEP-8fcf: eligible deployments send signed collection synchronization
  headers, serve requester-origin partial follower collections, verify fetched
  digests, accept matching pending relationships, and remove stale accepted
  relationships.
- FEP-400e: local actors expose an appendable wall whose contributed objects
  require a typed owner-matching target and are visible only after the owner
  emits a signed `Add` confirmation.

## FEP-8fcf deployment gate

Follower synchronization is disabled by default. An operator must set both:

```elixir
config :pleroma, Pleroma.Web.ActivityPub.FollowersSynchronization,
  enabled: true,
  managed_origin: "https://social.example"
```

The configured origin must exactly match the endpoint origin. The operator is
responsible for verifying that all managed actor IDs, inboxes, and shared
inboxes use that authority and that the authority does not host a separate
ActivityPub implementation.

## Software-name behavior

FEP-0151 makes NodeInfo software names opaque identifiers, not capability
advertisements. Unfathomably does not add new wire behavior based on those
names. The existing Ibis Delete-object compatibility transform remains as a
documented exception because Ibis does not currently expose an equivalent
actor or protocol capability and removing it would knowingly break delivery.
It should be replaced only when a reliable advertised or safely learned
capability is available.

Discovery and frontend presentation hints may still use software metadata.
Those hints do not alter ActivityPub payloads or validation rules.

<!-- end of FINALIZED_FEP_GAPS_2026-08-12.md -->
