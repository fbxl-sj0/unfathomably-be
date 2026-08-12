<!--
  Unfathomably upstream review
  File: UPSTREAM_AKKOMA_AUDIT.md

  Purpose:
    Record the 2026 Akkoma commit review and the lessons adapted to
    Unfathomably's Pleroma-derived but independently extended backend.

  This file intentionally does not treat shared ancestry as proof that a patch
  can be copied without checking Unfathomably's federation and data model.
-->

# Akkoma upstream audit

## Review boundary

- Upstream: `AkkomaGang/akkoma`, official `develop` branch.
- Base: `c971f297a57bad44f2ade02a5fdb8ad15a068a3c`, committed 2025-12-29.
- Head: `6bf627a51411e4de21da53a2e3d31cb9111f29a0`, committed 2026-08-01.
- Window: 293 commits, including 257 non-merge commits.
- Files changed upstream: 264.
- Next review cursor: `6bf627a51411e4de21da53a2e3d31cb9111f29a0`.

No dedicated Akkoma audit ledger existed before this review. Individual
Akkoma-derived changes in the changelog were not treated as a complete cursor,
so the review begins at the final `develop` commit before January 1, 2026.

## Adapted now

### OAuth secret redaction

Commit `c92456bf7` excludes authorization codes, access tokens, and refresh
tokens from the default `Inspect` representation of their Ecto structs. This
prevents ordinary exception and debug inspection from turning a bearer secret
into a log entry.

### Literal Mastodon filter phrases

Commit `d6209837b` identifies that user filter phrases were interpolated into
regular expressions as active syntax. Unfathomably now escapes every phrase
with `Regex.escape/1` before composing the Erlang and PostgreSQL forms.

The Akkoma helper was not copied verbatim because its pattern appears to match
the complete metacharacter sequence rather than each metacharacter. The local
adaptation preserves the intended literal semantics without that ambiguity.

### Query-bound HTTP signatures

Commits `6f98e0b89` and `6bf627a51` bind query parameters to outgoing legacy
HTTP signatures and prefer the query-bound form during incoming verification.
Unfathomably retains path-only verification as a fallback for older Pleroma and
Mastodon-family peers, but no longer lets that historical form take precedence
over a correctly signed query target.

### Activity-shaped MRF filtering on refetch

Commit `0baa51709` points out that a fetched object update can bypass policies
which operate on an enclosing `Update` activity. Unfathomably already validates
and MRF-filters reinjected objects, but it supplied the bare object. Existing
objects are now wrapped in a synthetic `Update` for filtering and the filtered
object is extracted before persistence. This preserves the local updater and
cache pipeline while making media and activity-shaped policies effective.

### Deterministic database search

Commit `811f0a468` removes the global `gin_fuzzy_search_limit` default because
PostgreSQL may return an arbitrary subset after reaching the cap. Unfathomably
now leaves fallback database search exact and deterministic. Operators needing
bounded search should use an indexed external backend or a deliberately scoped
query mechanism rather than changing every repository connection globally.

## Already covered locally

- Mastodon-compatible translation APIs and translation-language discovery,
  including avoiding provider calls when translation is disabled.
- Hidden follower and following counts in streamed relationship updates.
- FEP-2c59 actor metadata, leading-`@` WebFinger handles, and extensive remote
  actor validation and alias handling.
- Exclusive Mastodon lists and frontend member-management workflows.
- Host-header validation on signed ActivityPub routes.
- Immutable caching for hashed frontend assets, uploaded media, and proxied
  media responses.
- ConfigDB allowlisting, protection of the allowlist setting itself, and a CLI
  cleanup task for persisted settings outside the boundary.
- Poll update handling when normalisation fills the unused `anyOf` or `oneOf`
  collection with an empty list.
- Notification visibility checks for replied-to users and subscribers.
- Bounded, paginated status-context endpoints and normal not-found responses.
- Leading-`@` remote interaction handles, attachment MIME normalisation, avatar
  and header descriptions, and Mastodon-style quote identifiers.

## Reviewed but not transplanted

### User ActivityPub identifier redesign

The July series generates new local actor IDs from database IDs and separates
display URLs from canonical actor identifiers. This is a sound design for a new
installation, but changing canonical IDs on a live server would affect keys,
follows, cached aliases, backups, groups, feeds, Nostr bridges, and every remote
reference. Unfathomably retains stable existing actor IDs and its guarded alias
redirects.

### Activity visibility and direct-timeline removals

Akkoma removed historical thread-containment, list-addressing, direct-timeline,
and activity-visibility structures. Unfathomably still uses related concepts in
group, event, source, world, and compatibility workflows. Copying those schema
removals would be destructive and was rejected.

### Full WebFinger and user-fetcher replacement

Akkoma's large WebFinger rewrite adds useful authority, delegation, and
nickname rules. Unfathomably already has independent handling for groups,
feeds, alternate discovery, source outboxes, actor aliases, custom-object
publishers, and stricter signature-key resolution. Individual security lessons
are already represented, but replacing the subsystem wholesale would regress
the broader discovery model.

### Non-federating inbox status

Akkoma returns HTTP 405 when federation is disabled so senders can treat the
inbox as unsupported. Unfathomably currently distinguishes the general
federation plug from the stricter inbox guard. Changing this behavior should be
an explicit operator/privacy decision rather than an incidental backport.

### Poll voter-identity extension

Akkoma exposes whether a remote poll promises anonymous votes and federates
`votersCount`. Unfathomably already stores and renders `votersCount`, but a new
client-visible anonymity contract needs coordinated API schema and frontend
language before it should be advertised.

### MFM parser expansion

The MFM updates are relevant only to deployments that intentionally enable the
Misskey-flavoured parser. Sanitizer ordering is already hardened locally, and
parser lockfile changes should continue through the normal dependency audit.

### Search subsystem rewrite

Akkoma's search series adds unauthenticated restrictions, exact-match fast
paths, content-warning search, per-query PostgreSQL settings, and connection
checkout changes. Unfathomably has Meilisearch, native world discovery, remote
resolution limits, and different search ranking. The deterministic global
configuration fix was taken now; the remaining series needs endpoint-specific
profiling rather than a wholesale transplant.

## Not applicable

- Akkoma-FE links, Docker runner settings, nginx examples, Grafana dashboard
  formatting, release-version changes, and documentation-only commits.
- Dependency changes that target Akkoma's exact lockfile. Unfathomably tracks
  its own current Mix dependency train and should not replace the lockfile from
  another application.
- Pleroma history replacement and merge-only bookkeeping.

## Outcome

The review produced six concrete backend improvements without importing
Akkoma's live-identity migration or database-removal assumptions. Future
reviews should continue from the recorded head rather than rescanning the full
2026 window.

<!-- end of UPSTREAM_AKKOMA_AUDIT.md -->
