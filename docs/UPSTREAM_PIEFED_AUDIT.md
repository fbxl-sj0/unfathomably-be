# Upstream PieFed Audit

This document records the focused review of recent PieFed changes for lessons
that can be adapted to Unfathomably without importing PieFed-specific Flask,
SQLAlchemy, Jinja, Celery, plugin, or deployment architecture.

## Audit window

- Official repository: `https://codeberg.org/rimu/pyfedi`
- Branch: `main`
- Previous Unfathomably PieFed cursor: none found
- Conservative base: `b7679b5af4b75c95d9a610173abd547594790fbb`
  from 2026-06-15
- Reviewed head: `7db983686f20cf7ea3946317b540e0cae8270e35`
  from 2026-08-06 in the committer's `+12:00` timezone
- Commits reviewed: 166 total, 145 non-merge commits

June 18, 2026 was requested as the approximate boundary. The nearest earlier
mainline commit was used as the base so the boundary could not omit work. A
Docker side branch merged during the window contains commits authored in May;
those commits are included because they entered `main` after the audit base.

## Adapted now

### Verifiable creator attribution

PieFed commit `a51b1b8af8b5ccf41bb1ff97d7d29dcd0a6ab4d4` implements the
publisher side of draft FEP-2345. Unfathomably now emits a
`fediverse:creator` meta tag for local status pages and advertises the local
WebFinger hostname in each local actor's `attributionDomains` set.

Both halves are required. Emitting only the HTML tag would let a page claim an
unrelated actor, while emitting only the actor property would give link-preview
consumers nothing to discover. Remote status pages do not receive a creator
tag because their actors have not authorized the local instance hostname.

### Untitled PieFed posts

PieFed commit `b9ee6cefc2a21f2fa1b31ea64ec2fe77cad972f5` hides the internal
title `(content in post body)` in PieFed templates. PieFed can also federate
that value in a Page object's `name`, so hiding it in one Unfathomably renderer
would leave other clients and feeds inconsistent.

Unfathomably now removes that exact sentinel during incoming object
normalization. Genuine titles and every other object name remain unchanged.

## Already covered

### Events and locations

Commit `cd214cd0e9db4df19e21e82157cf1c6432b8a249` preserves event
locations in PieFed's API and outbound ActivityPub. Unfathomably already
validates physical and virtual locations, preserves Mobilizon and Gancio event
fields, renders them through Mastodon API event extensions, exposes them in
Worlds discovery, and maps compatible locations through its Nostr event bridge.

### Followers-only visibility

Commit `7e10e92de2cf271088b76a31d725cad67afe08aa` stops treating Hubzilla
microblogs without a title as public by default. Unfathomably derives
visibility from the ActivityStreams Public collection in `to` or `cc`; a post
addressed only to followers remains private regardless of whether `name` is
present.

### Follow direction, delivery, and integrity

Commits `ce4550cc60298810a073a5beb6d3a01351e25745`,
`6825038bc9862f14af71f8bf627449153e3c3b90`,
`1a523486b357e12304e0ce930bec1cc24b7ca356`,
`da231c4f7d505e37919493761db34325c4058b8f`, and
`ad54f663da93b7e69b4d2422fad5350276c0e4a1` correct PieFed's
direction flag, relationship schema, private-community fanout, and recipient
selection. Unfathomably models Follow activities and follow requests directly,
uses separate follower and following queries, applies database uniqueness, and
fans group activities out through accepted relationships rather than a shared
inward/outward row flag.

### Block filtering

Commits `c90baddbbca32d0a76b104dce8caa9b65e08a576` and
`8a68c76d0b31aabbeec4c2c01a0b231ccfc28244` add blocked-user and
blocked-instance filters to PieFed API lists. Unfathomably already applies its
shared visibility and relationship filters to timelines, search,
notifications, streaming, groups, sources, and status contexts.

### Feed query performance

Commits `918731bb80ee739d4b9963ce64acbbfd3f6afb41`,
`191057799b9c53ab8ee49193dedc2d0c2ac9928b`, and
`27621d2219dda1b8133dd99f1c66814a282f2e99` tighten PieFed feed
membership and ordering queries. Unfathomably already uses bounded keyset
pagination, indexed activity visibility, dedicated discovery queries, and
separate social, group, source, and Worlds surfaces rather than PieFed's post
table unions.

### API media types and response compression

Commit `15bad509198f7829828fbd3d802c2ce62a6ab243` accepts video through
PieFed's legacy image-upload API. Unfathomably's Mastodon-compatible media API
already accepts configured image, audio, and video MIME families without
mislabeling video as an image. Commit
`9ed4fb5c69996e42484c2aed7e8b756cc88347c2` enables response compression,
which is already provided by the Phoenix endpoint and deployment proxy.

## Not transplanted

PieFed commit `d8a26a555f4f651ab254c0fceea0cf1c0e10ec35` infers a requesting
instance from the User-Agent when deciding whether an author block should deny
an ActivityPub object fetch. That signal is spoofable. Unfathomably will not
turn it into an authorization boundary; any future per-author fetch denial must
use the actor established by a verified HTTP signature.

PieFed commit `839fdcdd684f63196e374108741027a90ae35330` changes its
`py-svg-hush` wrapper to cap SVG size, strip declarations, and fail closed when
sanitization fails. The fail-closed lesson is sound, but copying its regular
expressions without the same sanitizer would create a false security boundary.
Unfathomably already applies upload limits and disables XML entity expansion;
SVG upload and serving policy should remain an explicit media-security change,
not an incidental port in this federation audit.

Anoobis proof-of-work, reputation calculations, vote quotas, onboarding,
plugin hooks, direct Lemmy database import, Docker and cron work, Python
compatibility, translations, CSS refactors, typography, and template-only
accessibility changes do not map to Unfathomably's BE or FE architecture.

## Next cursor

Resume the next PieFed review after:

`7db983686f20cf7ea3946317b540e0cae8270e35`

<!-- end of docs/UPSTREAM_PIEFED_AUDIT.md -->
