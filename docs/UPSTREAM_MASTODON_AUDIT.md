# Mastodon Upstream Audit

This ledger records reviews of Mastodon changes for lessons that can be
adapted to Unfathomably. It is not an ancestry manifest: Mastodon and
Unfathomably have different application architectures and data models.

## 2026-08-05 review

The previous review boundary was the Mastodon checkout head recorded on
2026-07-15:

- Start, exclusive: `06f3695d94911779f198c1bf8f581f31d4391a79`
- End, inclusive: `8e592b88d625c4d437ef5dcc115096656b8607da`
- Range: 145 non-merge commits
- Diff size: 395 files, 8,861 insertions, 3,235 deletions

Every commit in the range was reviewed by subject and affected subsystem.
Portable candidates were then reviewed from their source diffs. The range
contained 64 dependency/localization changes, 12 frontend/design changes, 29
platform-specific changes, and 40 changes touching potentially portable
product or federation behavior.

### Adapted in this pass

| Mastodon change | Unfathomably disposition |
| --- | --- |
| [`0114b389`](https://github.com/mastodon/mastodon/commit/0114b389b012a8ab3da9e5a3e331ebe53e1cd016) `Link` attachments | Preserve bounded HTTP(S) `Link` attachments, use them as rich-card candidates, and exclude them from media rendering. |
| [`9d51f51c`](https://github.com/mastodon/mastodon/commit/9d51f51cc07aca1dc8e5ddfeadd1b6ed33815f43) known-object author changes | Reject a repeat `Create` when its actor differs from the stored Create actor. |
| [`428fccf0`](https://github.com/mastodon/mastodon/commit/428fccf04afdab8dfd2b53e38d39ea51c104d28e) null tags | Remove null tag values before validators and tag consumers see them. |
| [`f8337b04`](https://github.com/mastodon/mastodon/commit/f8337b04fe9bccb1ad021a8579d85d366605e1b2) collection limits | Cap remote featured-item storage and fetch fanout at 150 entries. This is deliberately separate from the smaller local-account pin limit. |

### Already covered locally

- Remote handle changes and stale-handle conflicts from `8bf4dc18`,
  `9748bcfe`, and `b625f21c` are covered by AP-ID-first actor refresh,
  collision-safe stale nickname renaming, and unique AP-ID insertion.
- Remote actor `410 Gone` handling from `9edbe470` is covered by tombstone
  deactivation and terminal refresh classification.
- Account URI uniqueness from `e0efc968` is covered by the unique
  `users_ap_id_index` and conflict-aware remote insertion.
- Nullable poll expiration from `42c01d70` is already represented as nullable
  in the frontend schema and does not mark a poll expired merely because the
  timestamp is absent.
- Follow-request counts already join active requesters, covering `86a7f955`.
- Backup item isolation and missing-user job guards cover `ae4f80ee` and
  `7f4800eb`.
- Rich-media and external search work already has bounded HTTP timeouts and
  health gating, covering the portable lesson from `299b628c`.
- Signed-fetch SSRF, admin authorization, and ActivityPub diagnostics are
  already enforced by origin containment, private-network fetch guards,
  scoped admin plugs, and structured federation logging.

### Reviewed but not copied

- Mastodon's Rails CSRF, ActiveRecord migration, Sidekiq, Elasticsearch,
  materialized-view, and S3 batch mechanics do not map directly to Phoenix,
  Ecto, Oban, Meilisearch, or Unfathomably's uploader abstraction.
- Mastodon's redesign and React implementation changes target a separate
  frontend and do not supersede Unfathomably FE's Soapbox visual language.
- `mldsa44-jcs-2024` Object Integrity Proof support remains deferred. The
  cryptosuite is still based on a 2026 working draft and the current OTP crypto
  stack does not provide the required ML-DSA primitive. Existing Ed25519 proof
  verification remains fail-closed.
- Mastodon's collection-of-activities removal, QuoteRequest changes, and
  account-merging fixes operate on models Unfathomably does not share. Their
  trust and idempotency invariants were checked against the ActivityPub
  pipeline rather than copied structurally.

The next Mastodon audit should begin after
`8e592b88d625c4d437ef5dcc115096656b8607da`.

<!-- end of docs/UPSTREAM_MASTODON_AUDIT.md -->
