<!--
  Unfathomably backend
  File: docs/UPSTREAM_FEDERATION_ECOSYSTEM_AUDIT_2026.md
  Purpose: Record the 2026 cross-ecosystem federation audit and resume cursors.
  This file does not claim source compatibility with the reviewed projects.
-->

# 2026 federation ecosystem audit

## Method and scope

No dedicated cursor existed for these projects, so January 1, 2026 is the
common conservative baseline. Every commit in each range was screened by
subject and changed path; protocol, security, data-shape, discovery, media,
delivery, and user-visible candidates received patch review. Language,
framework, packaging, translation, and project-local UI changes were recorded
as non-portable unless they exposed a protocol lesson.

| Project | Commits screened | Reviewed head and next cursor |
| --- | ---: | --- |
| Mobilizon | 161 | `e4e3d70747e1214415540eceb2bafeefabf0695c` |
| Fedify | 2,709 | `15ad1515640d90b91ce8e3a60c954e7106b9916f` |
| Ghost ActivityPub | 542 | `ab38c130010e230bb70e0b13efdb45f8016eb55e` |
| BookWyrm | 973 | `3d6da8b08179b0b074b2e62b188912d3966f1d1a` |
| WordPress ActivityPub | 614 | `2c89fa3fe0b30f288819d911c67cfc7c6b27f60d` |
| Bonfire | 722 | `272b150bfbc9b4fbc957ade06199ddb5021f6322` |
| Manyfold | 3,268 | `faadb717719ee760191918778ea5da509f10bd23` |
| NeoDB | 857 | `a914fcb8c0ce3b7de13c5279c9fc1372a0d6145b` |
| Flohmarkt | 777 | `27f72795ffa34c2f2615ae1e0256d54b47c57beb` |
| Wanderer | 224 | `fa168cb4b1a2f3af2cef03e1c9ad09eaba09e932` |
| Takahē | 0 | `d45f22c9c2f5e4feec9f9692c36b8385d51ec981` |
| snac2 | 409 | `ca60d65cb618da37e9c842706480d8b863c77055` |
| Hubzilla | 165 | `4af8fbbf5f91b02b37d156bd2f4aff3b8d1b0265` |
| Streams | 59 | `83f90075213911a7953cc46be6d90001cb8dbab1` |
| Forgejo | 1,265 | `89b71bc0bcf89efd892f29bd094d55154d10129c` |

Takahē has no commits in this window. NeoDB's maintained Takahē-derived
federation work supplies the active lessons for that family.

## Implemented lessons

- Mobilizon `6c3cb44`: Events may be signed by an organizing member while
  `attributedTo` names the Group. Unfathomably now accepts that shape only when
  the attributed actor resolves as a Group on the organizer's host. Ordinary
  status objects retain their stricter actor-attribution equality rule.
- NeoDB `53011a7`: JSON-LD permits `type` arrays. Incoming activities and their
  embedded objects now select a bounded known concrete type before validator
  dispatch, while retaining unknown specialized vocabulary types.
- snac2 `be54d22`: a valid public-key PEM may carry harmless text after its end
  marker. Remote actor ingestion now stores exactly the first recognized
  public-key block; unknown encodings retain the existing safe failure path.
- Bonfire `3fdab744` and `a9d49cd`: tested HTTP Message Signature support can be
  advertised through FEP-844e. Local actors now expose an anonymous partial
  Application generator, and service actors expose the same RFC 9421 Link
  capability directly.

## Mobilizon

- `cd7b4fa` confirms FEP-8a8e `endTime`; Unfathomably already stores and renders
  `startTime` and `endTime` with typed date validation.
- `6c5a582`, `6c3cb44`, and `d7f1574` informed the bounded group-attribution
  change. Mobilizon's internal group-role authorization cannot be copied
  because remote membership state is not authoritative here.
- `e454d50` reinforced accepting standards-compliant PEM actor keys, while
  `98ed533` matches the existing ability to ingest a directly delivered Event
  without requiring a separate Announce.

## Fedify and Ghost

- Fedify `8405a46a`, `0c10e0d8`, and `6afef275` require singular functional
  proof fields and unambiguous verification methods. Unfathomably does not
  expose Fedify's portable-object proof stack; its supported embedded-signature
  path authenticates a bounded activity, rejects conflicting `creator` and
  `verificationMethod` identities, and rejects ambiguous HTTP signature
  dictionaries instead of pretending to implement the broader stack.
- Fedify's Retry-After, circuit-breaker, task-deduplication, SSRF, redirect, and
  WebFinger canonicalization work is already represented by pooled HTTP
  controls, host reachability state, unique Oban jobs, public-address checks,
  bounded redirects, and alias-aware WebFinger resolution.
- Ghost `05a21de`, `cf7c9db`, and `a2d5963` reinforce alternate-domain and
  canonical actor discovery. Existing actor URL arrays, aliases, and canonical
  ID containment cover those shapes without treating sibling origins as the
  same cryptographic identity.
- Ghost `9d34685` and `b08ea71` match existing Move validation and remote actor
  deactivation behavior. Ghost's service architecture and parallel inbox
  scheduler are not transplanted into Oban.

## BookWyrm

- `d013a71`, `785bbb6`, and `fb10a0b` reinforce malformed-image tolerance,
  clean signed-fetch rejection, and avoiding actor persistence as a side effect
  of signature parsing. Existing image normalization and key lookup paths
  already follow those boundaries.
