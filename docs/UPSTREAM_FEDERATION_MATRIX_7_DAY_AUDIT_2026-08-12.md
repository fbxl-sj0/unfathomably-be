<!--
  Unfathomably backend
  File: docs/UPSTREAM_FEDERATION_MATRIX_7_DAY_AUDIT_2026-08-12.md
  Purpose: Record the seven-day delta audit across the federation matrix.
  This file does not claim source compatibility with the reviewed projects.
-->

# Federation matrix seven-day audit ending 2026-08-12

## Method and scope

The audit covers branch commits entering the matrix from
`2026-08-05T00:00:00Z` through `2026-08-12T23:59:59Z`. Git committer time is
the range authority; a merged commit can therefore retain an earlier author
time while correctly appearing in this window. All 960 commits across 47
source units were screened by subject, changed path, and patch. Protocol,
security, delivery, discovery, data-shape, media, and user-visible changes were
compared with current Unfathomably BE and FE behavior.

Forty-six checkouts refreshed successfully. The FediGroups forge URL returned
404, so its existing checkout was inspected and recorded as having no commits
in the window rather than silently dropping it from the matrix.

| Project | Commits | Reviewed head |
| --- | ---: | --- |
| ActivityPods | 0 | no window commits |
| Bonfire | 32 | `5397b266ee66` |
| BookWyrm | 9 | `89165dc696fe` |
| Castling.club | 0 | no window commits |
| Discourse | 156 | `ab9b2fbbeb92` |
| Discourse ActivityPub | 1 | `dc484ccb3ec5` |
| dokieli | 33 | `c23e80e4fe54` |
| FediGroups | 0 | checkout available; remote returned 404 |
| Flohmarkt | 0 | no window commits |
| Forgejo | 67 | `7afb7e87d897` |
| Friendica | 87 | `75852ea3d909` |
| Friendica addons | 2 | `ca420749a8df` |
| Funkwhale | 10 | `c58504cd5cfa` |
| Gancio | 19 | `70b90212f8d4` |
| GoToSocial | 1 | `7501a6f27966` |
| Hubzilla | 13 | `ea733fcfdf29` |
| Hubzilla addons | 6 | `2a19a43cb6fd` |
| Ibis | 0 | no window commits |
| Iceshrimp.NET | 0 | no window commits |
| Lemmy | 5 | `36d6297c8f82` |
| Manyfold | 57 | `65292fd285ba` |
| Mastodon | 67 | `697e96c220e4` |
| Mbin | 5 | `19974add226c` |
| Misskey | 1 | `988e3c32a39c` |
| Mitra | 27 | `b282f81dd844` |
| Mobilizon | 0 | no window commits |
| Mutual-aid Shape Trees | 0 | no window commits |
| NeoDB | 21 | `732be6278760` |
| NodeBB | 106 | `61a7a0aa58a5` |
| Official Nostr NIPs | 1 | `656cecc7c0a8` |
| Owncast | 12 | `5731ded5dd94` |
| PeerTube | 85 | `7667b26871b2` |
| PieFed | 6 | `30ab48953129` |
| Pixelfed | 0 | no window commits |
| Postmarks | 0 | no window commits |
| Sharkey | 0 | no window commits |
| snac2 | 10 | `9666850e2239` |
| WAFRN | 47 | `6ff260f38548` |
| Wanderer | 1 | `1c3446c17780` |
| WordPress ActivityPub | 19 | `84ea1a461431` |
| WriteFreely | 27 | `aa0143148ebc` |
| XWiki ActivityPub | 0 | no window commits |
| ZenPub | 0 | no window commits |
| Fedify | 8 | `15ad1515640d` |
| Ghost ActivityPub | 13 | `ddd860be69dd` |
| Streams | 6 | `aa53f72db449` |
| Takahē | 0 | no window commits; NeoDB carries its active fork work |

## Implemented lessons

