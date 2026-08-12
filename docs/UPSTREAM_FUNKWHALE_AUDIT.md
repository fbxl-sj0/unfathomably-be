# Upstream Funkwhale audit

This ledger records the portable lessons reviewed from Funkwhale's official
`develop` branch. It exists so later audits can resume from an exact commit
instead of guessing from changelog dates.

## Audit window

- Official repository: <https://dev.funkwhale.audio/funkwhale/funkwhale.git>
- Conservative starting cursor: [`ee2ba1e5f83707182cb5b4c29b8af7b0891b49ef`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/ee2ba1e5f83707182cb5b4c29b8af7b0891b49ef), dated 2026-07-13
- Reviewed through: [`aff3dc5f27ee5aff9e4d6b4cecf7b918e87eb59a`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/aff3dc5f27ee5aff9e4d6b4cecf7b918e87eb59a), dated 2026-08-05
- Scope: 55 non-merge commits, 238 changed files, 9,796 insertions, and 6,030 deletions

No earlier durable Funkwhale cursor was present in the source tree. The audit
therefore starts slightly before the comparable mid-July Mastodon review rather
than risk leaving a gap.

## Adapted now

### Stable received-audio catalogues

Funkwhale fixed duplicate catalogue rows caused by joins and filters in
[`e6084f30`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/e6084f30811f81a9981ab05f69c276af6f8f2ab2).
Unfathomably's equivalent risk came from several legacy or idless `Create`
envelopes resolving to one canonical Audio object. Received-audio discovery now
selects one newest local envelope per object and performs a one-item look-ahead
so `has_more` and `next_offset` are reliable.

### Preserve remote podcast taxonomy

Funkwhale's remote-podcast user-testing fixes in
[`8cb0b258`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/8cb0b2582793492845e1918fa7eba889eb91a6de)
retain additional iTunes categories as ordinary tags instead of silently
discarding them. Unfathomably now merges bounded tags and taxonomy from the
Audio object, nested track, and nested album, including genre, category, and
content-category fields.

## Already covered in Unfathomably

- Funkwhale's upload-privacy filtering in
  [`c24461a2`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/c24461a2fb12250b4427b80f2aab1ec4929fccf7)
  maps to Unfathomably's public-recipient and native-feed eligibility checks.
  Private audio is not exposed by Worlds discovery.
- The ownership-safe deletion changes in
  [`4f7e1378`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/4f7e1378f92cb72fab035fe0e077d05644f04dbf)
  and empty-upload handling in
  [`94a7a46b`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/94a7a46b2fdf13383245639d5f865dc4d5d62cf9)
  concern Funkwhale's shared Track/upload model. Unfathomably authorizes
  deletion against the ActivityPub object and actor and does not delete a
  shared canonical track row through a per-upload endpoint.
- RSS channels being forced public in
  [`fe450f23`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/fe450f23f39c074b535e73203136abb2b6b2266a)
  matches synthetic RSS source behavior here. RSS actors are refreshed by the
  RSS ingest worker rather than the ActivityPub actor refresher, and imported
  entries are published into the normal public source workflow.
- Empty artist-credit protection from
  [`184a4a1c`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/184a4a1ceb51c982a105dfe6f08166f3167ee1bc)
  is already covered by shape-tolerant audio normalization.
- Funkwhale's in-flight data-store fixes in
  [`25c84cb4`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/25c84cb4a1354eccf6c4a782c0984d29ae5bd890)
  and
  [`8f406417`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/8f406417386d80b484ca2acc9c4cf9830f8b46b6)
  address a hand-built Pinia cache. Unfathomably FE's discovery hooks use React
  Query, which already shares in-flight requests by stable query key and drops
  observers when components unmount.
- Funkwhale's selectable data-export work in
  [`200213ef`](https://dev.funkwhale.audio/funkwhale/funkwhale/-/commit/200213ef11812409512328328d087307cba74c06)
  overlaps Unfathomably's existing account backup and ActivityPub archive
  workflow.

## Reviewed but not transplanted

- The graph API and denormalized music tables are optimizations for
  Funkwhale's relational artist, album, track, and upload schema. Unfathomably
  stores remote catalogue objects as ActivityStreams JSON and uses bounded
  PostgreSQL expression indexes, so copying that design would add a second
  source of truth.
- Funkwhale's customizable iframe player, MilkDrop visualizer, onboarding,
  queue, and layout changes are specific to its dedicated streaming client.
  Unfathomably keeps audio inside ordinary status cards and the shared floating
  media player so Worlds retain the site's familiar social workflow.
- Python, Django, Redis, Alpine, and frontend build dependency commits do not
  transfer to the Elixir/React dependency graph.
- Query-prefetch changes are useful reminders to keep catalogue reads bounded,
  but their ORM paths have no direct Ecto equivalent. Existing Worlds queries
  select only the Activity and Object rows required for a page.

## Next audit cursor

The next Funkwhale audit should begin after
`aff3dc5f27ee5aff9e4d6b4cecf7b918e87eb59a` on the official `develop` branch.

<!-- end of docs/UPSTREAM_FUNKWHALE_AUDIT.md -->
