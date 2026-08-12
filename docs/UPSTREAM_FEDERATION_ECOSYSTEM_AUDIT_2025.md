# 2025 Federation Ecosystem Audit

## Purpose

This ledger tracks the ongoing review of calendar-year 2025 changes in every
project represented by Unfathomably's wide federation test matrix. It also
includes the official Nostr NIP repository because the matrix has a dedicated
NIP-29 lane.

The purpose is not to copy unrelated application features. The review asks
whether each upstream change exposes a wire-format requirement, safety rule,
delivery behavior, object shape, discovery convention, or user-facing semantic
that should change Unfathomably BE or FE.

## Method

For each source unit, the audit established the last reachable commit before
2025 and the last commit authored during 2025. Every commit in that interval was
exported to a tab-separated ledger. Commit subjects and changed paths were
screened broadly for protocol, federation, security, rendering, discovery,
moderation, delivery, retry, media, and object-model terms. Candidate diffs were
then compared with the current Unfathomably implementation.

The source corpus contains 46,396 commits. Deterministic exclusions leave
33,827 runtime-lane commit rows for patch-level review. The earlier broad
screen identified 9,798 candidates and inspected 2,680 candidate diffs, but
that screening does not count as complete patch coverage.

Patch-level completion requires every runtime-lane commit to belong to a
full-patch cluster with an explicit `implemented`, `already-present`,
`rejected-not-transferable`, or resolved follow-up disposition. As of
2026-08-07, 272 clusters covering 4,125 commit rows have decisions and 29,702
runtime-lane rows remain pending. Deferred findings remain open work and are
not represented as implemented.

Funkwhale includes reachable commits split between its July mirror and
December official history. The official host was unavailable during the
initial source collection; that ancestry boundary remains called out below
and must not be represented as stronger evidence than it is.

A no-change disposition means one of the following was proved:

- Unfathomably already implements the interoperable behavior.
- The change is internal to the peer and has no portable wire-level lesson.
- Importing it would weaken validation, privacy, authorization, or resource
  bounds.
- The feature requires an authority or trust model that the peer protocol does
  not communicate safely to Unfathomably.

## Source coverage

| Source unit | 2025 commits | Broad candidates | Inspected diffs | Status |
| --- | ---: | ---: | ---: | --- |
| ActivityPods | 147 | 39 | 2 | Source screened; patch audit in progress |
| Bonfire | 891 | 56 | 21 | Source screened; patch audit in progress |
| BookWyrm | 735 | 55 | 11 | Source screened; patch audit in progress |
| Castling.club | 6 | 0 | 0 | Source screened; patch audit in progress |
| Discourse | 5,563 | 924 | 61 | Source screened; patch audit in progress |
| Discourse ActivityPub plugin | 118 | 57 | 21 | Source screened; patch audit in progress |
| dokieli | 895 | 188 | 22 | Source screened; patch audit in progress |
| FediGroups | 4 | 0 | 0 | Source screened; patch audit in progress |
| Flohmarkt | 890 | 121 | 22 | Source screened; patch audit in progress |
| Forgejo | 2,091 | 285 | 50 | Source screened; patch audit in progress |
| Friendica | 1,373 | 359 | 74 | Source screened; patch audit in progress |
| Friendica addons | 132 | 11 | 0 | Source screened; patch audit in progress |
| Funkwhale | 426 | 258 | 32 | Source screened; patch audit and mirror-boundary review in progress |
| Gancio | 436 | 177 | 32 | Source screened; patch audit in progress |
| GoToSocial | 523 | 241 | 57 | Source screened; patch audit in progress |
| Hubzilla | 916 | 190 | 16 | Source screened; patch audit in progress |
| Hubzilla addons | 121 | 23 | 8 | Source screened; patch audit in progress |
| Ibis | 221 | 79 | 36 | Source screened; patch audit in progress |
| Iceshrimp.NET | 35 | 9 | 6 | Source screened; patch audit in progress |
| Lemmy | 542 | 241 | 74 | Source screened; patch audit in progress |
| Manyfold | 3,970 | 508 | 85 | Source screened; patch audit in progress |
| Mastodon | 2,250 | 491 | 151 | Source screened; patch audit in progress |
| Mbin | 408 | 87 | 41 | Source screened; patch audit in progress |
| Misskey | 1,911 | 399 | 71 | Source screened; patch audit in progress |
| Mitra | 928 | 513 | 299 | Source screened; patch audit in progress |
| Mobilizon | 402 | 116 | 13 | Source screened; patch audit in progress |
| Mutual-aid Shape Trees | 9 | 1 | 0 | Source screened; patch audit in progress |
| NeoDB | 562 | 79 | 8 | Source screened; patch audit in progress |
| NodeBB | 1,908 | 547 | 307 | Source screened; patch audit in progress |
| Official Nostr NIPs | 216 | 7 | targeted NIP diffs | Targeted NIP review complete; commit patch audit in progress |
| Owncast | 980 | 365 | 17 | Source screened; patch audit in progress |
| PeerTube | 1,969 | 234 | 45 | Source screened; patch audit in progress |
| PieFed | 3,788 | 894 | 355 | Source screened; patch audit in progress |
| Pixelfed | 1,110 | 301 | 58 | Source screened; patch audit in progress |
| Postmarks | 20 | 1 | 0 | Source screened; patch audit in progress |
| Sharkey | 3,755 | 895 | 241 | Source screened; patch audit in progress |
| snac2 | 957 | 157 | 67 | Source screened; patch audit in progress |
| WAFRN | 3,391 | 501 | 127 | Source screened; patch audit in progress |
| Wanderer | 750 | 59 | 15 | Source screened; patch audit in progress |
| WordPress ActivityPub | 938 | 567 | 257 | Source screened; patch audit in progress |
| WriteFreely | 109 | 17 | 8 | Source screened; patch audit in progress |
| XWiki ActivityPub | 0 | 0 | 0 | No 2025 commits |
| ZenPub | 0 | 0 | 0 | No 2025 commits |