- NeoDB/Takahē `a2fb3ace` and `732be627` complete FEP-7aa9 actor feature
  consent. Unfathomably already advertised `interactionPolicy.canFeature`, but
  did not process FeatureRequest. Direct actorless requests now inherit only a
  verified HTTP-signature actor, discoverable local actors issue idempotent
  FeatureAuthorization documents, and non-discoverable actors reject them.
  Relayed actorless requests remain closed because a relay HTTP signature does
  not prove the origin requester.
- Comparing that path exposed a local allowlist defect: the implemented
  QuoteRequest validator and side effects were unreachable through the inbox
  guard. QuoteRequest and FeatureRequest are now recognized activity types.

## Confirmed existing or stronger behavior

- NodeBB `d30f4c2f` aligns duplicate `keyId` parsing with a last-wins library.
  Unfathomably rejects every duplicated legacy Signature parameter instead,
  ensuring key lookup and cryptographic verification cannot disagree.
- NodeBB `e11c9fc5` treats a failed optional signed GET as anonymous. This is
  already Unfathomably behavior when authorized-fetch policy is disabled; an
  enabled policy still correctly rejects the now-unsigned request.
- NodeBB `7da65694` validates remote emoji icon URLs. Emoji tags already require
  HTTP(S) URLs through the ActivityPub URI type and malformed tags are ignored.
- NodeBB `813c37a6` rejects array-valued attribution to avoid an origin-check
  bypass. Unfathomably retains standards-compatible attribution arrays but
  validates actor authority and object containment across normalized IDs.
- Owncast `1b7970ea` serializes concurrent Follow delivery. Database uniqueness,
  conflict-safe relationship insertion, and deterministic Accept identifiers
  already make concurrent duplicate Follow delivery idempotent without a
  process-local lock.
- Mastodon `f01507ed` corrects collection item type extraction. The shared
  RemoteCollection reader already extracts `items` and `orderedItems`, accepts
  roots and pages, follows bounded same-origin pagination, and preserves inline
  objects.
- Mastodon `523aca3b` closes streams when deletion is requested. Local account
  deactivation already calls `Streamer.close_streams_by_user/1` before cleanup.
- WordPress ActivityPub `28726915` processes Public-only Delete at the shared
  inbox. Unfathomably's shared inbox enters the same receiver pipeline without
  requiring a resolved per-user hook, so this shape is already covered once.
- Streams `372e6bf1` adds the data-integrity context to minimal Follow and
  Accept activities. Unfathomably's outgoing preparation adds the shared
  ActivityPub and security contexts rather than emitting a separate stripped
  representation.
- WAFRN `3327cbb3` repairs Bluesky unfollow records missing an AT URI. The local
  ATProto publisher resolves linked records through the authenticated account
  session and does not depend on a social-follow row containing a foreign CID.
- snac2 `ac711dd4` repairs sensitive-state editing. Incoming booleans and
  Mastodon edit parameters are normalized through typed changesets; summary
  clearing does not leave a stale sensitive value.
- Official NIP-29 `656cecc7` adds an example for the existing `previous` tag.
  It clarifies relay-local anti-fork history but introduces no wire change.

## Reviewed without a portable change

The remaining patches were dependency, translation, generated asset, local UI,
framework, storage, or peer-internal lifecycle changes. Notable protocol-adjacent
work was still compared: Mitra's FEP-1b12 moderators collection matches the
existing local group moderators endpoint; PeerTube's queued video federation
matches Oban-backed publishing; Fedify's custom HTTP handlers are framework
routing; BookWyrm's remote-follow relocation is presentation-only; and
Discourse's edit-limit exemption is local forum policy. No behavior was copied
where Unfathomably could not preserve the reviewed project's authorization or
storage assumptions.

## Next review

Resume strictly after each reviewed head above. For zero-commit projects,
retain the current branch head as the cursor and begin with its first later
descendant. Restore or replace the FediGroups remote before treating a future
refresh failure as a clean zero-commit result.

<!-- end of docs/UPSTREAM_FEDERATION_MATRIX_7_DAY_AUDIT_2026-08-12.md -->
