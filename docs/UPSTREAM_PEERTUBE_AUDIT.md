# Upstream PeerTube audit

This ledger records portable lessons reviewed from PeerTube's official
`develop` branch. It gives future audits an exact cursor and separates
ActivityPub interoperability work from PeerTube-specific streaming machinery.

## Audit window

- Official repository: <https://github.com/Chocobozzz/PeerTube>
- Starting cursor: [`b1ca14a8bad71e09b7a24de354fad5b4f10d0ba1`](https://github.com/Chocobozzz/PeerTube/commit/b1ca14a8bad71e09b7a24de354fad5b4f10d0ba1), dated 2026-06-17
- Reviewed through: [`ea9132115048e6f4f65a8ba552f790dad2dd21c5`](https://github.com/Chocobozzz/PeerTube/commit/ea9132115048e6f4f65a8ba552f790dad2dd21c5), dated 2026-08-05
- Scope: 293 commits, including 282 non-merge commits

No earlier PeerTube-specific audit cursor was present in either Unfathomably
source tree. The review therefore begins immediately before June 18, 2026.

## Adapted now

### Bind unknown Updates to their actor origin

PeerTube began requiring signed Video Updates to remain on the signing actor's
host in
[`63d487d2`](https://github.com/Chocobozzz/PeerTube/commit/63d487d2a4a2a0e36af8c0ccb888cd23725bf7f2)
and broadened the protection in
[`e46fb4d8`](https://github.com/Chocobozzz/PeerTube/commit/e46fb4d864ad9f979d58f31a6d4c08d5931e695c).
Unfathomably already checks stored ownership for known objects. It now also
requires a previously unknown Update object's canonical ID to share the exact
host of the authorized actor before accepting the short initial-import path.

### Validate embedded public-key ownership

The same PeerTube hardening rejects an actor whose legacy `publicKey.owner`
does not equal the actor ID. Unfathomably now applies that check while retaining
compatibility with actors that omit the legacy owner field or publish newer
Multikey and JWK verification methods.

### Hide expired scheduled-video notices

PeerTube stopped presenting past live-schedule dates as current state in
[`b221e805`](https://github.com/Chocobozzz/PeerTube/commit/b221e8058bc804279d5fa1434d175f39cf8c62f5).
The Worlds video browser now displays a schedule only when it parses as a future
date.

## Already covered in Unfathomably

- Video federation already runs through bounded Oban publisher jobs, matching
  the request-path isolation introduced by
  [`e55325c6`](https://github.com/Chocobozzz/PeerTube/commit/e55325c62ed16541fe42ad5d0cd715e6597d61b6).
- Known-object Updates already require the stored actor, remote Create retries
  are actor-bound and conflict-safe, and fetched canonical identities are
  origin-contained. The new checks close only the unknown-Update and explicit
  public-key-owner edges.
- ActivityPub `View`, `Read`, and comparable receipt traffic is acknowledged
  without turning a general social server into an authoritative video-analytics
  service. PeerTube's bounded viewer counters and origin-only download totals
  therefore do not map to a local counter update.
- Remote Video cards already preserve channel, thumbnail, duration, language,
  licence, comments policy, download policy, processing state, and embed
  availability. Restricted embeds are not presented as playable embeds.
- Generic ActivityPub Update delivery already uses the object's current
  audience, while undelivered obsolete jobs are cancelled after authorized
  deletes and reaction undos. PeerTube's storage-privacy transitions have no
  equivalent local video-file move.
- Native playlist objects are inert received catalogue data. Unfathomably does
  not expose PeerTube's local playlist-element mutation endpoint, so the
  cross-playlist element bug fixed by
  [`39018a16`](https://github.com/Chocobozzz/PeerTube/commit/39018a16cf9934402bca35404945388b340e7bac)
  is not reachable here.
- Upload metadata extraction, image processing, media proxying, SVG/XML
  hardening, duplicate insert handling, worker uniqueness, and janitor cleanup
  already cover the portable classes behind PeerTube's thumbnail, caption,
  SVG, and job-race fixes.

## Reviewed but not transplanted

- HLS, WebRTC P2P, transcoding runners, live-segment stores, torrent metadata,
  stream keys, object-storage ACL moves, and video analytics belong to
  PeerTube's streaming server role.
- PeerTube's Angular client, standalone player, embed application, Vines UI,
  storyboard, poster, bezel, and player-lifecycle changes do not fit Soapbox's
  shared status-card and floating-player architecture.
- Channel synchronization, video imports, video studio, local captions,
  ownership transfer, and playlist editing require PeerTube's relational video
  library. Unfathomably deliberately keeps the remote ActivityStreams object as
  its source of truth.
- Sitemap timestamps, plugin APIs, administration dashboards, OAuth internals,
  translation updates, and PeerTube dependency migrations do not provide a
  direct change for the Elixir/React stack.

## Next audit cursor

The next PeerTube audit should begin after
`ea9132115048e6f4f65a8ba552f790dad2dd21c5` on the official `develop` branch.

<!-- end of docs/UPSTREAM_PEERTUBE_AUDIT.md -->
