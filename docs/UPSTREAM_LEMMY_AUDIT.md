# Upstream Lemmy Audit

This document records the focused review of recent Lemmy changes for lessons
that can be adapted to Unfathomably without importing Lemmy-specific Rust,
Diesel, API, or frontend architecture.

## Audit window

- Official repository: `https://github.com/LemmyNet/lemmy`
- Branch: `main`
- Previous Unfathomably Lemmy cursor: none found
- Conservative base: `5523e823e099799bf55cb29c38df784635e66bd8`
  from 2026-06-16
- Reviewed head: `fd09f815a076bf24858d9d0f51d7f749fb799b3b`
  from 2026-08-05
- Commits reviewed: 26, all non-merge commits

June 18, 2026 was requested as the approximate boundary. The nearest earlier
commit was used as the base so the June 18 boundary could not omit work.

## Adapted now

### Canonical remote actor redirects

Lemmy commit `f8a970035a0c87663d9fd122d22d91332fc22050` taught its
ActivityPub person and community routes to recognize qualified remote names.
Unfathomably already refused to render cached remote actors as local actors,
but returned 404 for those aliases. It now redirects a known remote actor alias
to the actor's authoritative `ap_id` after requiring an HTTP(S) URI with a
host. Local actor rendering is unchanged.

This is useful when software constructs a qualified actor route from a handle:
the peer reaches the authoritative actor instead of treating the alias as a
missing actor or caching a locally republished copy.

## Already covered

### Activity object identifiers and embedded activities

Commits `933ef0cc3a7c627fd3fd1ae9a9ee5767b5cb4487`,
`7068d783443bfc7a23313287732c5ae26d1b4b37`, and
`9443712581fffaa36dc022d57382f05cf13b01aa` generalized Lemmy's handlers to
accept an activity by identifier or as an embedded object. Unfathomably's
generic ActivityPub pipeline already accepts maps and identifiers, resolves
referenced objects when necessary, and retains authorization checks after
dereferencing.

### Microblog posts addressed to communities

Commits `845d155a334d1aafd6247195b415b6b12eebfc58` and
`ed084caab2cd54f80ae906cf34d1ed62036ed1d6` distinguish Mitra top-level
`Create/Note` posts from comments and private messages. Unfathomably does not
use Lemmy's type-based post/comment/private-message wrapper. Its group audience
and parent-context logic already classifies a Note from its addressing and
reply relationship, including group-unaware microblog clients.

### Deleted and removed content

Commit `f5e9101a4a214d3ad53f037ad73dad093a0c66e0` prevents a combined
post/comment view from leaking removed bodies. Unfathomably's object deletion,
Tombstone, visibility, and moderation paths already exclude deleted content
from ordinary status and world-feed rendering. There is no parallel combined
view that bypasses those checks.

### Long-running destructive work

Commit `3d8a985c1a548d36038d5d658fe94bac574380f5` moves bulk removal after
bans, purges, and account deletion out of request transactions. Unfathomably
already uses dedicated Oban deletion work with bounded worker timeouts. Keeping
that work durable is preferable to Lemmy's detached in-process tasks.

### Media proxy response names

Commit `3ba7821972cac18aa540312b94a86d821803de8f` adds proxy
`Content-Disposition` names and handles nested Lemmy proxy URLs. Unfathomably
already preserves and safely quotes upstream disposition names, supplies a
safe fallback name, strips stale response lengths, and validates signed media
paths. Replacing that generalized reverse-proxy handling with Lemmy-specific
proxy-path recognition would reduce compatibility.

### Community management context

Commits `5d62319c75c7560eedae5bdd026789156972dc98` and
`99afdc01e22528948dae223cecb540d06f06ce60` expose community moderators
with posts and let authorized moderators list followers. Unfathomably's group
API already returns moderator and member counts and provides owner/moderator
member-management endpoints with role checks.

### Dead-community activity counts

Commit `fb2d667f30451ff61b9fe165b551223a4ff96921` resets cached Lemmy
community activity counters when inactive communities disappear from an
aggregate query. Unfathomably does not persist an equivalent community
activity aggregate. Its group timelines query visible activities and its
persisted group counters describe followers and moderators, so there is no
stale activity counter to reset.

## Not transplanted

- OAuth email and provider corrections apply to Lemmy's OAuth model rather
  than Unfathomably's OAuth application and authentication flows.
- Lemmy settings-backup validation covers a profile/settings import format
  that Unfathomably does not expose.
- Report `conclusion` storage would require an intentional moderation API and
  schema design rather than copying Lemmy's report-table migration.
- The jemalloc switch, Rust formatting, typo checks, README changes, and
  duplicate Rust helper cleanup do not translate to the BE or FE codebases.
- The Lemmy `1.0.0-beta.1` version commit contains no portable behavior by
  itself.

## Next cursor

Resume the next Lemmy review after:

`fd09f815a076bf24858d9d0f51d7f749fb799b3b`

<!-- end of docs/UPSTREAM_LEMMY_AUDIT.md -->