## Implemented findings

### ActivityPods and mutual-aid Shape Trees

ActivityPods commits `79115b80`, `773a77cc`, and `fefb608f` replaced coarse
resource-class discovery with Solid Shape Tree identifiers and SHACL target
classes. Unfathomably now preserves bounded `shapeTreeUri` and
`interop:registeredShapeTree` references in native presentation metadata.

Unfathomably does not automatically dereference arbitrary Shape Tree or SHACL
URLs while rendering. Doing so would add an unbounded remote-fetch and SSRF
surface. The identifiers are available for safe classification and explicit
future resolution through the existing guarded fetch path.

### BookWyrm series

BookWyrm commit `e3699ff6` introduced `Series`, `SeriesBook`, `seriesBooks`,
`seriesIds`, and `seriesNumber`. BE classifies these bounded objects and exposes
their relationships. FE presents series and position beside the existing book
details on standard post cards.

### Funkwhale playlists

Funkwhale commits `fedd340e` and `c9d915fb` moved public audio sharing toward
federated `Playlist` and `PlaylistTrack` objects. BE now recognizes both types
and preserves their playlist, track, and index relationships. Existing generic
collection paging, signed fetch, public-audience checks, and track rendering
remain the authority for retrieval and interaction.

### Mastodon and Friendica quote authorization

Friendica commit `fd8395a9` and Mastodon's 2025 FEP-044f work were compared with
the existing local quote request, accept, reject, revoke, worker, and policy
implementation. Unfathomably already covered the primary protocol. Mastodon
commits `48005c55` and `ea7371c1` supplied two missing hardenings: authorization
documents now disappear when either object is a Tombstone, and only fully
public live documents receive a short shared-cache lifetime.

### Nostr relay and group semantics

NIP-11 commits `611b6351` and `8c45ff5d` distinguish the maximum explicit query
limit from the default used when a client omits `limit`. Remote relay metadata
now preserves both values.

NIP-29 commit `fb18d4c7` clarifies that `private` controls reading, `restricted`
controls member posting, `hidden` controls discovery, and `closed` controls join
requests. The bridge no longer mistakes `restricted` for moderator-only posting.
Hidden mirrors are excluded from discovery, and private native group events are
stored as verified Nostr records without being copied into a public ActivityPub
post. A future private cross-protocol projection requires a defensible per-member
audience and is intentionally not guessed.

NIP-25 commit `a6a20209` confirms custom emoji reactions are not ordinary likes.
The existing bridge already maps only `+` or empty content to a favorite and
keeps other content as emoji reactions. External-content kind 17 reactions from
`84e0b44f` remain deferred because an arbitrary external identifier is not proof
of authority over a local ActivityPub object.

## Patch-level completion pass

The initial source table proved that every 2025 history had been collected and
screened, but collection counts alone did not prove that the strongest patches
had been compared with Unfathomably. The final pass reopened the largest and
most protocol-sensitive sets and inspected the actual diffs before assigning a
disposition.

