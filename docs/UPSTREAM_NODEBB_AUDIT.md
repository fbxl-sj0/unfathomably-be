<!--
  Unfathomably backend
  File: docs/UPSTREAM_NODEBB_AUDIT.md
  Purpose: Record transferable NodeBB federation lessons and their disposition.
  This file does not claim source compatibility with NodeBB.
-->

# NodeBB federation audit

## Scope

This audit reviewed the official NodeBB repository from the conservative base
`89abdca1794647cd716fd7999c7e0403fb2b286d` dated December 31, 2025 through
commit `8cdf3cdc670fea544bf8c08f2cf7e0e44b184c66` dated August 5, 2026. The
screen covered 2,131 reachable commits, including 1,687 first-parent commits.
No older NodeBB audit cursor was present, so January 1 is the baseline for
future incremental reviews.

NodeBB and Unfathomably have different data models. Changes below are adapted
at the ActivityPub behavior boundary rather than copied mechanically.

## Implemented lessons

- `92f3b2bd4a543be8083acb68447ff7aa126c7b19`: retain a late category
  `Announce` when its embedded `Create` was already cached. Unfathomably now
  materializes the Group wrapper only when it adds missing group association,
  and reconciles that assertion onto the cached object and existing Create
  envelopes without changing authorship or widening non-public content.
- `57e65d08b4a73901ef9a27e4ec5238eb5f4f6da7`: distinguish followed remote
  communities during pruning. Unfollowed group history keeps the normal
  183-day horizon; followed group history receives a finite 730-day horizon.
- `5b9b17449e550a5daf3570bf7bf72279f266cf4a` and
  `457a9702f193e7e32736d11eb802d8caeb6b9932`: support Unicode WebFinger
  usernames and avoid unsafe domain interpolation. Outgoing ordinary handles
  and explicit `acct:` subjects now share one resource-construction and
  encoding boundary.

## Already covered

- `f93507a6404ce0e32e6e7befb47ef3a1f56bbac1`: direct Creates require the
  activity actor to match the object's actor or attribution; unknown Updates
  additionally keep their object identifier on the signing actor's origin.
- `6067a49f06fc08de0ad427788dc1dc2f3a6a00bb` and
  `590ac686cfc325255901ac73e99e9c6a8784279e`: HTTP digest verification already
  uses the captured raw request body and checks a supplied Digest header.
- `97e1c6b60f024377f4d8c22728e1e3b987152aca`: remote object fetchers already
  require a decoded JSON object rather than accepting arbitrary JSON values.
- `3a0797a80670bb06dca67e77769cb9df8be08dca`: collection pagination already
  emits `partOf` on pages and uses bounded keyset pagination.
- `f875e918`, `90461e005`, and `459970382`: duplicate reactions, deletes, and
  undo operations already use idempotent existing-object paths.
- `7d416fc`: redirects remain bounded and every destination passes the existing
  remote-fetch containment and address-safety checks.
- `c4b9d03` and `6fcc344`: inbox routing and signature enforcement are anchored
  in Phoenix routes and the inbox guard rather than a bypass regular expression.
- `2518e71834f138f7bf4b816229c6cd3c7da55678`: backend-rendered remote
  profiles and statuses already receive `noindex, noarchive` through the
  metadata restriction provider while remaining discoverable inside Worlds.

## Not transplanted

- NodeBB's forum-specific ActivityPub analytics tables and administrative queue
  UI do not map directly to Oban. Unfathomably retains bounded jobs and janitor
  diagnostics instead of adding a second federation job store.
- NodeBB-specific FEP presentation and category permission changes were not
  applied where Unfathomably already exposes native Group and moderator
  collections with different authorization rules.

## Next cursor

Resume after `8cdf3cdc670fea544bf8c08f2cf7e0e44b184c66`.

<!-- end of docs/UPSTREAM_NODEBB_AUDIT.md -->
