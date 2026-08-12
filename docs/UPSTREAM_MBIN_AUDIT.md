# Upstream MBin Audit

This document records the focused review of recent MBin changes for lessons
that can be adapted to Unfathomably without importing MBin-specific Symfony,
Doctrine, Twig, or PHP runtime architecture.

## Audit window

- Official repository: `https://github.com/MbinOrg/mbin`
- Branch: `main`
- Previous Unfathomably MBin cursor: none found
- Conservative base: `6ee7918acf65a786b321c9998140ac41e6b4d857`
  from 2026-06-15
- Reviewed head: `1439efd749e7af9d157c6bda4fa2cac4cb79e6bb`
  from 2026-08-05
- Commits reviewed: 29, all non-merge commits

June 18, 2026 was requested as the approximate boundary. The nearest earlier
commit was used as the base so the boundary could not omit work.

## Adapted now

### Actor profile URL arrays

MBin commit `c719c41af341458173723807fe0c7e5f43b61d02` fixed magazine
profile ingestion when an ActivityPub actor's `url` property is an array.
Unfathomably already avoided type errors for arrays, but selected only the first
entry. It now extracts usable strings, `href`, `id`, and nested `url` values,
then chooses the candidate with the fewest path segments. Publisher order is
retained when candidates have equal depth.

This keeps ordinary actor and group profile links stable when a peer puts an
alternate representation before its canonical human-readable profile.

## Already covered

### Inactive and pending API users

Commit `6af202c3c4841c2906407012c3b6f0f53d21d282` applies MBin's web
user checker to OAuth API requests. Unfathomably's OAuth plug only resolves
tokens to active users, and authenticated pipelines apply the existing account
status policy. Its confirmation and approval lifecycle intentionally differs
from MBin's application workflow, so copying MBin's pending-state rules would
break Mastodon-compatible registration behavior.

### User-level instance blocks

Commit `4afca4a79af2d088b913f8279fc135b53ee33647` adds per-user
instance blocks and applies them to content and search. Unfathomably already
implements Mastodon domain-block endpoints and filters blocked domains from
timelines, search, notifications, streaming, relationships, groups, and source
feeds while preserving explicitly followed relationships where required.

### Boost-aware combined ordering

Commit `0466fa4b14a9c96b3230b8032ea72acdcf698284` records a separate
last-boost timestamp for MBin's combined content table. Unfathomably stores an
Announce as its own activity, so timeline keyset ordering naturally uses the
boost activity's insertion time without mutating the original object's date.

### Case-sensitive ActivityPub identity

Commit `d6426e8068e42e500551ad68fa06ff5ed4b87bf6` stops applying a
case-insensitive username lookup to ActivityPub users. Unfathomably resolves
canonical remote identity by exact `ap_id`; case-tolerant nickname handling is
limited to human-facing account lookup and does not redefine actor ownership.

### Search without a content type

Commit `8bcabc123b014783958b18d9ec888c7961baf3ec` makes a missing MBin
search type mean both threads and microblogs. Unfathomably's account/status and
federated-target discovery endpoints already treat an omitted specialization
as combined discovery rather than an empty result.

### Visibility and query correctness

Commits `c2e1b2185766a75fc2054ff94712c7979520693d` and
`5816c805375e6fde94809e200ba5b1ba15d4ca18` correct MBin-specific SQL
aliases, subscription joins, and magazine visibility in combined searches.
Unfathomably builds these timelines from ActivityPub activities with shared
visibility, block, and authorization filters rather than parallel SQL unions
for four MBin entity tables.

### Worker memory discipline

Commits `f1ec93ede4a95d5917cb713e1c5d492f990366df` and
`f0520d22f0e4aa21255ee7f2a825897d053bd321` reduce eager Doctrine
collection loading and force PHP cycle collection after queue messages.
Unfathomably's Oban jobs run as isolated BEAM processes, release process heaps
on completion, and use bounded batches for large janitor and deletion work.

## Not transplanted

- MBin's direct-video allowlist only accepts MP4 and WebM. Applying it would
  regress Unfathomably's PeerTube, HLS, remote attachment, and external-player
  compatibility; unsupported media continues to use a safe linked fallback.
- Redis session migration, managed PHP session garbage collection, PHP 8.5,
  Docker, devcontainer, and CI changes are runtime-specific.
- Doctrine `EXTRA_LAZY` mappings and MBin's last-boost database migration do
  not correspond to Unfathomably's Ecto schemas or activity model.
- Translation, version, documentation, npm audit, and Guzzle dependency bumps
  do not provide portable BE or FE behavior.

## Next cursor

Resume the next MBin review after:

`1439efd749e7af9d157c6bda4fa2cac4cb79e6bb`

<!-- end of docs/UPSTREAM_MBIN_AUDIT.md -->