| Source | Representative patches inspected | Result |
| --- | --- | --- |
| Sharkey | `82b90d02`, `a568333e`, `e5593af4`, `969fdc03`, `71487f78`, `893f964d`, `6e8ab007`, `01dfdc6d`, `cc4236e6`, `a5d49c8b` | Added object-visibility validation to incoming interactions. Existing HTTPS, redirect, key-history, signature-query, quote, and terminal-refresh handling covered the other portable lessons. |
| Owncast | `f1ca5f95`, `92d1b79a`, `8c97360c`, `8eb8bdc1`, `149d80a0`, `e088520d` | Stream-key, chat, and Owncast administration changes were product-local. Existing Service actor and live-stream metadata handling already covered the federation-facing lessons. |
| Discourse ActivityPub | `861e2d8b`, `ac74e0aa`, `b3efec49`, `85a46e6d`, `bdcc7872`, `6b6d9289`, `6a023593`, `2d360f8a`, `9a78a76a` | Conflict-safe object/activity insertion, actor refresh, collection visibility, Service actors, and attachment handling were already present. A second object mutex was not added because it would duplicate database conflict control. |
| PieFed | `124c64da`, `39461acd`, `ce0beab2`, `e6520759`, `1833f075`, `83a84a4a` | Existing immutable publisher payloads, actor merging, attachment updates, cache invalidation, and private-message validation covered the portable fixes. PieFed's removed audience check was intentionally not copied. |
| WordPress ActivityPub | `33179e16`, `4f8a4fae`, `c99298ea`, `73887658`, `7f43ae4f`, `a5ed897c`, `00c30c70`, `82396773`, `e3827496` | Added moderation of `contentMap`, `summaryMap`, and `nameMap`. Existing cleanup preservation, self-Announce handling, Follow idempotence, actor validation, and interaction policy support covered the rest. |
| Manyfold | `ac56fa85`, `5d558238`, `37a67b96`, `27f7f361`, `b33b71d9`, `92ce5648`, `f6b9c320`, `3eb3f0dc` | Added object-level discovery opt-outs and matching partial-index predicates. Existing remote ownership checks and native 3D model/file presentation covered the remaining portable behavior. |
| NodeBB | `822f4edc`, `fadac616`, `07bed55e`, `885b83e5`, `92708d2f`, `33d7b9b3`, `7687da00`, `ddb6e0f3` | Existing wrapped Delete, attachment, cache invalidation, emoji, category Follow, conversation, and private-message handling covered the useful fixes. Oversized remote messages remain rejected rather than converted into attacker-triggered notifications. |
| Misskey | `e5d117dc`, `389ec635`, `f454e820`, `b2e3e658`, `d7fdcbc7`, `b5767c31`, `73bcd330` | Added direct Delete delivery to remote interaction actors. Existing URL-authority checks, quote markup and FEP fields, attachment alternatives, outbox pagination, emoji metadata, and local-host federation policy covered the rest. |
| WAFRN | `143b7d43`, `8990576d`, `5d5f9669`, `36e61a19`, `5655b526`, `84f2012a`, `bf819003` | Existing digest and actor binding, safe embedded-proof handling, bounded key refresh, idempotent Follow, missing shared-inbox fallback, attachments, and quote authorization were stronger or equivalent. WAFRN-specific Bluesky bridging and Bite activities were not copied. |
| Mastodon | `1248c4d1`, `3e5d78cc`, `22e2e7f0`, `7a7e0ba4`, `59e189ad`, `3edac14f`, `5b291fcb`, `9c80b164`, `0ec6c26a`, `0be0a889` | Added normalized FE mention matching, bounded missing-quote hydration, and safe forwarding of quote Updates and Deletes. Existing RFC 9421, redirect re-signing, collection paging, attachment alternatives, duplicate-safe JSON storage, and collection-shape handling covered the other patches. |

The remaining source units already had patch-level dispositions from the first
pass. Their candidate ledgers remain under `upstream-audit-2025/screening`, and
the table below records whether the lesson was implemented, already covered,
or deliberately rejected as unsafe or product-specific.

## Per-platform dispositions