- `054206d` confirms that reviews need not have titles. Incoming Review and
  catalogue presentation derive useful display text from content and the
  related book. The local workflow's required title identifies that related
  book; review text has no separate headline requirement and a rating can stand
  alone.
- BookWyrm shelf privacy and Django-specific cache, form, and migration changes
  do not map to Unfathomably's bookshelf and Ecto models.

## WordPress ActivityPub

- `c2e8c25` is already covered: incoming Cavage signatures try the raw query
  string in `(request-target)` before the historical path-only compatibility
  form, and outgoing signed fetches include the query.
- `c06ce3d`, `d67504b`, `7fb6047`, and the Announce authority hardening match
  existing actor/object containment, key-owner checks, and canonical refetch of
  forwarded destructive activities.
- `74c5330` matches the existing replay windows for HTTP Message Signatures and
  signed Date validation. FEP-8fcf follower synchronization remains deferred:
  the FEP itself prohibits deployment unless every managed actor, inbox, and
  shared inbox follows same-authority assumptions that Unfathomably cannot
  impose on all supported installation layouts.
- WordPress-specific REST capabilities, cron scheduling, and plugin database
  migrations are not portable.

## Bonfire

- `3fdab744`, `a9d49cd`, and the accompanying interoperability documentation in
  `e691223` add FEP-844e capability discovery around Bonfire's RFC 9421 work.
  Unfathomably now advertises its tested RFC 9421 implementation through
  spec-shaped Link objects. Inbox responses also request the exact RFC 9421
  POST components the verifier requires, and successful peer negotiation is
  remembered by URI authority for one day. This avoids NodeInfo version guesses
  while allowing subsequent deliveries to use the requested format directly.
- The rest of the application repository's 2026 changes primarily cover
  search, UI, announcements, embeds, and extension upgrades. Unfathomably
  already has bounded ValueFlows Proposal, Intent, offer, need, resource,
  quantity, action, participant, and location presentation.
- Bonfire's internal extension graph and authorization engine are not copied.
  ValueFlows remains an interoperable object vocabulary here, not a second
  application framework or local economic ledger.

## Manyfold

- `85c7362` retains ActivityStreams Link names; Unfathomably's attachment
  validator already preserves `name`, and safe Link attachments feed rich-card
  presentation instead of becoming broken media.
- `6158cd0` and `ed6a53e` reinforce output sanitization and path-safe filenames.
  Existing HTML sanitizers, uploaded-media ownership checks, and quoted
  attachment responses cover these boundaries.
- Manyfold's Rails policy classes, job removal, and local 3D library storage are
  not copied. F3DI concrete type, model files, previews, license, version,
  format, scale, creator, and collection metadata remain supported.

## NeoDB, Flohmarkt, and Wanderer

- NeoDB `53011a7` supplied the implemented JSON-LD type-array normalization.
  `8b7f3a2`, `2093644`, and `eb53ebb` reinforce bounded converted media/Event
  objects, field limits, and idempotent review/comment updates already present.
- Flohmarkt `99bf86a`, `23acfac`, and `651982b` match existing FEP-0837
  Proposal, Intent, location, stable fragment identifier, and marketplace
  delivery support. Its rejection of bare `application/json` is intentionally
  not copied because Unfathomably uses guarded JSON fallback for deployed peers
  that lack precise content types.
- Wanderer `fc73513`, `ec76b69`, and `86cca8e` match stable route identifiers,
  preferred-username-aware actor discovery, and bounded list deduplication.
  Private trail authorization remains remote-system policy and is not inferred
  from a public ActivityPub object.

## Takahē and snac2

- Takahē had no new commits after the baseline. NeoDB's active fork was audited
  rather than inferring changes from an inactive history.
- snac2 `083a338` is already covered by query-aware incoming and outgoing HTTP
  signatures. `45d7d89` matches alias-aware non-acct WebFinger handling, and
  `e21c6ce` matches Unfathomably's explicit-to mention policy.
- snac2 `be54d22` supplied the implemented remote PEM canonicalization.

## Hubzilla and Streams

- Hubzilla `519b52c` reinforces failing closed on unsafe JSON-LD signature
  processing. Unfathomably does not perform arbitrary remote context expansion
  and therefore does not add a permissive fallback.
- Hubzilla `866cd52` matches bounded collection pages, fetch depth, queue
  uniqueness, and host pacing already used for large remote collections.
- Streams `def3c4d` matches existing empty collection handling for replies,
  followers, and following. `ef4e27c` is covered by compatibility Accept/Follow
  handling and Pixelfed smoke tests.
- DID identity equivalence from Streams `9a63c6b` is not inferred from an actor
  field alone. It needs a separately authenticated identity-linking design
  before it can safely affect account aliases or migrations.

## Forgejo experimental monitor

- Forgejo remains monitored rather than declared production-compatible while
  its federation surface is experimental and may change incompatibly.
- `540551a`, `da8d5a8`, and `169ea1d` reinforce public-address SSRF checks,
  redirect revalidation, and public-only unauthenticated activity delivery.
  Existing HTTP safety and visibility boundaries already apply to ForgeFed
  object discovery.
- Forgejo's repository persistence, Actions, Git transport, and Gitea-specific
  permission model are not transplanted. Unfathomably continues to present
  Project, Repository, Ticket, issue, and development activity as federated
  social objects rather than pretending to be a forge.

## Next review

Resume each project strictly after the head recorded in the scope table. When
a short cursor is shown, resolve it in that project's official repository
before reviewing descendants.

<!-- end of docs/UPSTREAM_FEDERATION_ECOSYSTEM_AUDIT_2026.md -->