| Matrix platform | Result of the 2025 review |
| --- | --- |
| ActivityPods | Implemented bounded Shape Tree identity; remote SHACL fetching remains guarded and explicit. |
| Bonfire ValueFlows | Existing Offer, Need, Resource, Intent, Proposal, and relationship handling covers portable changes. |
| BookWyrm | Implemented Series and SeriesBook metadata and FE presentation. |
| Castling.club | No protocol-bearing 2025 commit; existing chess object handling remains current. |
| Discourse | Existing category/group Announce, conflict-safe inserts, collection visibility, delivery retry, key refresh, Service actors, attachments, and delete handling cover the plugin lessons. |
| dokieli | Security and Solid editor changes are application-local; Unfathomably's sanitizer and guarded fetch path are stricter. |
| FediGroups | No portable code change in the four 2025 commits. |
| Flohmarkt | Existing Update replacement includes attachments; price, currency, location, and coordinates are already exposed. |
| ForgeFed / Forgejo | Existing actor resolution, signed fetch, project, repository, issue, patch, and development activity support covers portable changes. |
| Friendica | Quote authorization was already complete; adopted cache and Tombstone hardening. |
| Funkwhale | Added Playlist and PlaylistTrack; retained standards-based recipient visibility; existing actor 404, WebFinger, search, duration pass-through, Listen/favourite handling, reachability backoff, and delete processing cover the portable lessons. |
| Gancio | Existing raw-body digest verification, Event, Place, Announce, reply, and delete handling covers portable changes. |
| GoToSocial | Existing interaction policy, indexability, 410, focal media, key refresh, and bounded retry behavior covers portable changes. |
| Hubzilla | Existing actor extensions preserve protocol tags and Zot-family metadata; no unsafe host-name inference was added. |
| Ibis | Existing recipient normalization, content negotiation, Update, collection, and conflict-safe insertion cover portable changes. |
| Iceshrimp.NET | Existing Misskey-family quote, reaction, delete, profile, and Group probe behavior covers the small 2025 set. |
| Lemmy | Existing multi-community audience extraction, nested-object bounds, moderation, and retry handling cover portable changes. |
| Manyfold | Added explicit object discovery opt-outs; existing F3DI concrete type, license, tags, content warning, file name, MIME type, preview, ownership, and actor image metadata cover the other portable changes. |
| Mastodon | Added quote forwarding, bounded quote hydration, and normalized mention matching; quote authorization, RFC 9421, signed redirects, interaction policy, media bounds, and status semantics were already present. |
| Mbin | Existing wrapped group activity, moderation Announce, retry, Update, Lock, and collection compatibility covers portable changes. |
| Misskey | Added Delete reach for independently discovering interactors; existing quote URI aliases, reaction semantics, refetch bounds, URL authority, outbox paging, and profile handling cover the other portable changes. |
| Mitra | Existing RFC 9421 request-target, full-URI, port, digest, and key resolution behavior covers portable changes. |
| Mobilizon | Existing Event, Place, Image, group Announce, RSVP, comment, delete, and actor refresh handling covers portable changes. |
| Mutual-aid federation | Shape Tree identifiers are now retained; existing ValueFlows and coordination records remain the presentation model. |
| NeoDB | Existing cultural objects, recursive relation bounds, language, ratings, reviews, and retry handling cover portable changes. |
| NodeBB | Existing category Announce, topic/reply delivery, durable jobs, reactions, deletion, and group discovery cover portable changes. |
| Owncast | Existing service actor, stream lifecycle, audience, media, pool, and job bounds cover portable changes. |
| PeerTube | Existing channel, Video, scheduled live metadata, comment, reaction, delete, raw-recipient, and key retry behavior covers portable changes. |
| PieFed | Existing origin fetch, retry, closure, group moderation, and community discovery behavior covers portable changes. |
| Pixelfed | Existing Document and media attachment rendering, replies, favorites, unfavorites, and deletes cover portable changes. |
| Postmarks | The 2025 changes were deployment and documentation only. |
| Sharkey | Added actor-to-target visibility validation for incoming interactions; existing Misskey-family reaction, quote, profile, signature, redirect, key-history, and remote-refetch cooldown behavior covers the other portable changes. |
| snac2 | Existing quote aliases, Tombstone/410, Event Update, reaction, and compact actor handling covers portable changes. |
| WAFRN | Existing digest and actor binding, embedded-proof origin authentication, key refresh, Follow idempotence, quote authorization, rich object, and bounded rendering behavior covers portable changes. Bluesky bridge and Bite behavior is product-specific. |
| Wanderer | Existing signed route fetches, trail identity, geographic metadata, actor discovery, and deduplication cover portable changes. |
| WordPress ActivityPub | Added language-map moderation; existing shared inbox, cleanup preservation, collections, Move, key management, Follow idempotence, QuoteAuthorization, and signature behavior covers the other portable changes; FEP-8fcf remains deferred because its authority assumptions are not portable. |
| WriteFreely | Existing collection context, source actor discovery, long-form rendering, and Ghost-style follow behavior covers portable changes. |
| XWiki | No 2025 source commits were present. |
| ZenPub | No 2025 source commits were present. |
| Nostr NIPs | Implemented NIP-11 and NIP-29 corrections; NIP-25 custom emoji behavior was already correct. |

## Funkwhale source continuity

The official Funkwhale GitLab host was intermittently unavailable during the
audit. The completed source uses a GitHub-maintained derivative whose ancestry
contains the known July mirror tip `5f5b185c` and the exact November parent
`49411842` of the previously fetched December official boundary `bde1df4c`.
That continuity proof closes the July 11 through November 30 gap without
assuming that two disconnected snapshots represent the complete history.

<!-- end of UPSTREAM_FEDERATION_ECOSYSTEM_AUDIT_2025.md -->
