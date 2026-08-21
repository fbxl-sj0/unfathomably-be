# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
### Added
- Added private native-object workspace state for books, culture, audio, video,
  live streams, events, software projects, 3D models, marketplace listings,
  games, routes, and coordination records. Users can keep bounded progress,
  ratings, notes, and family-specific workflow state without publishing an
  extra status or notifying followers.
- Added OAuth-scoped workspace state APIs and optional public Worlds
  participation. Public profile queries expose only records a user explicitly
  marks public and never return their private notes; profile participation
  counts now include those opted-in records.

### Fixed
- Reconciled required native Nostr profile-recovery and community-discovery
  schedules after ConfigDB loading so stale Oban overrides cannot silently
  disable newly added maintenance workers.
- Fixed first-contact native Nostr replies that directly tag a local identity
  so their signed events are accepted and their authors enter the normal
  profile hydration path without broadening relay subscriptions into a
  firehose.
- Classified private-network remote fetch failures as terminal SSRF rejections
  immediately and taught the Oban janitor to retire historical retries.
- Fixed native Nostr contact hydration when kind-0 metadata was stored before
  its mirror account existed, and made blank `display_name` values fall back to
  useful profile names instead of rendering an empty account name.
- Reworked unhydrated Nostr profile recovery with batched relay lookups and
  durable 10-minute, hourly, six-hour, then daily retry backoff, allowing
  recently propagated contact metadata to appear without flooding public
  relays or waiting a full day after the first lookup miss, and moved the sweep
  to an independent Oban worker so per-profile uniqueness cannot suppress it.
- Moved optional NIP-05 proof lookups into stale-safe background jobs so dead
  well-known endpoints cannot delay names, biographies, and avatars, while
  continuing to hide every human-readable identifier until it verifies.
- Fixed imported QuoteAuthorization records that could remain pending forever
  by verifying authorization documents on first receipt and gradually
  recovering older stranded records with bounded, per-host janitor pacing,
  while retaining visibility-based compatibility for legacy servers that do
  not publish interaction policies.
- Enforced the group-cleanup query budget inside PostgreSQL while allowing a
  separate bounded pool-checkout window, so expected cold-scan cancellation no
  longer tears down healthy database connections during live traffic.
- Closed a cleanup-worker startup race with a shared non-blocking runtime lock,
  so overlapping group and orphan/cache janitors reschedule before checking out
  PostgreSQL connections instead of timing out under live page traffic.
- Stopped group detail and lookup responses from synchronously recounting every
  locally cached top-level post, keeping cold group pages responsive while
  preserving cached status totals and targeted member/moderator refreshes.
- Bounded stale group-discussion cleanup by a wall-clock work budget, made it
  coordinate symmetrically with orphan-activity cleanup, capped cold candidate
  queries, and continued unfinished scans with adaptive pacing so maintenance
  cannot starve live timeline requests on large federation databases.
- Raised the bounded media-proxy streaming ceiling from 25 MiB to 64 MiB so
  valid remote videos from modern federated servers remain playable without
  removing response-size or read-time safeguards.
- Prevented sustained orphan-activity backlog cleanup from starving live API
  and federation requests by pacing continuation jobs according to the measured
  database cost of each cleanup page.
- Fixed reply-policy traversal at its depth boundary so a legitimate cached
  root at depth 64 is inspected instead of being misclassified as a locked
  thread, while deeper or cyclic ancestry continues to fail closed.
- Preserved bounded BookWyrm series names and positions through received book
  context, catalog-seeded reviews, and locally published book objects, so work
  and edition relationships remain meaningful instead of being reduced to a
  title and publisher string.

### Fixed

- Improved Worlds discovery hydration by matching a bounded set of nested
  book, media, event, project, and resource references to their existing local
  status records, so specialized entries can reuse ordinary post interactions
  without treating arbitrary nested metadata as a status.
- Prevented blank search requests from reaching the database or external search
  backend, avoiding needless empty discovery work.
- Included translated status content warnings in Mastodon translation responses
  while preserving the original warning if the optional second translation
  request cannot be completed.
- Fixed Nostr responder identity hydration by immediately scheduling signed
  profile metadata backfills for newly projected authors and periodically
  retrying a bounded set of legacy placeholders across native and response
  relays, with a durable one-day retry cooldown for identities whose relays
  publish no kind-0 profile event.
- Fixed Nostr response ingestion for local posts by subscribing approved relays
  to events tagging local actor keys, admitting unknown responders only when
  their signed event references an exported local event, and adding a bounded
  response-relay pool so replies and reactions published through Snort, nos.lol,
  or Damus are recovered after reconnects without importing a public firehose.
- Delayed Create-activity WebSocket broadcasts until after their database
  transaction commits, preventing newly ingested Nostr posts from briefly
  appearing as actor-name-only placeholders in live timelines.
- Re-streamed Nostr projections after late thread-parent or group-address
  repair so open timelines adopt the corrected reply and group context without
  requiring a browser reload.
- Made the retention janitor self-heal after transient database timeouts and
  added a compact local-activity reference index so preserving local replies,
  reactions, and other interactions does not repeatedly probe the global
  multi-gigabyte activity index during historical cleanup; protection checks
  now stop after the first matching local reference instead of materializing
  every activity attached to a frequently referenced object. A compact,
  transactionally maintained local-reference catalog now keeps those safety
  checks fast on cold databases and is rechecked by the final delete.
- Tuned per-table and TOAST autovacuum thresholds for the large activities and
  objects caches so bounded retention work continuously makes deleted space
  reusable instead of waiting for PostgreSQL's impractical default 20 percent
  dead-row threshold.
- Added janitor backpressure while PostgreSQL vacuums either large cache table,
  allowing page reuse and statistics maintenance to finish without competing
  with user requests for database connections and storage I/O; the probe uses
  PostgreSQL's maintenance lock visible to the restricted application role and
  yields conservatively when database load prevents a definitive answer.
- Added a bounded, unique continuation lane for old remote objects, Tombstones,
  and stale actors so retention backlogs converge without waiting for one small
  hourly batch, while yielding to both the orphan-activity sweep and PostgreSQL
  maintenance.
- Fixed the hourly root retention job so it also defers old-object, Tombstone,
  and stale-actor scans while an orphan-activity sweep is active, preventing
  retrying root jobs from holding database connections until their worker
  timeout while the bounded continuation lane was making progress.
- Reworked remote-cache retention into a self-healing janitor: newly pruned
  objects now shed safely detachable remote activity envelopes, historical
  orphans are removed in restart-safe bounded batches with persistent progress,
  local bookmarks, notifications, reports, replies, quotes, and interactions
  remain protected, and old remote Tombstones expire on a longer safety window.
- Increased recurring remote-post cleanup throughput and cadence, added compact
  cursor indexes for orphan activities and Tombstones, and retained periodic
  full sweeps so one-time cleanup gaps cannot silently regrow indefinitely;
  orphan cleanup runs before expensive object-protection checks so a slow
  remote-cache query cannot starve the bounded recovery lane, and local
  reply/quote/activity protection is resolved once per indexed candidate set
  rather than repeated as a correlated scan for every historical row. Added
  the missing `quoteUri` lookup index so both quote field spellings retain the
  same protection without a full object-table scan, and kept cleanup pages
  deliberately small so cold multi-year databases self-throttle instead of
  monopolizing a database connection.
- Added the Mastodon-compatible `/api/v1/trends/statuses` fallback so clients
  receive an empty collection instead of a route-level 404 until a
  moderation-safe trending-status ranker is explicitly enabled.
- Fixed authenticated ActivityPub inbox jobs so they use the configured
  ReceiverWorker timeout instead of carrying a stale 20-second per-job
  override that could abort valid slow federation deliveries.
- Fixed static status metadata rendering for older objects with an unspecified
  sensitive flag, so valid public notice pages render previews instead of
  returning HTTP 500.
- Prevented inline ActivityPub reply collection maps from being enumerated as
  key/value tuples and inserted as malformed remote-fetch jobs.
- Improved remote-cache janitor resilience by splitting candidate queries that
  exceed their database timeout, allowing smaller safe slices to continue
  instead of abandoning the full daily cleanup pass.
- Added an ordered partial index for stale remote-actor cleanup so the janitor
  no longer sorts and spills tens of millions of temporary blocks while
  selecting its small bounded actor batch.
- Requeued missing remote quote objects when a status is rendered, so a
  previously missed or discarded quote hydration job can repair the embedded
  quote asynchronously without blocking status requests or bypassing quote
  visibility checks.
- Treated empty quote-authorization state from older or foreign ActivityPub
  implementations as ordinary public quote behavior instead of hiding the
  quote as rejected.
- Extended the Oban janitor's persistent-error boundary to incoming
  federation jobs, so repeated remote HTTP 5xx responses from peers such as
  Lemmy and snac receive the same bounded retry treatment as outbound
  deliveries instead of consuming the full retry budget indefinitely.
- Added a compiled-application artifact check to source promotion so a
  missing `pleroma.app` stops activation before systemd can enter a restart
  loop.
- Reduced source-promotion backup scope so historical backup trees, build and
  dependency caches, uploads, and server-local instance state are not copied
  into every new rollback archive.
- Restored the shipped Pleroma fallback avatar and header assets so legacy
  `/images/avi.png` and `/images/banner.png` account URLs resolve instead of
  producing browser 404s when the frontend receives them from an API payload.
- Added the Mastodon v2 `configuration.urls.streaming` field while retaining
  the existing top-level streaming URL alias, allowing current frontends to
  discover authenticated WebSocket streaming without v1 fallback assumptions.

### Security

- Audited all 47 published Mastodon CVEs and Pleroma CVE-2023-5588 against
  Unfathomably's corresponding code paths, with source-level dispositions and
  regression evidence in `docs/SECURITY_CVE_AUDIT_2023_2026.md`.
- Hardened ActivityPub, FASP, WebFinger, rich-media, and reverse-proxy requests
  against SSRF by validating all resolved addresses, rejecting special IPv4
  and IPv6 transition ranges, and pinning connections while retaining TLS
  hostname checks.
- Hardened OAuth and streaming lifecycles so expired or deleted tokens,
  destroyed applications, password resets, and inactive users cannot retain a
  live stream, and applied anonymous-federation restrictions to hashtag streams.
- Prevented LDAP options from disabling TLS verification, bounded remote polls
  and local lists, added destination confirmation throttling, and rejected
  percent-routed email addresses.
- Added a signed-release FFmpeg installer for CVE-2026-8461 so deployments can
  use fixed FFmpeg 6.1.6 while affected distribution packages remain pending.

### Added

- Advertised explicit `native_federation` and `quote_post_listing` instance
  capabilities so compatible frontends can expose specialized workflows and
  quote listings without guessing from the backend software name.
- Added a release-gated selective-protocol smoke contract covering AT Protocol,
  Nostr, Diaspora, dedicated Tor onion routing, and the corresponding frontend
  account-linking and protocol-identity presentation.
- Updated the federation smoke suite to derive its Elixir image from the
  repository's OTP 29 toolchain, rebuild stale labelled images, honor both
  supported image overrides consistently, verify BE/FE version alignment, and
  install the JSON and Python tooling required by current adapters.
- Added a consolidated optional-feature enablement guide covering AT Protocol
  and Bluesky account linking, Nostr identity and relay setup, Diaspora routes,
  Tor client-only fetching and hidden-service entrances, Worlds discovery,
  RSS sources, translation, Meilisearch, VAPID web push, FASP approvals, secret
  handling, reverse-proxy requirements, and operational verification.
- Replaced the legacy global Tor proxy and CSP-disable instructions with a
  fail-closed client-only onion adapter procedure and a separate, non-relay
  hidden-service entrance guide.
- Added opt-in Tor v3 onion-service federation through a loopback-only SOCKS5
  client, with address checksum validation, isolated bounded HTTP capacity, and
  fail-closed handling that prevents onion names from leaking to ordinary DNS.

### Fixed
- Restored live local media after an ad hoc source deployment deleted the upload
  tree, moved uploads outside the application checkout, and strengthened the
  supported source-promotion path with independent rsync receiver protection.
- Fixed extension-neutral local media such as legacy `.blob` avatars so safe
  image, audio, and video signatures receive their real MIME type while unsafe
  content remains sandboxed as generic binary data.
- Added a permanent `/favicon.ico` compatibility redirect to the configured
  PNG favicon so conventional browser and crawler requests no longer receive
  the frontend application shell.

- Documented the frontend streaming repair: initial WebSocket upgrade failures
  now fall back to authenticated EventSource delivery, while top-of-list
  timelines reconcile without requiring a manual refresh.
- Fixed media-proxy failure caching so stale URL-only and failed HEAD entries
  cannot suppress healthy GET or ranged media requests, and made failed
  thumbnail generation fall back to the full proxied media instead of showing
  an unavailable placeholder for healthy remote avatars. Temporary image
  failure placeholders are now non-cacheable so an edge proxy cannot retain
  one as an account's avatar after the remote image recovers, with matching
  no-cache guards in the maintained nginx media-proxy examples.
- Fixed outbound HTTP authority handling after public-address pinning so Gun
  connects to the validated address while retaining the URI hostname for
  HTTP/1 `Host` and HTTP/2 `:authority`, preventing widespread `421 Misdirected
  Request` responses, missing avatars, and failed federation fetches on shared
  CDNs.
- Fixed StaticFE rendering for cached posts whose remote author cannot be
  resolved, using a minimal remote-author placeholder instead of returning an
  HTTP 500 for the entire notice thread.
- Recovered stale frontend sessions whose older Vite preload runtime requested
  nested `/packs/js/packs/js/` or `/packs/js/packs/assets/` paths, allowing the
  existing content-hashed asset to load instead of triggering navigation errors.
- Fixed WebFinger discovery for actor URLs with bracketed IPv6 hosts and
  non-default ports by encoding IPv6 brackets safely inside resource queries.
- Added a strict release-engineering gate covering dependency advisories and
  freshness, warning-free compilation, formatting, strict Credo, isolated
  test batches, documentation warnings, and security regression checks.
- Made ExDoc generation warning-clean by fixing malformed local markup, giving
  the README a stable documentation route, and explicitly baselining only
  legacy deployed-guide and private/external API references.
- Stopped the configuration documentation task from booting the database and
  background workers, and made strict documentation builds clear stale output
  before rendering so old page-name collisions cannot poison a release gate.
- Updated test configuration helpers and call sites to use unambiguous per-key
  section overrides instead of the deprecated whole-section keyword form.
- Made the isolated release test matrix resumable from an exact numbered batch
  without changing its deterministic file ordering or default full-suite run.
- Fixed event-capacity API handling so full events return a useful client error
  for both direct joins and participation approvals instead of a generic error
  or controller exception.
- Hardened post-archive imports by rejecting unsafe ZIP paths before extraction
  can silently skip them and incorrectly mark the import complete.
- Preserved bounded standard oEmbed cache, version, media, and thumbnail
  dimensions, including numeric strings emitted by otherwise compatible media
  providers, while continuing to discard unknown nested metadata.
- Documented unauthenticated account-credential and alias failures as 401
  responses in OpenAPI so generated clients match the hardened OAuth pipeline.
- Made test teardown drain late-registered streamer workers before SQL sandbox
  ownership ends, removing orphaned renderer queries and database disconnect
  noise without changing streaming concurrency.
- Fixed ActivityPub advisory-lock queries that nested repository timeout
  options, and fixed outbox next-page links that were calculated from the
  rendered collection's reversed order and could repeat the first page.
- Fixed Ed25519 verification for legacy and RFC 9421-style HTTP signatures by
  passing the signed message and signature to OTP crypto in the required order.
- Normalized pinned-status timestamps before storing them in JSON-backed user
  maps so fresh writes and reloaded users expose the same stable string type.

- Fixed known remote-handle resolution so cached actors are used before an
  alias lookup or new WebFinger request, keeping mentions functional while a
  previously discovered peer is unavailable.
- Made `mix pleroma.user rm` distinguish a missing local account from a
  downstream delete-pipeline failure so operators receive an actionable error.
- Made the backend release gate run explicit test-file batches serially because
  the suite exercises shared Application configuration and process-wide caches,
  removing parallel state failures while bounding compiled-test memory.
- Strengthened the backend release gate with locked and unused dependency
  checks, vendored dependency security auditing, warning-free compilation,
  formatting, high-signal Credo checks, the full test suite, and strict ExDoc
  generation.
- Added regression coverage proving the vendored Gun and cowlib request-header,
  structured-header, and cookie injection protections covered by narrowly
  documented advisory exceptions.
- Fixed stale test assumptions around capability configuration, MRF defaults,
  push truncation, compile-time module requirements, and Oban test helpers.
- Fixed the ExDoc output collision with its reserved search page and completed
  structured logger metadata for memory and AT Protocol bridge events.
- Fixed local group Announce retries so they use the existing deterministic
  activity ID derivation instead of producing parallel federation activities.
- Restored the Mastodon v2 instance `urls` object at its required top-level
  location instead of nesting it inside `configuration`.
- Split anonymous local and federated timeline and streaming capabilities from
  the broad native-federation flag so clients follow the effective access
  policy instead of assuming that every Unfathomably instance is public.
- Fixed instance metadata to report the deployed Unfathomably FE 3.5.0 release
  instead of the stale 3.4.0 frontend version.
- Hardened frontend fallback routing so PHP, CGI, and other executable
  web-shell probes return a real 404 instead of receiving the single-page app
  shell, including nested script paths and common WordPress probe roots.
- Made Nostr mirror provisioning conflict-safe when concurrent relay events
  discover the same actor, preventing a harmless database race from retrying
  an otherwise successful ingest job.
- Scoped reverse-proxy failure caching by HTTP method so a transient failed
  media `HEAD` probe cannot suppress a valid video `GET`, and added a short
  cooldown for repeatedly failing optional actor collections.
- Fixed Lemmy-style link posts whose ActivityPub `Link` destination is nested
  under an attachment `url` array, rendering them as link-preview cards with
  their title and image instead of unknown HTML media downloads.
- Fixed Nostr projection interoperability observed in Snort: media URLs now
  accompany NIP-92 `imeta`, replies to kind-1 notes use marked NIP-10 tags,
  ActivityPub-only reply targets use NIP-22 external scopes, and nested NIP-22
  replies preserve their original root scope.
- Fixed public Nostr replies, reactions, reposts, and deletes so recipient
  relays remain preferred while configured public relays provide durable
  fallback delivery when a selective relay declines or later drops an event.
- Fixed Nostr exports of locally authored plain-text and Markdown posts so
  source whitespace around mentions and links is preserved instead of being
  reconstructed from rendered ActivityPub HTML.
- Fixed linked AT Protocol publishing after access-token expiry by sending the
  no-input `com.atproto.server.refreshSession` procedure without an empty JSON
  request body, which standards-compliant PDS implementations reject.
- Fixed native AT Protocol publishing to use deterministic, lexicon-valid TID
  record keys instead of prefixed hash keys rejected by compliant PDS
  implementations for posts, follows, reactions, and reposts.
- Fixed ordinary local status creation to enqueue AT Protocol and Diaspora
  exporters after commit, matching the existing common ActivityPub pipeline
  instead of silently queuing only Nostr publication.
- Fixed AT Protocol reaction export by mapping local emoji reactions to
  Bluesky Likes and securely recovering aged-out strong references from
  embedded ATProto provenance only when the post DID matches its projection.
- Fixed selective AT Protocol publishing so explicitly addressed Bluesky
  projection accounts become native mention facets even when the stored local
  object predates outgoing Mention-tag reconstruction, while preserving the
  authored plain-text spacing around formatter-generated mention markup.
- Kept Oban janitor uniqueness effective for suspended jobs and removed an
  unused native-discovery function default so current Elixir and Oban builds
  remain warning-clean in Unfathomably-owned source.

## [3.5.0] - 2026-08-12

### Added

- Added a bounded local-user Nostr bootstrap task that repairs missing profiles, NIP-65 relay lists, and a small sample of existing public posts without creating ActivityPub activities or exporting private content.
- Added durable BookWyrm-style reading lifecycle tracking to personal book
  shelves, including started and finished dates exposed through the book shelf
  API.
- Added public account Worlds participation and book-shelf endpoints so clients
  can show only the specialized profile tabs an account actually uses.
- Added on-demand local AT Protocol identity provisioning with standards-valid
  handles below `social.fbxl.net`, encrypted publishing sessions, and a bounded
  PDS deployment that stores only opted-in local repositories. Remote Bluesky
  reads remain selective and no relay, AppView, or full-network mirror is run.
- Advertised FEP-3b86 Follow and Create activity intents through WebFinger so
  compatible clients can open the existing remote-interaction and share
  workflows instead of requiring manual actor or object URL copying.
- Advertised tested RFC 9421 HTTP Message Signature support on local actors and
  the instance service actor through FEP-844e capability discovery.
- Added PieFed-compatible `/activitypub/externalInteraction` handling and
  advertised `web+ap:` support through the generated browser manifest, while
  recording remote `410 Gone` responses so future federation deliveries stop
  targeting deliberately retired servers.
- Marked machine-facing API and ActivityPub responses with `X-Robots-Tag:
  noindex` so search engines prefer human-facing profile and status pages over
  duplicate JSON endpoints.
- Advertised the instance ActivityPub `Application` actor from
  `/.well-known/nodeinfo` using the FEP-2677 relation so compatible event and
  relay software can discover the existing service actor without a hard-coded
  path.
- Added Mastodon-compatible About, Privacy Policy, and Terms URL fields to the
  v2 instance API, advertising only destinations the installation actually
  serves.
- Added Manyfold-compatible object-level `indexable` and `discoverable` hints
  for public locally authored 3D models while explicitly opting quieter models
  out of catalogue discovery.
- Added validated catalogue actions for received BookWyrm books, including
  Open Library, Inventaire, Finna, LibraryThing, Goodreads, Wikidata, VIAF,
  and BnF identifiers without making remote catalogue requests at render time.
- Preferred JRD JSON for outgoing WebFinger requests while retaining JSON and
  lower-priority XRD XML compatibility for legacy servers.
- Added bounded FEP-f228 reply discovery through same-origin `contextHistory`
  collections so compatible Mitra conversations can expose remote replies.
- Added OAuth 2.0 PKCE support for authorization-code grants, including bounded
  `plain` and `S256` challenges that survive login and MFA and are checked
  before one-time codes are consumed.
- Added support for GoToSocial's unauthenticated-web visibility actor hints so
  remote public and quiet-public profile posts honor explicit privacy choices
  before pagination without changing authenticated timelines.
- Added FEP-c180 Problem Details responses for ActivityPub endpoint errors while
  preserving structured metadata and `410 Gone` Tombstone representations.
- Centralized security-sensitive URL-safe token generation behind named,
  allocation-bounded entropy levels and migrated OAuth, password-reset,
  confirmation, invitation, and archive identifiers to the shared policy.
- Added a hybrid authorized-fetch mode that exposes only local actor keys and
  delivery routes to unsigned requests, allowing peers to bootstrap signed
  federation without exposing profile data, posts, or collections.
- Hardened OpenGraph and Twitter-card privacy for sensitive posts so external
  unfurlers receive only the sanitized content warning, or a neutral fallback,
  unless the operator explicitly enables NSFW unfurls.
- Added a reproducible patch-level audit ledger for the 2025 commit history of
  platforms in the wide federation matrix, plus the official Nostr NIPs,
  recording reviewed candidates, implemented lessons, explicit no-change
  dispositions, and remaining coverage in
  `docs/UPSTREAM_FEDERATION_ECOSYSTEM_AUDIT_2025.md`.
- Added bounded native metadata for BookWyrm `Series` and `SeriesBook`,
  Funkwhale `Playlist` and `PlaylistTrack`, and ActivityPods/Solid Shape Tree
  relationships so these 2025 ecosystem additions remain discoverable and
  presentable without retaining unbounded remote structures.
- Added standards-shaped RFC 9421 `Accept-Signature` negotiation for
  ActivityPub inboxes, including exact body-digest coverage and a bounded
  per-authority preference cache so cooperating peers can use the modern
  signature format directly on later deliveries.
- Added a complete 2026 commit audit across Mobilizon, Fedify, Ghost
  ActivityPub, BookWyrm, WordPress ActivityPub, Bonfire, Manyfold, NeoDB,
  Flohmarkt, Wanderer, Takahē, snac2, Hubzilla, Streams, and experimental
  Forgejo federation, with explicit upstream cursors and dispositions.
- Advertised tested RFC 9421 HTTP Message Signature support through FEP-844e
  Link capabilities on local actor generators and service actors, improving
  format discovery without relying on software-version guesses.
- Added a focused audit of GoToSocial's 2026 changes, with an explicit
  upstream cursor and dispositions for interaction authorization, remote poll,
  backfill surfacing, relay, media, and federation error-handling lessons.
- Added a focused audit of NodeBB's 2026 changes, with an explicit upstream
  cursor and dispositions for portable ActivityPub, security, retention, and
  pagination lessons.
- Added an opt-in, server-side FediBuzz discovery connector that consumes the
  public event stream, accepts only posts matching locally followed actors or
  hashtags, and routes canonical objects through the normal ActivityPub fetch,
  validation, visibility, blocking, and MRF pipeline.
- Added the publisher half of FEP-2345 `fediverse:creator` attribution for
  local status pages, including local actor `attributionDomains` authorization
  so compatible link-preview consumers can verify the claimed creator.
- Added fast Mastodon-compatible `/context/ancestors` and
  `/context/descendants` status endpoints with bounded ascending keyset
  pagination, visibility filtering, continuation Link headers, and no
  synchronous remote-reply fetch.
- Added bounded, signature-checked discovery for active NIP-29 relay groups and
  NIP-72 moderated communities, including moderator approval verification and
  safe projection of approved embedded posts.
- Added an activity-ranked Nostr community catalogue that records recent post
  counts, distinct authors, and last activity instead of treating historical
  membership totals as evidence that a group is alive.
- Added server-side NIP-17 private chats using NIP-44 encryption and NIP-59
  gift wraps, including bounded private-message relay discovery, local sent
  copies, missed-message subscriptions, safe projection into normal chat
  activities, and explicit refusal to expose unencrypted chat attachments.
- Added NIP-38 live profile statuses and NIP-58 profile badges to the native
  Nostr bridge. Public ActivityPub Listen activities now publish expiring music
  statuses, remote status and user-selected badge references appear as bounded
  account presentation data, local visible `badge:` tags publish portable badge
  definitions and selections, and remote awards never confer local roles,
  verification, or moderation authority.
- Added safe NIP-21 and NIP-27 reference interoperability so known Nostr
  profiles and events become usable local links on inbound posts, explicit
  ActivityPub mentions become portable `nostr:nprofile` references with
  matching `p` tags, mapped post links become `nostr:nevent` references, and
  private-key `nsec` identifiers remain excluded.
- Added bounded NIP-52 calendar-event and NIP-53 live-activity translation to
  the server-side Nostr bridge. Scheduled and live entries now use native
  ActivityPub Event rendering, including times, locations, banners, stream and
  recording links, accepted RSVP joins, and threaded live-chat projections,
  while unsupported meeting-space presence remains outside the advertised
  bridge behavior.
- Added bounded NIP-51 public simple-group lists, NIP-56 report translation,
  and NIP-88 polls and votes to the server-side Nostr bridge. Group membership
  changes now refresh portable relay-aware lists, locally actionable reports
  reuse the normal moderation queue without automatic enforcement, and poll
  interoperability reuses the existing ActivityPub poll limits and vote path.
- Added end-to-end Nostr compatibility for content warnings, event expiration,
  protected-event redistribution boundaries, external content identifiers, and
  outbound media metadata, and now accurately advertise the existing thread,
  long-form, custom-emoji, and external-identity behavior through NIP-11.
- Added NIP-19, NIP-24, NIP-30, NIP-39, and NIP-65 profile parity to the
  server-side Nostr bridge: local ActivityPub profile edits now publish
  portable relay-aware identities, birthdays, bot state, websites, Lightning
  addresses, and custom emoji immediately, while verified incoming events
  populate ordinary account presentation without fabricating identity-proof
  verification.
- Added a complete beginner-oriented epic, story, and acceptance catalogue for
  all 16 Worlds families, including explicit knowledge boundaries, safe source
  handoffs, non-mutating browser evidence, and implementation ownership across
  the frontend and backend.
- Added bounded, server-brokered NeoDB catalogue lookup for Culture authoring so
  users can select a federatable cultural work without contacting remote
  providers directly from the browser.
- Added authenticated Worlds object authoring for books, software tickets,
  3D models, marketplace offers, games, routes, culture, coordination, and
  publishing through fixed server-side ActivityPub templates. Locally authored
  resource and process objects can participate in the Worlds timeline without
  allowing remote objects to opt themselves into ordinary timelines.

### Changed

- Reduced federation delivery-health write pressure by persisting successful
  inbox health only when a host or endpoint actually transitions to healthy,
  while retaining first-success, recovery, and new-endpoint observations.
- Extended untouched remote-group discussion retention to two years when a
  local user follows the group, while preserving the shorter configurable
  cleanup horizon for incidental, unfollowed group traffic.
- Moved uncached quote hydration out of incoming federation requests and into
  the deduplicated remote-fetch queue, retaining the normalized quote URL while
  the original object is unavailable and reconciling quote authorization and
  counters after hydration.
- Added bounded automated-source pacing for RSS refreshes and FediBuzz
  discovery, including per-source reservations, a global discovery budget,
  and per-remote-host fetch spacing.
- Updated the remaining compatible direct dependency lines, including Oban,
  Tesla, ExMachina, libsecp256k1, and mdex_native, while retaining only
  constraints required by the current HTTP/3 and WebTransport stack.

### Fixed

- Added security-bounded HTML canonical discovery for remote object actions so
  Lemmy-family reactions referencing alternate frontends resolve to the real
  ActivityPub object, retain canonical interaction state, and still pass the
  normal URL, MRF, containment, origin, and object-validation checks.
- Fixed verified incoming ActivityPub deliveries carrying preserved HTTP
  headers being mistaken for legacy failed-signature retries and cancelled;
  legacy retry detection now requires the complete saved request envelope.
- Implemented finalized ActivityPub FEP gaps for structural quoted-object
  Links, safe RSA Multikey actor publication, deployment-gated signed follower
  collection synchronization, and owner-confirmed appendable wall collections.
- Added a concurrent partial index for confirmed appendable collection
  memberships so empty and populated walls stay responsive on large object
  tables without indexing unconfirmed remote target claims.
- Fixed unsigned follower-synchronization and unavailable appendable-collection
  requests so they return normal not-found responses instead of violating the
  Phoenix controller contract and producing HTTP 500.
- Preserved the Ibis Delete compatibility fallback because peers do not yet
  advertise an equivalent protocol capability; presentation-only platform
  classification remains separate from federation wire behavior.
- Fixed the shared `/relay` endpoint so ActivityPub actor requests reach an
  `Application` relay actor while Nostr WebSocket and NIP-11 requests retain
  their existing behavior, and normalized other internal service actors away
  from the user schema's `Person` default.
- Added finalized FEP-d556 server-actor discovery for exact server-prefix
  WebFinger requests and a FEP-67ff root federation capability manifest.
- Audited every currently finalized FEP, documenting complete, partial, and
  deferred support plus the prioritized interoperability roadmap.
- Completed FEP-7aa9 actor-feature consent by accepting directly signed
  actorless `FeatureRequest` activities, persisting idempotent collection
  authorizations, returning dereferenceable authorization documents, and
  rejecting requests when the local actor is not discoverable.
- Fixed the inbox guard activity allowlist so supported `QuoteRequest`
  activities reach the existing quote-consent pipeline instead of being
  acknowledged as unknown federation traffic.
- Audited 960 commits across the 47-target federation matrix for the seven-day
  window ending 2026-08-12, recording portable lessons and explicit
  already-covered or non-portable dispositions.
- Replaced OTP's Linux system-memory alarm, which treated reclaimable page
  cache as unavailable, with a supervised available-memory monitor whose
  configurable set and clear thresholds use hysteresis to report real pressure
  without producing a false alarm after every application start.
- Added a partial local-activity context index so conservative remote-post
  cleanup can preserve locally touched threads without repeatedly scanning the
  full federation activity table or exhausting its database checkout timeout.
- Kept valid signed Nostr text events with empty, non-media bodies in the
  native event store without repeatedly attempting an impossible ActivityPub
  status projection during profile backfills.
- Added public WebSocket fanout for `Listen` activities, including remote,
  hashtag, and media topics, so Funkwhale-style listening entries can update
  live Worlds and media views without a reload.
- Classified ActivityPub object and collection containment mismatches with
  explicit terminal reasons so deterministic identity and origin failures no
  longer retry as opaque remote-fetch errors.
- Added standards-compliant AT Protocol OAuth account linking with PKCE, PAR,
  DPoP, one-use bounded state, protected-resource and issuer rebinding, encrypted
  session secrets, and least-privilege repository and blob permissions while
  retaining app passwords as a fallback.
- Added bounded AT Protocol image and video blob uploads for explicitly
  published local attachments, with content and size validation, fallback
  links for unsupported media, and no relay or firehose ingestion.
- Hardened native AT Protocol identity resolution with DID-document binding,
  bidirectional handle verification, typed origin-only PDS discovery, strict
  blessed DID/NSID/record-key/AT-URI validation, bounded identity caching, and
  IPv4-mapped IPv6, transition-address, path-based did:web, and future-time
  rejection.
- Made selective Bluesky ingestion resilient to malformed records without
  abandoning a whole author feed, preserved retryable AppView failures,
  refreshed changed projections by CID, removed confirmed deleted projections,
  kept durable retention source/local state from being downgraded, and selected
  reassigned handles deterministically.
- Made outbound AT repository writes idempotent with deterministic record keys
  and putRecord, synchronized edits and mapping cleanup after deletes, retried
  XRPC 400 ExpiredToken/InvalidToken sessions while keeping refreshed sessions
  bound to the original DID, and stopped replies with no native parent from
  being misrepresented as unrelated root posts.
- Added standards-correct Bluesky URL and hashtag facets, boundary-safe mention
  rewriting, and ASCII-stable Unicode mention-boundary handling.
- Treated DIDs rather than mutable handles as the durable identity of linked AT
  Protocol accounts, while retaining indexed handle lookup and deterministic
  Bridgy identity-field precedence.
- Kept Diaspora and ActivityPub visibility boundaries aligned by rejecting
  non-public status messages on the public Diaspora endpoint, declining
  encrypted aspect-scoped posts until their audience can be represented
  locally, and preventing non-public ActivityPub posts from entering the
  public Diaspora publisher.
- Completed the native Diaspora bridge with actor- and root-aware delivery,
  independently retryable per-pod jobs, retryable encrypted contact delivery,
  bounded hCard key-rotation recovery, public profile synchronization, safe
  profile media handling, and no-destination record suppression.
- Replaced the web-of-trust-gated Nostr relay after it rejected otherwise valid new local identities, and added a metadata refresh mode so relay-policy changes can be announced for existing users without replaying their posts.
- Fixed Nostr profile bootstrap after relay-policy changes so a new NIP-65 relay list is fanned out to every configured discovery relay rather than only the newly added relay.
- Exported ordinary public local posts as Nostr kind-1 notes while preserving
  direct, followers-only, local-only, chat, and explicit opt-out boundaries.
- Replaced fire-and-forget Nostr WebSocket publication with one durable,
  acknowledgement-aware Oban delivery per event and relay, including bounded
  retry for temporary relay failures and terminal policy rejection handling.
- Fixed NIP-29 group event delivery so group-tagged events use configured group
  relays instead of being confined to the local relay.
- Fixed local NIP-65 relay-list events so they advertise the external relays
  where local actor events are actually published, and added conservative
  public relay.nostr.com, nostr.mom, and Primal relay defaults.
- Unified reply ancestry for ActivityPub, Nostr, ATProto, and diaspora* so
  bridge-projected comments receive the normal replied-to display and complete
  thread contexts, including NIP-22 parent tags and parents projected after
  their replies.
- Made native discovery and Meilisearch authorize the activities they return,
  preventing a matching identifier or search hit from bypassing the final
  per-user visibility decision.
- Added stable current-status and exact-revision identities to native discovery,
  selected canonical Create envelopes deterministically, and deduplicated
  repeated object envelopes from status contexts, including duplicate roots.
- Balanced merged Worlds discovery pages across distinct actors, channels, and
  source hosts, exposed bounded language/participant metadata, and honored an
  explicit preferred discovery language without displacing chronological
  relevance within each class.
- Bounded each Oban janitor mutation batch, prevented overlapping hourly cleanup
  cycles, limited historical duplicate repair work, and logged one semantic
  cleanup summary when a cycle changes rows or encounters a failed step.
- Normalized native book comments around their canonical book URL through both
  BookWyrm's `inReplyToBook` relationship and ordinary ActivityPub
  `inReplyTo`/`context`, while keeping reviews as independent posts.
- Accepted remote object updates from actors retained in both the stored and
  incoming multi-valued ownership sets, supporting PeerTube account/channel
  video ownership without allowing an incoming update to claim a new owner.
- Reported attempts to update deleted ActivityPub objects as Tombstone
  resurrection attempts instead of misleading actor-ownership failures.
- Stopped retrying local relay wrapping for public activities other than
  `Create`, which the relay actor intentionally does not implement.
- Preserved Bluesky facet mentions and signed Nostr `p`-tag account references
  as ordinary linked ActivityPub mentions, displayed them with recognizable
  native handles, and added bounded repair paths for existing projections.
- Classified locally hosted Nostr, ATProto, and diaspora* projections as
  remote in local timelines and admin account filters, including a migration
  that repairs existing projected activities.
- Clarified remote collection diagnostics so transport failures are no longer
  mislabeled as JSON decoding failures, preserving useful federation signal.
- Fixed authenticated WebSocket crashes when legacy or malformed streamed
  activities have no actor URI by safely filtering those activities.
- Fixed Mastodon poll updates whose plain-text option labels contain Unicode
  emoji, while continuing to reject actual HTML markup in poll choices.
- Collapsed synchronized ActivityPub outbox-root count requests through a
  short visibility-aware cache so discovery bursts cannot exhaust the database
  pool while collection pages remain exact and uncached.
- Fixed outbound HTTP 5xx delivery handling to record host failure backoff, so
  a failed peer snoozes queued fanout instead of making every delivery probe it.
- Added a validated native-family filter to account status timelines so profile
  Worlds tabs reuse normal local post rendering and visibility enforcement.
- Added a concurrent actor/native-family object index so complete historical
  profile Worlds participation summaries avoid full cached-object scans.
- Kept malformed RSS, Atom, and federation XML discovery candidates from
  emitting xmerl fatal-error noise after their callers had already handled the
  parse failure, and staggered remote-post cleanup away from the busy 04:00
  cron boundary after a live database checkout timeout.
- Kept Worlds book-library add, move, progress, and remove operations out of
  timelines and notifications while preserving public BookWyrm-compatible
  shelf collections and explicit review publishing.
- Updated Hackney to 4.7.2, normalized recently added federation source,
  migration, and test formatting, and registered new federation logger
  metadata keys with both configured logger backends.
- Preserved book titles, authors, covers, ISBNs, and progress when clients move
  an existing book with a partial shelf update.
- Kept successful media-proxy size-limit fallbacks at debug severity instead
  of logging an application error when oversized remote media is safely
  replaced by the local placeholder.
- Made Funkwhale actor rendering tests explicitly enable federation and updated
  unread-notification fixtures to represent distinct events under the new
  user/activity uniqueness invariant.
- Restored the identity-proof compatibility endpoint's factory-backed
  regression test so clean test compilation exercises persisted proofs.
- Removed warning-backed unreachable paths in accepted-answer validation,
  deferred collection counts, account native metadata, and status edits while
  preserving their explicit error contracts and background-refresh behavior.
- Added the missing OpenAPI contracts for moderator-reply distinguish and
  undistinguish routes so API schema generation no longer fails during clean
  compilation, and regrouped ActivityPub collection render clauses.
- Fixed migration ordering for simultaneous notification-integrity and
  federation-delivery tracking changes, completed suspended-state Oban
  uniqueness, and removed unreachable worker clauses that hid real validation
  signal under current Elixir and Oban.
- Updated remote reply and collection traversal for the contained prefetched
  object's three-element return shape, restoring context, parent, and paged
  reply discovery without bypassing canonical fetch validation.
- Restored explicit repository and constants-macro bindings in event capacity,
  interaction policy, actor rendering, validation, and ActivityPub metadata
  paths, and cleaned stale notification and account rendering bindings.
- Restored stable status-render cache keys for current content and summaries by
  deriving their chronological position from bounded object history, with a
  safe zero fallback for malformed legacy history.
- Fixed local-reference resolution under current Elixir by moving dynamic URL
  membership checks out of guards, and removed a duplicate create-status quote
  policy schema that silently replaced the documented creation default.
- Restored the ActivityPub BCC publisher's nested delivery loop and federated
  collection removal control flow so both paths compile and preserve their
  fail-fast error handling.
- Fixed a malformed poll-option default argument and cleaned warning-backed
  defects in accepted-answer publishing, aggregate Feed membership, native
  ISBN validation, quote-link recognition, and Nostr maintenance tasks.
- Updated Phoenix, Phoenix LiveView, and Postgrex to patched releases after
  Hex advisory checks identified the previous locks as vulnerable.
- Fixed remote-target curation re-enablement on current Ecto by preventing the
  imported query `update/2` macro from intercepting the curation module's own
  persistence function.
- Exposed backend-verified FEP-c390 identity statements in public Mastodon
  account metadata so profile clients do not need privileged secondary
  requests to present them.
- Prevented unverified FEP-c390 identity statements from surviving as opaque
  actor extensions, so only statements accepted by the bounded cryptographic
  verification pipeline can be stored or re-emitted.
- Added bounded FEP-c390 remote identity-proof verification using the W3C
  `eddsa-jcs-2022` algorithm, actor/DID binding checks, persistent original
  statements, ActivityPub actor re-emission, and the account identity-proofs
  API instead of its former empty stub response.
- Bound prefetched ActivityPub objects to the exact URL that passed the normal
  fetch and containment pipeline, and tightened canonical permalink aliases to
  explicit document metadata or an authoritative HTTP redirect instead of a
  permissive path-name heuristic.
- Added bounded ActivityPub request counters and latency distributions labeled
  only by code-defined route, method, and response class, avoiding actor, IP,
  host, body, query, and full-URL cardinality or adjacent-pipeline duplication.
- Added bounded, cache-only canonical link localization so known actor and
  visible object references in sanitized status HTML open through local FE
  routes without changing stored content or fetching arbitrary links.
- Added administrator-managed remote Group curation with safe actor
  resolution, duplicate-safe reversible storage, explicit ordering, and
  priority placement in ordinary Worlds community discovery.
- Made local Group Announce identifiers deterministic and propagated wrapped
  Delete and Undo creation or enqueue failures through the owning deletion
  pipeline, allowing retries to validate and requeue one canonical wrapper.
- Made automatic Follow and Join responses use deterministic local activity
  IDs, recover and requeue the exact stored response after a processing race,
  and fail the owning pipeline when durable federation insertion fails instead
  of creating duplicate Accept or Reject activities on retry.
- Unified the runtime ActivityPub disable switch across protocol routes,
  WebFinger and NodeInfo advertisements, actor and object fetch fallbacks,
  outgoing queue insertion, and queued AP workers while leaving cached remote
  content, RSS ingestion, and independently gated native bridges available.
- Made outgoing ActivityPub fanout observable and retryable by propagating
  publisher, inbox-job, relay, and forwarded-activity enqueue failures through
  the owning Oban worker, while deduplicating already-inserted delivery jobs.
- Made canonical ActivityPub actor IDs authoritative over inferred host-based
  handles, persisted verified WebFinger aliases separately with bounded
  revalidation, and prevented unverified actor documents from displacing an
  existing remote nickname.
- Made ordinary client replies inherit and reauthorize the parent post's
  canonical group audience, so remote group replies retain both object context
  and durable delivery even when the client does not submit a group-specific
  field, and copied that audience onto the outer Create envelope.
- Distinguished intentionally bounded remote collection results from incomplete
  page walks, preventing unavailable, malformed, or cross-origin continuation
  pages from publishing partial featured data or caching partial counts.
- Preserved bounded native Video attachment metadata while selecting a
  type-appropriate playable representation, retaining captions and alternate
  metadata instead of replacing the remote attachment set.
- Resolved relative HTML and Markdown source links against canonical object or
  instance URLs through parsed Floki and MDEx trees, and scrubbed outbound HTML
  source so portable federation does not preserve executable source markup.
- Added one bounded, cycle-safe remote collection reader for mixed inline and
  URL entries, and used it for featured-object and moderator-count refreshes so
  collection pages without `totalItems` no longer collapse silently to zero.
- Enforced remote moderator-only group posting restrictions before status
  creation and exposed role-aware `can_post` relationships so clients do not
  offer group composers that the destination will reject.
- Reconciled concurrent Create and Update deliveries at the object insertion
  boundary with the existing row-locking timestamp-aware updater, so a Create
  that wins insertion cannot discard a newer Update body and an older Update
  cannot overwrite newer stored content.
- Added a bounded, configurable post-follow outbox backfill worker that fetches
  only the remote actor's outbox root and first page, rechecks the active
  follow, and schedules same-origin canonical items through ordinary contained
  remote-fetch jobs with per-item spacing.
- Hardened remote media representation handling by bounding URL alternatives,
  filtering malformed and unsafe entries, selecting typed HTTP(S) media and
  page URLs, and rejecting unusable objects without `[nil]` attachment data.
- Made status edits reject quote-target mutation and incompatible poll/media
  replacements with clear client errors instead of reporting an internal
  server error.
- Allowed validated polls, media, and visible quotes to stand alone without a
  text body while continuing to reject submissions that have no meaningful
  content after poll and quote resolution.
- Added one sanitized visible fallback link to serialized local quote posts so
  peers that discard structured quote properties retain the quoted target,
  including quotes whose authored body is empty and only has a content warning.
- Made RichMedia previews fragment-aware through bounded exact-ID section
  extraction, while safely falling back to ordinary card metadata for missing,
  malformed, selector-shaped, or oversized fragments.
- Made specialized photograph discovery interaction permissions explicit and
  fail-closed when a remote object does not advertise reply, like, or announce
  support, while preserving whether each permission was actually declared.
- Fixed source-only ActivityPub posts, including private posts delivered to an
  authorized recipient, by safely formatting supported `source.content`
  representations when the peer supplies no rendered content.
- Normalized current Funkwhale artist `cover` metadata and the historical
  `attachment_cover` alias, including bounded generated cover URL maps, so
  received audio can fall back to artist artwork when track and album artwork
  are absent.
- Added authority-checked accepted-answer interoperability for question-style
  discussions, including PieFed `ChooseAnswer` and embedded Undo handling,
  one-answer-per-thread persistence, group-wrapped delivery, Mastodon API
  controls, and status metadata for native frontend presentation.
- Corrected protected API authentication semantics so absent or invalid bearer
  credentials return JSON 401 responses with a Bearer challenge, while valid
  tokens lacking required scopes continue to return 403.
- Added authority-backed Threadiverse distinguished comments: the validator
  preserves the wire property only for a known group actor or manager, the
  Mastodon status extension exposes it, and local moderators can federate
  distinction changes on their own group replies through dedicated endpoints.
- Scoped federated Flag delivery to remote community actors or explicitly known
  remote community moderators and, where needed, the reported actor's instance;
  sensitive reports now discard inherited public/follower audiences and
  deduplicate destinations by instance.
- Added an idempotent, normalized projection for PieFed-style aggregate Feed
  membership so signed Feed Add/Remove activities can curate community actors
  without creating account follows, changing pins, or trusting foreign
  collection targets, and surfaced the curated communities with Feed provenance
  through native group discovery. Feed actor refreshes now seed the projection
  from one bounded, same-origin following page in the existing background
  collection worker.
- Enforced bounded plaintext on every final Web Push title and body so remote
  group names, fallback notification types, and future formatters cannot leak
  HTML or oversized text into device notifications.
- Normalized bounded decimal and hexadecimal HTML numeric entities used by
  snac-style EmojiReact activities, but only when they decode to one valid
  Unicode emoji grapheme.
- Preserved remote attachment labels while consistently preferring nonblank
  ActivityStreams `summary` alt text in Mastodon API responses, RSS/Atom media
  descriptions, and Schema.org metadata.
- Prevented inherited Mention tags from generating irrelevant notifications on
  federated replies unless the mentioned actor is also present in the reply's
  ActivityPub audience, while retaining tag-only compatibility for top-level
  posts.
- Isolated malformed or historically orphaned ActivityPub outbox entries so
  one unrenderable item is skipped with bounded diagnostic metadata instead of
  returning a 500 for the complete collection page.
- Bounded failed-signature actor key refreshes with a durable freshness
  cooldown, preventing invalid inbox signatures from repeatedly forcing
  synchronous remote actor fetches while preserving key-rotation recovery.
- Excluded quote fallbacks, recipient affordances, and invisible URL fragments
  from generated group titles and native-object catalog text so transport
  compatibility markup is not presented as authored content.
- Rejected canonical localhost, private, link-local, documentation, multicast,
  and non-public literal addresses during federated URL and WebFinger target
  discovery, with production host resolution failing closed when no public
  address is available, including IPv4-compatible and IPv4-mapped IPv6 forms.
- Added shared page-budget and cycle state to remote reply and context
  collection traversal, preventing cyclic `first`, `current`, and `next` links
  from causing repeated network fetches while preserving mixed inline items and
  URL identifiers.
- Prevented federated target discovery from recursively probing the local
  endpoint, alternate WebFinger domain, or configured fetch-actor origin by
  comparing normalized schemes, hosts, and effective ports before network I/O.
- Hardened oEmbed ingestion so only bounded scalar card fields and reasonable
  dimensions reach storage, while hostile nested metadata is ignored without
  breaking the entire preview.
- Added flattened media width, height, and aspect metadata alongside
  `meta.original` for Mastodon-compatible attachment consumers.
- Prevented concurrent federation deliveries from persisting or streaming
  duplicate notifications for the same local user and exact activity, with a
  migration that safely merges historical duplicate rows before enforcing the
  database invariant.
- Added context-aware Mastodon filter results with exact matched text, corrected
  per-filter whole-word semantics, included content warnings in irreversible
  filtering, and reused active filters across each rendered page.
- Moved allowlisted remote emoji downloads out of incoming ActivityPub request
  processing into deduplicated background jobs that revalidate policy, retry
  transient failures, install files atomically, and refresh the emoji cache.
- Added complete Mastodon search pagination links that preserve the active
  query, resource type, account and capability filters, resolution mode, and
  offset for frontend and third-party API clients.
- Enforced local federation policy before creating replies, quotes, chats,
  likes, dislikes, reposts, and emoji reactions, preventing local interaction
  state from claiming success when either endpoint is defederated and the
  publisher would necessarily discard delivery.
- Tracked successful outbound object delivery so drafts, local-only posts, and
  failed publishes no longer emit misleading remote Deletes to peers that
  never received the object, while preserving conservative behavior for
  historical activities whose delivery state cannot be reconstructed.
- Preserved bounded attachment licensing metadata in Mastodon status responses,
  including common SPDX and license-reference shapes, alongside the existing
  media type, dimensions, description, and blurhash fields.
- Stopped the custom emoji API from returning entries with blank, malformed, or
  credential-bearing media locations, while retaining those loader records for
  operator diagnosis and reload instead of emitting broken client markup.
- Fixed Mastodon pagination links so short pages do not advertise false next
  cursors, full descending pages continue from their oldest item, empty pages
  remain header-free, and invalid limits resolve to bounded defaults.
- Centralized bounded HTTP media-type parsing for ActivityPub negotiation,
  object fetches, WebFinger, and rich media so valid lists and parameters work
  while malformed ranges and explicit `q=0` alternatives fail closed.
- Made Nostr media backfills deterministic and resumable with an indexed event
  scope, bounded batches, validated `--after-id` cursors, completion reporting,
  and exact continuation tokens for interrupted maintenance.
- Added asynchronous instance metadata discovery when a remote actor first
  establishes an accepted follow to a local account, so active new peers become
  classifiable without delaying or risking the follow transaction.
- Added regression coverage proving pending and rejected relationships cannot
  enter followed group, source, RSS refresh, or Worlds discovery surfaces.
- Enforced ActivityPub Lock across complete reply subtrees with bounded,
  cycle-safe ancestor checks, preserving local group-manager authority while
  rejecting ordinary local and remote replies and rendering descendants closed.
- Hardened HTML ActivityPub alternate discovery by resolving relative links
  against the final response URL, rejecting cross-origin, credential-bearing,
  fragment, oversized, and looping targets, and routing accepted alternates
  through the normal SSRF, redirect, MRF, and identifier-containment fetcher.
- Preserved the exact audience of followers-only and direct parents for local
  replies, and rejected incoming protected replies that widen that audience or
  reference a missing parent whose authorization cannot be established.
- Bounded local and incoming emoji reaction names by grapheme and byte length,
  normalized locally submitted poll choices to unique plain text before limits
  and storage, and rejected remote poll choices containing raw or escaped HTML.
- Centralized credential-safe URL rendering for logs and applied it to actor
  fetches, outbound federation, remote reply hydration, RSS ingestion, and rich
  media diagnostics so userinfo, signed queries, and fragments are not logged.
- Stopped internal and ActivityStreams `Application` actors from accumulating
  human follow, interaction, stream, and push notifications while preserving
  notification behavior for user-controlled `Service` bots.
- Added a bounded account-migration restart endpoint that reuses the latest
  stored Move, re-resolves and reauthorizes its destination, deduplicates
  delivery and follower-reconciliation jobs, preserves the original cooldown,
  and exposes the moved-to actor to the authenticated account owner.
- Accepted account archives with one enclosing export directory while
  rejecting path traversal, duplicate required files, and ambiguous roots;
  running imports now publish their total item count for meaningful client
  progress reporting.
- Completed the FEP-1b12 group activity authority verifier with compile-safe
  canonical type comparison, allowing cross-origin wrapped activities to be
  refetched and checked instead of leaving the verifier unavailable at runtime.
- Normalized multi-valued and embedded-ID ActivityPub `inReplyTo` values at
  ingress and during remote reply discovery, preserving threads from peers
  that publish more than one reply target representation.
- Recognized FlockXR 3D model attachments by their registered media type and
  `.flock` extension so federated model objects use the native model workflow.
- Routed server-side media preview work through the configured internal HTTP
  listener while retaining public HTTPS browser redirects, preventing local
  hairpin timeouts and persistent self-TLS connections during shutdown.
- Acknowledged remote featured-collection additions beyond the local pin
  authoring limit without mutating the bounded local view, preventing permanent
  remote pin-limit failures from retrying as generic transaction rollbacks.
- Accepted bounded NIP-31 `alt` and NIP-89 `client` metadata on NIP-17 relay
  lists, accepted bounded Unicode NIP-58 badge identifiers, and retained large
  valid remote badge selections while resolving and displaying only the first
  eight entries. Control characters and malformed badge references remain
  rejected.
- Accepted bounded large NIP-29 administrator and member lists so followed
  Nostr communities with more than 128 identities can synchronize their signed
  group state without weakening the smaller limit applied to ordinary events.
- Applied the NIP-01 lowest-event-ID tie-break to equally dated replaceable
  events during both storage and query deduplication, preventing relay arrival
  order from oscillating group membership and other replaceable state.
- Replaced quote-forwarding and post-hydration scans with the existing indexed
  JSONB quote-target lookup, preventing ordinary remote Update and Delete
  activities from exhausting database connections while preserving validation
  that a matching local Create activity exists.
- Restored GoToSocial unauthenticated-web visibility normalization in account
  status queries so remote profile timelines cannot fail when those actor
  extensions are present.
- Serialized native-object lifecycle transitions and made repeated state changes
  idempotent so concurrent or duplicate requests cannot publish redundant
  ActivityPub Update activities.
- Improved NodeInfo 2.1 interoperability by publishing the software homepage,
  advertising both legacy HTTP and current HTTPS schema relation aliases, and
  adding bounded public cache headers for discovery and metadata responses.
- Kept retried ActivityPub Follow activities idempotent at the notification
  layer without loading a user's full notification history, while still
  emitting a fresh Accept activity to repair remote relationship state.
- Honored explicit ActivityPub `indexable: false` and `discoverable: false`
  object-level preferences in full-text search indexing, extending the existing
  FEP-5feb actor and native Worlds discovery protections to ordinary posts.
- Encrypted webhook signing secrets at rest with authenticated, record-bound
  ciphertext and added safe Schema.org JSON-LD descriptions for public
  profiles, native objects, non-sensitive media, reviews, ratings, and reviewed
  catalogue items.
- Hardened WebFinger and account Move handling for legacy actors whose
  `also_known_as` value is absent, and exposed alias and last-move state to
  administrators for migration diagnosis.
- Prevented disabled admin webhooks from being selected for delivery.
- Preserved canonical and legacy quote target IDs in scheduled-status API
  responses so clients can render scheduled quotes after reloading them.
- Fixed frontend reply composition so normal and event replies cannot retain a
  stale quote target from an earlier composer action.
- Removed scheduled statuses and their linked Oban jobs before deleting an
  account, and deduplicated identical incomplete deletion jobs so stale
  schedules cannot outlive account cleanup or run concurrently twice.
- Validated Open Library ISBN metadata by checksum, including both assigned
  `978` and `979` ISBN-13 ranges, so malformed provider values do not populate
  editable book drafts when a valid candidate is available.
- Stopped expired account relationships from remaining effective while their
  cleanup job is delayed by filtering them from existence, timeline, and
  rendering queries and expiring the muted-user cache at its nearest deadline.
- Bounded per-account content filters and filter-phrase length, rejected
  unknown filter contexts, and serialized filter ID allocation so simultaneous
  clients cannot create ambiguous filter IDs or race past the configured cap.
- Rejected blank Mastodon admin account actions before moderation side effects,
  preventing an omitted action type from silently resolving an attached report.
- Preserved reporter and target ActivityPub identities in admin report
  responses after either account has been deleted, keeping historical reports
  reviewable without inventing a replacement account.
- Prevented concurrent incoming activities from downloading and writing the
  same stolen remote emoji more than once by locking and rechecking the target.
- Added route-aware crawler directives for API, authentication, and federation
  infrastructure while keeping public profiles and post pages indexable.
- Enforced federated event attendee capacity under a per-event database lock
  for direct joins and restricted-event approvals, preventing concurrent local
  requests from overbooking Mobilizon-compatible events.
- Fixed local ActivityPub outbox collection metadata so root collections and
  pages report the full visibility-aware `totalItems` count instead of omitting
  it or confusing the total with the current page size.
- Preserved WordPress ActivityPub content warnings that arrive through
  `dcterms:subject` by using them as the standard object summary when no
  explicit ActivityStreams summary is present.
- Prevented historical federation backfills from producing fresh web-push
  alerts while retaining the stored notification and websocket update.
- Made timestamped ActivityPub Update activity IDs deterministic per object and
  edit timestamp so peers can deduplicate repeated deliveries safely.
- Fixed NodeBB category addressing when forum posts identify their destination
  Group through ActivityPub `target` rather than `audience`, `to`, or `cc`.
- Bounded remote ActivityPub media arrays separately from local composer limits,
  preserved a bounded set of excess media as safe post links, and enforced the
  documented remote character limit against visible text after stripping HTML.
- Rejected ActivityPub Updates that attempt to move an existing object to a
  different `inReplyTo` parent, preserving thread, visibility, and notification
  topology across remote edits.
- Restricted private quote-authorization documents to the signed quoting or
  quoted actor while keeping fully public approvals briefly cacheable, so
  cache-control headers are no longer mistaken for access control.
- Inlined federation-ready quote objects in outgoing QuoteRequest instruments
  so peers can validate local quotes without a second fetch, and streamed status
  updates when quote authorization is accepted, rejected, or revoked.
- Verified profile-field backlinks against both canonical ActivityPub actor IDs
  and advertised human profile URLs, so remote rel-me fields do not lose
  verification when those URLs differ.
- Acknowledged unsupported ActivityPub activities from validly signed or
  already-known actors without queueing them, preventing pointless remote
  retries while retaining strict rejection for unsigned unknown first contact.
- Completed FEP-e232 quote Link handling by emitting the explicit Misskey
  quote relation on outbound tags, requiring it during inbound normalization,
  and keeping repeated policy passes idempotent.
- Added safe inbound PieFed `PollVote` compatibility by normalizing known-poll
  votes through the existing ActivityStreams Answer validation and storage
  pipeline.
- Added `Vary: Accept` to negotiated profile and object responses while
  preserving authorized-fetch variation, preventing intermediary caches from
  mixing frontend HTML and ActivityPub JSON for the same URL.
- Accepted bounded PieFed-style multi-object Announce activities by expanding
  same-group items into deterministic single-object activities before the normal
  validation, authorization, containment, and side-effect pipeline runs.
- Accepted direct `mediaType: text/markdown` Article, Note, and Page objects,
  preserving their original Markdown source while rendering safe HTML locally.
- Preserved explicitly tagged ActivityPub Group mentions with actor-type metadata
  while continuing to hide implicit group audience addresses from status mentions.
- Fixed incoming poll option and vote names containing HTML entities so remote
  poll updates match their options consistently and clients receive the
  intended text.
- Updated local Question federation so poll result Updates are delivered
  privately to all known remote voters as well as the original status
  recipients.
- Kept remote tag, emoji, and generator refreshes from fabricating post edit
  history or replacing the user-visible edit timestamp when human-authored
  content did not change.
- Stopped outbound Like and EmojiReact activities from addressing the Public
  collection while retaining their concrete author and follower recipients.
- Hardened FEP-1b12 group wrappers by using inline activities only when their
  identifiers share the Announce origin and otherwise fetching the canonical
  cross-origin activity before ingestion; also advertised Mastodon-compatible
  actor `canFeature` policies, preferred canonical ActivityStreams content
  negotiation, and exposed both standard ActivityPub alternate-link types.
- Accepted linked ActivityStreams `likes` collections on incoming notes and
  edits by dropping the remote aggregate before validating locally maintained
  reaction state.
- Rechecked remote quote authorization when an implicit object update adds a
  verification URL, while refusing target swaps and revoked-quote revival.
- Ignored malformed cross-origin shared inbox endpoints while importing remote
  actors, preserving actor compatibility without allowing signed deliveries to
  be redirected to an unrelated origin.
- Made event link previews use the event's own sanitized title and event type
  instead of presenting Mobilizon and Gancio events under the organizer name.
- Bound fetched ActivityPub documents to the single final response URL after
  redirects, rejecting cross-origin responses that claim an identifier on the
  requested host while retaining same-origin human-to-canonical redirects.
- Serialized featured-collection pin and unpin updates against the current
  user row so concurrent ActivityPub Add and Remove deliveries cannot lose a
  valid pin or restore one that was already removed.
- Serialized local unreblog requests and made already-unreblogged requests
  idempotent so concurrent clients cannot publish duplicate Undo activities.
- Deferred AT Protocol and Nostr user-cache population until after their
  identity transactions commit, preventing rolled-back identity state from
  leaking through cache entries.
- Serialized remote object edits against the current database row so a stale
  concurrent Update cannot overwrite a newer edit or emit duplicate edit
  events.
- Prevented clients from making direct or followers-only posts advertise a
  broader ActivityPub quote policy, while preserving normal quote controls for
  public and unlisted posts.
- Fixed ActivityPub follower and following collection pagination so roots
  advertise both bounds, pages include backward links, and final partial pages
  no longer point peers at a nonexistent extra page.
- Normalized NodeBB-style `Update(Tombstone)` deletion activities through the
  existing authorized Delete pipeline so remote topic removals are applied
  without introducing a weaker deletion path.
- Preserved PeerTube account and channel relationships when newer video
  objects send `attributedTo` as bare actor URLs instead of embedded actors.
- Fixed BookWyrm quotation objects so their string-valued `quote` passage is
  not mistaken for a federated quote-object URL.
- Defaulted unlisted posts to follower-only quote approval when a client omits
  an explicit policy, preventing quotes from unexpectedly promoting an
  intentionally unlisted post to unrelated users.
- Bound newly issued OAuth authorization codes to their original redirect URI,
  preventing a code created for one registered callback from being redeemed
  through another callback owned by the same client.
- Made TOTP enrollment replace recovery codes atomically when confirmation
  succeeds and return their one-time plaintext values to the enrolling client,
  preventing settings-page visits from silently invalidating saved codes.
- Prevented browsers and intermediary caches from storing dynamic error
  responses by applying `Cache-Control: private, no-store` to every HTTP 4xx
  and 5xx response, even when the optional HTTP security-header bundle is
  disabled.
- Revoked every active OAuth session after a successful password change so a
  previously stolen token cannot remain usable after the account is secured.
- Updated the default Owncast live-stream discovery endpoint from the retired
  `directory.owncast.online` host to `owncast.directory`, restoring the native
  live-stream catalogue without overriding operator-configured directories.
- Normalized inbound bare `Public` and compact `as:Public` ActivityStreams
  audience values through the standard recipient pipeline, preserving public
  visibility for NodeBB-style activities without a redundant compatibility
  pass.
- Rechecked the current MRF domain reject list when queued federation delivery
  runs, preventing jobs created before an operator block from sending after the
  block takes effect.
- Completed local `toot:indexable` support so users can independently control
  whether compatible federated services include their public posts in
  full-text search, without conflating post indexing with profile discovery.
- Queued direct ActivityPub recipient deliveries before creating relay
  Announces so relays cannot race ahead of the object they reference.
- Fixed external OAuth provider failure callbacks so browser-supplied state
  cannot redirect outside an application's registered callback URI list.
- Added a bounded per-domain `MRF.SimplePolicy` content-warning rule that
  safely prepends operator context to remote author warnings and marks matching
  Create and Update objects sensitive without discarding either warning.
- Preserved ActivityPub quote policies across unrelated status edits and
  exposed the normalized policy to clients so an edit cannot silently broaden
  quote permission back to the frontend default.
- Added the missing Ed25519 ActivityPub HTTP-signature path promised by the
  actor-key compatibility work: bounded actor-controlled JWK and Multikey
  methods are retained alongside RSA keys and verified for both legacy and
  RFC 9421 signatures without accepting malformed or foreign-controlled keys.
- Reduced incoming `Announce`/`Create` queue races by retrying an unresolved
  announcement quickly only while its referenced Create is still pending in
  the local receiver queue, without accelerating ordinary remote failures.
- Required incoming replies, quotes, reactions, boosts, answers, and event
  participation activities to target objects visible to their actors, closing
  a cross-platform authorization gap identified in Sharkey's 2025 hardening.
- Extended outgoing Delete delivery to known remote reply, quote, boost, like,
  dislike, and emoji-reaction actors even when they discovered a public object
  without receiving its original delivery from this server.
- Forwarded origin-authenticated public quote Updates and Deletes to remote
  followers of local quote authors when the original activity carries a safe
  embedded forwarding proof, while preventing origin loops and duplicate inbox
  deliveries.
- Applied keyword moderation to ActivityStreams language maps as well as scalar
  content, summary, and name fields, preventing multilingual payloads from
  bypassing reject, delist, or replacement rules.
- Honored explicit `indexable: false` and `discoverable: false` object metadata
  in native Worlds discovery and its PostgreSQL partial indexes while keeping
  direct object resolution available.
- Corrected NIP-29 group semantics so `restricted` means member-only posting
  rather than moderator-only posting, `hidden` controls local discovery, and
  private Nostr group events are retained as signed relay records without
  being projected into the public ActivityPub timeline.
- Hardened FEP-044f quote authorization documents so deleted quote or target
  objects return not found, public live documents receive only a 30-second
  shared cache lifetime, and all other authorization responses are explicitly
  non-cacheable.
- Preserved remote NIP-11 `default_limit` relay metadata, matching its
  clarified meaning for subscriptions that omit an explicit result limit.
- Rejected embedded legacy signature proofs whose `creator` conflicts with a
  second `verificationMethod`, preserving canonical-origin forwarding support
  without accepting ambiguous proof identity.
- Accepted bounded JSON-LD `type` arrays on incoming activities and embedded
  objects, preferring known concrete ActivityStreams types without discarding
  specialized vocabulary types.
- Accepted Mobilizon group Events whose authenticated organizer differs from
  `attributedTo` only when the attributed actor is a known Group on the same
  host, preserving useful group attribution without allowing cross-host claims.
- Canonicalized recognized remote public-key PEM blocks before storage so
  harmless snac-style trailing text no longer makes a valid actor key unusable.
- Preserved GoToSocial `replyAuthorization` on incoming replies, accepted the
  deprecated `approvedBy` fallback, and advertised the corresponding JSON-LD
  interaction-policy vocabulary when re-serving those objects.
- Rejected votes after a remote poll's known closing time even when its final
  closing Update has not arrived yet.
- Prevented old posts discovered through explicit object or thread fetching
  from generating fresh notifications or websocket events while retaining
  storage, search, counters, group association, and normal inbox behavior.
- Reconciled public posts that arrive before a remote Group actor's Announce so
  their cached object and Create envelopes acquire the late group context
  without changing authorship or broadening private content.
- Accepted Unicode local WebFinger account names and centralized outbound
  resource encoding so explicit `acct:` subjects are encoded exactly once.
- Explicitly addressed remote event organizers on outgoing Join activities so
  Friendica-style RSVP notifications reach the organizer without broadening
  the event audience.
- Prevented local replies and quotes from being published more broadly than
  the referenced private, unlisted, or local post.
- Rejected malformed actorless ActivityPub activities at the inbox guard
  before they can consume incoming federation queue capacity, while retaining
  embedded actor-object compatibility.
- Routed RSS and Atom source refresh requests through the shared HTTP client so
  they receive the same pooling, timeout, proxy, TLS fallback, and exception
  handling as other controlled outbound requests.
- Accepted safely origin-refetched public ActivityPub Updates and Deletes from
  authenticated inbox forwarders, handled forwarded View/Read receipts as
  state-free no-ops, and retained strict rejection when a destructive activity
  cannot be confirmed from its canonical origin.
- Fixed idless Smithereen-style featured collections by fetching them through
  the collection containment path, including collections that embed complete
  pinned objects in `orderedItems`.
- Fixed a native-Nostr ingestion race where ActivityPub reactions targeting a
  Mostr object could arrive just before the corresponding native projection;
  target resolution now performs the bounded native lookup and returns the
  existing retryable Nostr error instead of permanently losing the reaction.
- Applied Akkoma's 2026 security and correctness lessons by redacting OAuth
  bearer material from struct inspection, treating user filter phrases as
  literal text, preferring query-bound incoming HTTP signatures, signing query
  parameters on outgoing federation requests, and reapplying activity-shaped
  MRF policy to fetched object updates.
- Removed the global PostgreSQL GIN fuzzy-search cap so database fallback
  searches remain deterministic instead of silently returning an arbitrary
  subset under load.
- Applied Pixelfed's recent OAuth hardening lesson by placing token exchanges
  behind dedicated per-minute and per-hour rate limits, while retaining
  Unfathomably's existing application-scope validation.
- Applied PieFed's untitled-post interoperability lesson by removing its
  `(content in post body)` sentinel during incoming ActivityPub normalization,
  preventing the implementation detail from appearing as a user-facing title.
- Applied MBin's actor-profile compatibility lesson by considering every usable
  link in ActivityPub actor `url` arrays and selecting the shallowest canonical
  profile route instead of assuming the first entry is suitable.
- Applied Lemmy's canonical-actor routing lesson so ActivityPub requests for a
  known remote actor through a qualified local alias redirect to the actor's
  authoritative HTTP(S) identifier instead of returning a misleading local
  representation or an unhelpful 404.
- Applied PeerTube's recent actor-binding lessons by requiring unknown remote
  Updates to keep object identifiers on the signing actor's host and rejecting
  actor documents whose embedded public key explicitly names another owner.
- Deduplicated received-audio discovery by canonical ActivityPub object,
  added reliable look-ahead pagination metadata, and preserved nested track,
  album, genre, category, and podcast taxonomy supplied by audio publishers.
- Preserved safe ActivityStreams `Link` attachments as rich-card candidates
  without exposing them as broken media attachments in Mastodon API status
  responses.
- Rejected repeat ActivityPub `Create` deliveries when an already-known object
  belongs to a different actor, while retaining idempotent same-author delivery.
- Dropped null ActivityPub tag entries before object validation and capped
  remote featured collections and pin-fetch fanout at 150 items.
- Included a bounded, visibility-filtered ancestor closure on reply-inclusive
  Nostr group timeline pages so kind-9 conversations remain visibly threaded
  when pagination would otherwise return a child without its local parent.
- Kept NIP-17 gift wraps and kind-10050 private-message relay metadata off
  strict group-only relays, even when those relays are part of the broader
  configured Nostr relay set.
- Fixed bounded source previews so complete posts embedded by Mitra and similar
  ActivityPub collections become normal local status cards without restoring
  synchronous per-item network fetches.
- Fixed instance-panel preloading so only an operator-installed panel is
  advertised; packaged frontend fallbacks can no longer mask a configured
  panel or appear as instance-specific content.
- Fixed remote-instance deletion so its reachability jobs, cached state, and
  database record are removed together.
- Rejected fetched ActivityPub objects whose response body claims an
  unadvertised attachment, media, storage, or upload URL as its identity while
  retaining legitimate same-origin human-page aliases.
- Fixed incoming joins for local Group actors so open groups accept and record
  membership immediately while moderated groups retain a pending request.
- Kept Worlds discovery SQL aligned with every supported native platform and
  rejected obvious inbound actor-origin spoofing before remote actor lookup.
- Fixed NIP-C7 chat reply projection so kind-9 Nostr group messages using
  `q` parent tags render as ordinary threaded replies, hydrate bounded context,
  propagate corrected root context through nested replies, maintain parent
  reply counts, and repair automatically when a referenced parent arrives
  later.
- Fixed Mastodon context rendering for out-of-order remote imports by deriving
  ancestors from explicit ActivityPub `inReplyTo` links instead of comparing
  locally assigned activity IDs, and ordering context entries by published
  time.
- Fixed native Nostr reply threading by distinguishing NIP-10 root/reply tags
  from citation-only mentions, hydrating bounded missing-parent threads, and
  consulting explicit hints, known parent/participant NIP-65 write relays, and
  approved search/profile relays before atomically reattaching existing
  ActivityPub projections once their parent becomes available; late parent
  arrivals now wake a bounded set of directly waiting child projections, and
  stored poll/media/event roots are reprojected through normal bridge checks.
- Moved bounded Nostr thread retrieval and local projection repair onto the
  existing remote-fetch and background queues so profile backfills cannot
  starve user-requested conversation context.
- Moved bulk Nostr profile/history backfills to the slow-work queue so they no
  longer occupy every native relay-ingest slot during large synchronization
  runs.
- Fixed historical Nostr polls used as conversation roots so elapsed `endsAt`
  values remain importable with their original closed timestamp and cannot be
  reopened for local voting.
- Separated group-only Nostr relays from profile-capable relays so account
  metadata, NIP-65 lists, badges, and private-message relay lists are no longer
  sent to strict NIP-29 relays that require an `h` group tag.
- Added outbound Nostr relay acknowledgement logging so rejected events retain
  their relay, immutable event ID, and protocol reason instead of disappearing
  behind an ignored `OK` response.
- Fixed deterministic Nostr metadata validation failures so malformed relay
  lists, badge definitions, and profile badge selections cancel ingestion on
  the first attempt instead of raising a worker case error and retrying.
- Fixed Nostr profile and NIP-65 relay-list propagation so each destination
  relay receives fresh local actor metadata before posts or interactions even
  when another relay was refreshed recently, and added a background profile
  publication operation using stable actor URIs for controlled refreshes.
- Stopped the generic ActivityPub follow exporter from emitting NIP-29 join or
  leave events for NIP-72 communities, whose membership is a local subscription
  rather than a relay-managed group relationship.
- Kept active Nostr community discovery actionable by withholding relay
  catalogue entries until at least one verified post is available in their
  indexed local group timeline.
- Fixed NIP-72 clients that place the community coordinate only on the signed
  approval by accepting that moderator-authorized form without weakening
  mismatched-coordinate checks, applying the verified address only to the
  local projection, and supporting picture/video-first submissions.
- Fixed approved NIP-72 submissions that were already known as ordinary Nostr
  posts so verified community replays add the group audience and indexed
  recipient without duplicating or deleting the existing local projection.
- Fixed OAuth scope and view rendering coverage for active Nostr community
  discovery so the Worlds and group interfaces can load the ranked catalogue.
- Prevented ActivityPub ChatMessage objects from entering the public Nostr
  status exporter and avoided atomizing attacker-controlled tag names while
  decrypting native Nostr messages.
- Completed NIP-29 group detail hydration by exposing real owner accounts,
  public member cards, and root-post counts; explicit NIP-21 event links now
  resolve through balanced, bounded server-side relay requests and normal
  signature and bridge validation instead of opening missing Mastodon status
  IDs or being hidden by a long identity relay list.
- Added a second bounded Nostr profile backfill pass when NIP-65 metadata
  reveals additional approved relays, improving names, avatars, and biographies
  for members discovered through NIP-29 group directories.
- Implemented capability-aware NIP-50 profile discovery through explicitly
  configured search relays, including NIP-11 feature checks, bounded
  server-side requests, signature verification, and relevance-ranked local
  relay search results.
- Corrected NIP-65 outbox routing so followed-author events are downloaded
  from write relays, tagged-user events are delivered to read relays, and
  local actors publish their relay-list metadata alongside outgoing events.
- Kept NIP-29 group events on their authoritative host relay instead of
  leaking group interactions onto unrelated profile relays.
- Allowed explicitly approved Nostr profile-discovery relays to hydrate account
  metadata without treating those relays as general posting or group relays.
- Hydrated followed NIP-29 group directories into standard member accounts,
  roles, and metadata backfills so group posts and member lists show usable
  names, avatars, biographies, and profile links instead of public-key
  placeholders.
- Ordered native Nostr community timelines by the original event publication
  time, including timestamp-aware Mastodon cursors and canonical Create
  projections, so historical backfills do not appear in arbitrary local
  ingestion order or lose page capacity to duplicate group Announces.
- Hydrated NIP-29 administrator, member, and role snapshots for native Nostr
  community mirrors so group APIs report the relay identity, authoritative
  member and moderator counts, and native platform classification instead of
  presenting an incomplete local ActivityPub shell.
- Routed browser-rendered Worlds catalogue artwork through a same-origin media
  proxy URL even for operator-whitelisted remote hosts, preventing strict CSP
  deployments from hiding PeerTube thumbnails and other native discovery
  previews.
- Integrated Pleroma's new Gun stream-lease architecture with Unfathomably's
  custom pools, proxy handling, and RichMedia limits; added safe extensionless
  image detection, strict Content-Length handling, and hard aborts for
  truncated committed proxy responses.
- Merged the newest fedidev.fun ActivityPub normalization cases for preferred
  list-valued types, inferred tags, varied emoji icons, and safe attachment URL
  shapes while retaining the broader local actor and native-object vocabulary.
- Backported the newest applicable Pleroma fixes for stale numeric user-cache
  entries, followed-account streaming through domain blocks, multi-hashtag
  pagination, unauthenticated account-feed restrictions, grouped notification
  details, and safer RSS/Atom links and sensitive-media enclosures.
- Isolated OpenTranslate requests from the federation HTTP pool and gave the
  self-hosted provider a bounded configurable receive timeout, preventing busy
  federation traffic from turning fast local translations into HTTP 503s.
- Stopped deterministic remote ActivityPub object-validation failures, such as
  polls with blank options, from consuming every remote-fetch retry when the
  same immutable object cannot become valid on a later attempt.
- Bounded incoming federation retries when a peer still rejects the verified
  TLS 1.2 compatibility request, and taught the Oban janitor to discard older
  exhausted handshake jobs instead of retaining impossible nested context
  fetches for days.
- Added a verified TLS 1.2 compatibility retry for idempotent Gun requests
  when an otherwise reachable federation peer rejects OTP's normal TLS
  ClientHello, without weakening certificate or hostname verification.
- Fixed remote instance favicon rendering so malformed absolute favicon URLs
  are normalized and media-proxied instead of violating the frontend's strict
  image Content Security Policy.
- Stopped the native book catalog from advertising local review posts and other
  non-book objects as selectable BookWyrm books. Catalog results now pass the
  same Book, Edition, or Work trust check used when publishing reading activity.
- Closed a delete-versus-fanout race where per-inbox `Create` publisher jobs
  inserted after the deletion cleanup could still deliver an already-deleted
  local object. Each queued `Create` now verifies its persisted source before
  delivery.
- Extended failed-image proxy fallbacks to extensionless ActivityPub custom
  emoji when the browser explicitly requests an image, preventing malformed
  remote emoji URLs from surfacing as page-level HTTP errors.
- Restricted Mastodon admin pending-account listings to local registrations,
  preventing federated remote actors from entering the approval workflow and
  avoiding an unindexed full-user scan for empty waitlists.
- Fixed outgoing ActivityPub normalization for remote attachments that omit
  `mediaType`, preserving validated HTTP(S) media links without inventing a MIME
  type so boosts, group wrappers, and object re-serving do not drop the media.
- Fixed quote-policy handling for remote actors whose advertised following
  collection does not use the conventional `actor-id/following` path.

### Security

- Centralized credential-safe URL diagnostics across remote object fetches,
  WebFinger, RichMedia-adjacent federation work, reply hydration, relay output,
  and remote emoji fetches, including redaction of credentials repeated inside
  adapter errors and reviewed search or database service DSNs.
- Bound legacy HTTP signatures to a signed request time, rejected stale
  signatures, and required body-bearing federation requests to sign a verified
  digest so captured signatures cannot authorize altered or indefinitely
  replayed inbox payloads.
- Prevented password-reset links from creating local credentials for
  external-auth-only accounts that do not already have a local password.

## [3.4.0] - 2026-07-19

### Security
- Rate-limited authenticated combined group/feed target discovery so explicit
  remote handle and URL resolution cannot be used to generate abusive lookup
  traffic toward another federated server.

### Added
- Added bounded native ActivityPub support for BookWyrm catalog activity,
  ForgeFed development objects, ActivityPods projects, Manyfold models,
  Flohmarkt listings, Castling games, Wanderer routes, NeoDB catalog entries,
  Bonfire ValueFlows, Mutual Aid, and ZenPub/CommonsPub resources, including
  actor extension metadata that the frontend can present safely.
- Expanded the checked-in wide federation suite to 39 peer-specific adapters.
  The suite now runs the shared moderation and defederation contract and records
  bidirectional follow, group, post, reply, reaction, deletion, blocking, and
  moderation capabilities without treating untested behavior as success.
- Added Friendica-compatible dislike APIs and native ActivityPub Dislike
  federation for peers that expose downvotes.

### Changed
- Updated every currently resolvable Hex dependency, including security-fix
  releases for Mint, Plug, Phoenix, Phoenix LiveView, and Postgrex; kept
  Hackney at 4.6.0 because later releases currently conflict with
  WebTransport's h2 requirement.
- Made the wide federation lane build its checked-in Elixir 1.20 and OTP 28
  test image automatically before starting disposable peers.

### Fixed
- Completed the federation-status OpenAPI schema used by account responses and
  removed an unreachable duplicate federated-target renderer so clean
  production builds include the expanded federation interfaces.
- Serialized concurrent ActivityPub object mutations so Updates, Likes,
  reactions, and their Undo activities cannot overwrite each other's object
  aggregates, and made reaction aggregate failures reach the receiver retry
  path instead of returning a false success.
- Fixed native Funkwhale Track Listen rendering and scrobble metadata, Owncast
  StreamStatus public-audience classification, linked non-actor Updates and
  Answers, and client-to-server Create validation for embedded Notes.
- Accepted ActivityPub signature actor identifiers that differ only by an
  explicit default HTTP or HTTPS port, and classified XWiki actors as publishing
  sources when NodeInfo is unavailable.
- Fixed upload metadata and blurhash analysis on Windows hosts and executable
  paths containing spaces.
- Fixed thread-aware remote fetches whose successful resolver result was a bare
  object, and made federation churn classification ignore unrelated structs
  instead of attempting to enumerate them as validation error containers.
- Restored the combined group/source discovery endpoint used by the frontend,
  including authenticated mixed-result rendering, ranking, deduplication, and
  pagination through the existing federated target catalog.

## [3.3.1] - 2026-07-17

### Fixed
- Accepted ActivityPub Link attachments whose remote `mediaType` is explicitly
  null by applying the existing safe octet-stream fallback instead of rejecting
  the entire containing post.
- Stopped remote-object fetch jobs from retrying and becoming discarded when
  validation already proves that the cached remote author is deactivated.
- Treated duplicate incoming federation deliveries as idempotent receiver
  success instead of cancelled Oban failures, including duplicate Likes caught
  during object-action validation, keeping routine peer retries out of the
  actionable federation-failure signal.
- Fixed incoming reactions and likes against temporarily unavailable remote
  objects so real fetch failures reach the bounded receiver retry path instead
  of being erased and misclassified as permanent missing-object validation
  failures, and derived stable thread context for Likes wrapped by Lemmy group
  Announces whose target objects omit their own explicit context.
- Added fail-closed support for public inbox-forwarded Mastodon Create
  activities carrying legacy `RsaSignature2017` envelopes. Cross-actor HTTP
  deliveries now fetch and process the canonical HTTPS origin activity only
  after strict actor, object, audience, forwarder, freshness, and origin checks;
  destructive and private activities remain rejected.
- Fixed reverse-proxy 500 responses when remote media servers return
  nonstandard HTTP status codes by safely mapping unknown codes to 502.
- Fixed reverse-proxy transport failures so upstream timeouts return 504,
  other upstream failures return 502, and routine timeout families no longer
  emit misleading application-error logs.
- Made transient remote object, reply-collection, and actor refresh failures
  retry with bounded backoff while deterministic missing, forbidden, deleted,
  and unsupported actor refreshes cancel without becoming discarded jobs.
- Capped remote-post janitor batch and candidate-page sizes so oversized legacy
  ConfigDB values cannot hold a PostgreSQL connection until its query timeout.
- Completed Mastodon-derived follow-request pagination and stale remote-poll
  refresh support so production builds do not retain controller calls to
  missing data-layer helpers.
- Corrected the quote lifecycle integration by using the real remote-object
  fetcher, delivering authorization revocations to the quoting actor, keeping
  local lifecycle bookkeeping off the ActivityPub wire, and accepting both
  keyword and map options in FEP-7888 context pagination.
- Added the FEP-044f and GoToSocial JSON-LD vocabulary mappings used by quote
  requests, quote authorizations, and interaction policies, and documented the
  corresponding Mastodon API status fields in OpenAPI.
- Added full quote interaction-policy handling with automatic, manual, denied,
  accepted, rejected, and revoked states; federated QuoteRequest and
  QuoteAuthorization verification; count-safe lifecycle transitions; and
  authenticated approval and revocation endpoints.
- Added FEP-7888 conversation context collections for local ActivityPub posts,
  including visibility-aware URI-only pages with bounded keyset pagination.
- Reduced avoidable federation work by rejecting rich previews before fetches
  for posts that already carry media or quotes, coalescing rapid local profile
  edits into one latest-state ActivityPub Update, and bulk-scheduling only
  remote-host probes that do not already have incomplete jobs.
- Added bounded per-inbox delivery histories to federation health metadata so
  administrators can distinguish a failing shared inbox or endpoint from a
  host-wide outage while retaining existing host-level backoff behavior.
- Preserved structured HTTP-signature failures so malformed RFC 9421 requests
  return client errors while temporary remote key failures return a retryable
  service-unavailable response, and re-signed authenticated object fetches after
  redirects instead of replaying signatures bound to the previous URI.
- Hardened incoming Updates by importing recent actor-matching objects when an
  Update legitimately races ahead of its Create while rejecting stale unknown
  objects and retaining the existing newer-edit protection.
- Closed active WebSocket and EventSource streams when local accounts are
  deactivated or their OAuth tokens are revoked, and refused new authenticated
  streams for inactive accounts.
- Normalized keyword moderation matching with Unicode NFKC and case folding so
  visually equivalent text cannot bypass string-based rejection or delisting.
- Isolated Oban janitor steps and per-object cleanup so one malformed row,
  timeout, or database failure is reported without abandoning unrelated cleanup
  work in the same run.
- Serialized concurrent idempotent API requests across connected BE nodes,
  scoped replay caches by authenticated user and endpoint, and added bounded
  lock waits with process-failure cleanup.
- Added incoming RFC 9421 HTTP Message Signature verification with RFC 9530
  body digests, replay-window enforcement, actor key refresh/history fallback,
  and outgoing ActivityPub retry after legacy signature rejection.
- Rejected ambiguous duplicate parameters in legacy HTTP Signature headers
  before actor key resolution or verification, and normalized language-tagged
  descriptions on incoming ActivityStreams media attachments.
- Connected the bundled backend-maintenance AdminFE to the maintained
  Unfathomably operations dashboard, corrected its stale development-doc link,
  and made future AdminFE installs default to the official stable branch.
- Fixed list create and update requests that combine replies policy with
  OpenAPI-cast title or exclusivity fields so mixed map keys cannot reach Ecto.
- Fixed dotted remote `/users/:nickname` browser routes so domain suffixes are
  not mistaken for unsupported response formats.
- Fixed `/users/:nickname/statuses/:id` compatibility routes so StaticFE uses
  the supplied status ID instead of falling through to an action-clause error.
- Restored the federation-status service and controller to the canonical BE
  distribution so federation-policy checks and their frontend surfaces no
  longer fail with an undefined-controller HTTP 500.
- Fixed extensionless browser tag URLs so they load the frontend, and hardened
  tagged Atom and RSS feeds so titled or malformed federated objects without
  text content render safely instead of raising from feed helpers.
- Fixed Mastodon status context requests for missing statuses so they return a
  normal 404 response instead of falling through to an HTTP 500.
- Reworked remote post and group discussion janitors to scan bounded,
  index-backed stale-object windows before applying expensive preservation
  checks, preventing daily cleanup queries from timing out on large databases.
- Made incoming federation processing timeouts configurable with a longer
  default so deep but valid remote reply chains can finish atomically instead
  of repeatedly rolling back at the historical 30-second boundary.
- Rejected malformed UTF-8 request paths before routing and made empty legacy
  remote-interaction requests return a client error instead of endpoint 500s.
- Filtered remote `alsoKnownAs` values through the local ActivityPub ObjectID
  type so cross-protocol aliases cannot prevent an otherwise valid actor
  profile from refreshing.
- Included suspended Oban jobs in RichMedia uniqueness so temporarily paused
  work cannot admit duplicate preview jobs.
- Accepted Lemmy- and PeerTube-style language descriptor objects on incoming
  posts, and ignored PeerTube video likes collection URLs that are not local
  interaction-ID lists.
- Made repeated Deletes that reference an already stored Tombstone idempotent
  instead of reporting the Tombstone's intentionally absent actor as an error.
- Accepted web-push subscription payloads without an optional alert policy,
  storing an empty policy instead of returning HTTP 500.
- Deduplicated RichMedia backfills across stream variants of the same activity
  and retained terminal outcomes for the same 15-minute window as the negative
  cache, preventing paired fetches for deterministic failures.
- Kept replies out of followed group and source aggregate streams so live
  WebSocket updates match the discussion-root-only REST feeds without removing
  replies from each group or source's own stream.
- Raised the systemd file-descriptor limit for source and release installs so
  short federation or media bursts cannot exhaust Cowboy acceptors and cascade
  into database checkout timeouts.
- Reworked remote-host database lookups around a matching host-and-id index,
  including a true loose-index peer scan, so reachability probes and instance
  statistics do not repeatedly scan the full remote-user table.
- Kept expected HTTP pool client `:normal` and `:shutdown` exits at debug level
  while preserving warnings for abnormal exits and request timeouts.
- Completed the frontend list workflow by wiring exclusive lists through
  create/edit state, clarifying member management, fixing the list editor close
  action, preventing blank member searches, and making list member additions
  duplicate-safe.
- Fixed list timeline routing in the frontend so `/list/:id` uses the route id
  supplied by the app wrapper instead of opening list, timeline, and WebSocket
  requests for `undefined`.
- Fixed list creation and editing in the frontend so Mastodon lists no longer
  show or submit the unsupported emoji field that caused `/api/v1/lists` to
  reject otherwise valid list names.
- Hardened frontend fallback routing so encoded credential, key, certificate,
  and environment-file probe paths return 404 instead of the single-page app
  shell.
- Cleaned follow-collection refresh logging so expected remote private or
  missing collections are one-line debug entries instead of warning noise.
- Refreshed warning-clean backend source on the live service so startup compile
  logs no longer hide runtime signal behind stale grouping and unreachable
  clause warnings.
- Fixed followed group/source aggregate streaming so frontend group and source
  feeds connect to path-style WebSocket endpoints and the backend fans target
  updates out to local followers' aggregate streams.
- Fixed protected frontend streaming hooks so user, notification, direct, list,
  group-feed, and source-feed streams wait for an OAuth token before opening
  WebSocket connections.
- Fixed invalid Mastodon list IDs such as `undefined` so list APIs and list
  timelines return normal not-found responses instead of raising Ecto cast
  errors.
- Tuned the remote group discussion cleanup worker for large live databases by
  reducing the default cleanup batch and allowing longer candidate-query
  timeouts before a daily janitor run is skipped.
- Reduced duplicate-key federation races by making hot object, remote actor,
  and instance-host inserts conflict-aware before falling back to the existing
  winning database row.
- Fixed OpenTranslate-backed status translation for remote posts whose detected
  source language is not directly advertised by the provider by retrying those
  concrete source-code failures with provider auto-detection.
- Fixed quote hydration for publicly addressed remote posts whose reply parent
  has been deleted or is unavailable, preserving the quote and its media without
  weakening ordinary protected-reply validation.
- Added bounded field-level diagnostics for terminal remote ActivityPub
  validation failures so federation compatibility issues identify the rejected
  fields instead of collapsing into generic churn.
- Fixed Lemmy-family Create activities that carry the same recipients as their
  embedded object but partition the community differently between `to` and
  `cc`, preventing valid posts from being discarded as addressing mismatches.
- Removed duplicate network fetches during remote reply ancestry hydration by
  passing already-contained payloads through the normal object pipeline, and
  stopped an initial transport failure from being retried immediately.
- Deduplicated remote actor refreshes across completed and terminal Oban states
  for the existing cooldown window, preventing bursts of stale or unreachable
  actor events from launching several identical refreshes.
- Accepted valid empty ActivityStreams featured collection pages and
  `items`-based Collection pages without treating them as malformed remote
  responses.

## [3.3.0] - 2026-07-06
### Added
- Added `build_scripts/unfathomably-friendica-smoke.sh` for stock Friendica
  forum federation coverage, including bidirectional follows, group posts,
  replies, local reactions, deletes where stock Friendica applies them, and
  explicit stock limitation reporting.
- Added `build_scripts/unfathomably-hubzilla-smoke.sh` for stock Hubzilla
  forum/channel federation coverage, including bidirectional follows,
  Hubzilla-to-Unfathomably group posting, Unfathomably-to-Hubzilla group
  posting, local reactions, cleanup, and explicit stock limitation reporting
  for reply, reaction, delete, and CLI/API unfollow gaps.
- Added `build_scripts/unfathomably-gotosocial-smoke.sh` for stock GoToSocial
  local federation coverage, including bidirectional account follows, posts,
  replies, likes, unlikes, deletes, unfollow cleanup, and explicit stock
  Group actor probe reporting.
- Added `build_scripts/unfathomably-misskey-smoke.sh` for stock Misskey local
  federation coverage, including bidirectional account follows, posts, replies,
  favourites, emoji reactions, quote notes, profile summaries, deletes,
  unfollow cleanup, and explicit stock Group actor limitation reporting.
- Added `build_scripts/unfathomably-iceshrimp-smoke.sh` for stock Iceshrimp.NET
  local federation coverage, including bidirectional account follows, posts,
  replies, favourites, emoji reactions, quote posts, deletes, unfollow cleanup,
  profile summaries, and explicit stock Group actor probe reporting.
- Added `build_scripts/unfathomably-pixelfed-smoke.sh` for stock Pixelfed local
  federation coverage, including bidirectional account follows, media posts,
  replies, favourites, local unfavourite cleanup, Pixelfed-origin deletes,
  unfollow cleanup, remote media attachment visibility, and explicit stock
  remote-unfavourite, remote-delete, and Group actor probe reporting.
- Added `build_scripts/unfathomably-funkwhale-smoke.sh` for stock Funkwhale
  local federation coverage, including account discovery/follow, public
  library and audio-track federation, local favourite/unfavourite behavior,
  outbound inbox delivery checks, and explicit stock remote-favourite,
  audio-delete, account, and Group actor probe reporting.
- Added `build_scripts/unfathomably-discourse-smoke.sh`, a stock Discourse
  ActivityPub bidirectional group-federation harness covering follow,
  top-level posts, replies, likes, unlikes, deletes, and unfollow behavior
  insofar as Discourse category actors support each operation.
- Added `build_scripts/unfathomably-wide-federation-smoke.sh` to run the live
  compatibility audit against broad group/forum/channel platforms and record
  per-platform `tested` or `not_tested` reports without stopping at the first
  unavailable public target.
- Added `build_scripts/unfathomably-nodebb-smoke.sh` for stock NodeBB local
  federation coverage, including supported category follow, topic delivery,
  like/unlike, reply/delete, cleanup, and explicit stock limitation reporting.
- Added `build_scripts/unfathomably-peertube-smoke.sh` for stock PeerTube local
  federation coverage across HTTPS channel follow, video delivery, likes,
  comments in both directions, comment deletes, video deletes, and explicit
  non-video group limitation reporting.
- Added a combined group/feed target discovery endpoint so clients can search
  known and newly resolved groups, forums, feeds, blogs, libraries, and channel
  actors through one ranked catalog.
- Added a shared federation-safety smoke gate covering local defederation
  awareness, blocked group relationship messaging, federated group Block
  delivery, source/account follow refusal, and frontend disabled-state
  rendering before the platform peer matrix runs.
- Added `build_scripts/unfathomably-release-gate.sh`, a non-interactive
  release gate that runs the federation smoke matrix before unit tests,
  warning gates, package freshness checks, and the final `ready to release`
  confirmation.
- Fixed missing VAPID web-push configuration handling so test and local deployments report absent push keys cleanly instead of crashing instance metadata.
- Fixed incoming top-level posts from group-unaware clients that mention a local
  group as plain `@group@host` text, so Pleroma, Rebased, Mastodon, and similar
  clients can post into groups after following the group actor.
- Fixed ActivityPub follower and following collection rendering to include
  compatibility `count` and `results` aliases alongside OrderedCollection
  fields, improving compatibility with Funkwhale-style actor collection
  parsers during account and group probes.
- Fixed incoming replies from group-unaware clients so replies to known group
  posts inherit the parent group context and appear in the group timeline.
- Fixed the Pleroma/Rebased smoke harness so CLI user creation runs with a
  no-server config while the actual reference servers still boot normally.
- Fixed remote account search normalization so hyphenated domains such as `mastodon-ref.test` survive remote resolution.
- Fixed local group moderator add/remove and group ban/unban API actions so they emit federated ActivityPub moderation activities for Threadiverse peers.
- Fixed group moderation Announces so accepted remote followers receive moderator and ban activity fanout instead of seeing local-only state.
- Fixed Threadiverse group moderation fanout for MBin and PieFed by embedding the moderated activity inside the group Announce, publishing a group profile Update first, and delaying moderation Announces briefly so asynchronous peers can refresh moderator collections before applying Add, Remove, Block, or Undo Block activities.
- Fixed top-level group posts without an explicit title so they derive an ActivityPub `Page.name`, improving MBin and PieFed compatibility.
- Fixed HTTP TLS CA selection so smoke and source deployments respect
  `SSL_CERT_FILE` before falling back to the bundled CA store.
- Fixed chat read endpoints so browser JSON requests with string-key route
  parameters return normal client responses instead of falling through to a
  controller action-clause error.
- Added regression coverage for Pleroma notification mark-read requests that
  receive grouped notification keys, ensuring they fail as client errors rather
  than server errors.
- Deduplicated recent remote object fetch jobs by fetch target and mode,
  including terminal cancelled fetches during a cooldown window, and taught the
  Oban janitor to collapse pre-existing duplicate remote fetch rows so repeated
  reply refreshes cannot flood the remote fetch queue.
- Fixed a remote-fetch queue amplification path by enforcing incomplete-job
  uniqueness at insertion, increasing bounded fetch capacity, and making the
  hourly Oban janitor remove redundant historical jobs while preserving work
  already executing.
- Fixed incoming federation lookups when legacy or idless Create envelopes
  point at the same object, and made Activity inserts conflict-safe so a normal
  concurrent delivery cannot abort its surrounding database transaction.
- Fixed remote actor refreshes that adopt a nickname held by a stale actor
  alias by applying the existing collision-safe rename before updating.
- Fixed websocket status rendering when several legacy Create envelopes point
  at one object, added a cooldown for repeated terminal remote-fetch outcomes,
  and accepted collection pages that remote servers label as collection roots
  while refreshing follower and following counters.
- Fixed remote reply backfills that rapidly retried rate-limited collections,
  and replaced the recursive peer-domain stats scan with a single distinct scan
  that preserves the full peer set without timing out on large user tables.
- Fixed reactions against Tombstones so recipient normalization preserves the
  supplied audience instead of raising when the deleted object has no actor,
  and stopped incoming remote Move activities from invoking the local-account
  move cooldown updater.
- Kept remote-fetch uniqueness complete across Oban's suspended state and
  avoided misleading nickname-race logging when an actor refresh keeps the
  same nickname.
- Fixed the notification receiver fallback so unsupported or fake activities
  return the normal `{enabled, disabled}` tuple shape instead of a bare list,
  avoiding future MatchError-class crashes in notification helper callers.
- Backported and strengthened Pleroma's explicit-mention handling so outgoing
  ActivityPub `Mention` tags are generated from `to` recipients only, preventing
  cc-only delivery recipients from being advertised to remote software as
  human-visible mentions.
- Hardened Mastodon status rendering for titled Page/Article-style objects whose
  ActivityPub `url` arrives as a map, list, or malformed value, and kept nil
  content rendering as an empty string instead of risking a render failure.
- Fixed Mastodon incoming edits whose objects inline `likes` as ActivityStreams collections by dropping the wire-level collection before local object validation.
- Fixed upload metadata extraction for grayscale images so blurhash failures do not discard successfully extracted image dimensions.
- Fixed integer-ID keyset pagination by honoring `:id_type` for `min_id`, `since_id`, and `max_id`, which makes followed-tag pagination and other integer-backed paginated resources advance correctly.
- Fixed frontend archive installation on OTP 27.1+ by skipping archive entries that resolve to directories instead of trying to write them as files.
- Fixed Meilisearch index setup so ranking-rule and searchable-attribute updates use `PUT`, and removed the stale unused `meili_post/2` import from the indexing task.
- Fixed release-task lookup so dotted `pleroma_ctl` task names such as `search.meilisearch` resolve through `Code.ensure_loaded/1`, with regression coverage.
- Stopped rendering local Atom feed alternate links for remote account profile pages.
- Fixed local emoji reactions on remote statuses with no local notification
  target so the notification pipeline returns an empty notification list instead
  of raising a `MatchError` and returning HTTP 500.
- Fixed instance feature metadata so `pleroma:language_detection` is advertised when a language detector provider is configured.
- Fixed RichMedia streaming support for Tesla Finch by adding a Finch adapter helper that maps `stream: true` to Finch's `response: :stream` option.
- Fixed account relationship rendering so `following`, `followed_by`, and `requested` do not report stale follow-request state after the authenticated account already follows the viewed account.
- Fixed ActivityPub language-code validation so newline-tainted values such as `en-US\n` are rejected instead of accepted by a loose end-of-line regex.
- Fixed `GET /api/v1/statuses` compatibility by accepting Mastodon-style `id[]` while keeping the deprecated `ids[]` form.
- Fixed status translation compatibility by accepting Mastodon-style `lang` while preserving deprecated `target_language`.
- Fixed streaming follow-relationship updates so hidden follower and following counts are not leaked when the target account hides those counts.
- Fixed Gun publisher pool race handling so routine `:already_started` and `:pool_full` cases snooze briefly instead of producing noisy failures.
- Fixed remote user profile fields so over-limit remote field arrays are truncated to the configured limit instead of dropping or rejecting the whole field list.
- Fixed marker updates so setting the notifications marker also marks notifications read up to the supplied `last_read_id`.
- Fixed LDAP authentication and automatic registration on newer OTP by starting `:eldap`, accepting both LDAP search-result tuple shapes, and logging structured bind/search failures.
- Fixed queued federation publish cleanup so deletes, unlikes, unboosts, and emoji unreactions cancel undelivered outbound jobs for the affected activity after authorization succeeds.
- Fixed incoming ActivityPub Delete handling so non-validation pipeline errors return normal error tuples instead of leaking worker exceptions.
- Fixed RichMedia preview jobs so deterministic GET, HEAD, content, validation, and malformed URL failures cancel cleanly and negative-cache where appropriate instead of retrying indefinitely.
- Fixed RichMedia preview suppression so posts marked sensitive or tagged `#nsfw` do not generate or cache link previews.
- Fixed reachability cleanup so marking a host reachable can cancel outstanding reachability probe jobs instead of warning about a missing helper.
- Fixed metadata rendering for objects with no summary or content by keeping the empty-string fallback covered by regression tests.
- Fixed newer-Elixir warning noise in feed templates, OAuth/app specs, object maybe-refetch, invite revoke handling, password reset handling, and HTTPSecurity test startup warnings.
- Added `mix pleroma.config fix_mrf_policies` and documentation so stale ConfigDB MRF module entries can be repaired without manual database edits.
- Added ActivityPub alternate-link metadata tags for rendered local profiles and statuses.
- Extended Pleroma, Rebased, and Mastodon smoke coverage to prove account-style
  group follow, receive, like, unlike, reply, delete, top-level mention posting,
  and unfollow behavior for platforms without native group UI.
- Added an S3 uploader `force_media_proxy` option so operators can route stored S3 media URLs through the media proxy instead of exposing the configured public S3 endpoint directly.
- Added an OpenLDAP self-service ACL example for LDAP-backed password changes.
- Added an Oban-backed remote actor refresh worker so stale cached actors refresh asynchronously instead of blocking request and render paths.
- Backported Pleroma/Akkoma `mix pleroma.database prune_objects` options for `--keep-threads`, `--keep-non-public`, and `--prune-orphaned-activities` so large remote-data cleanup can be safer and more selective.
- Added the Mastodon-style dashed /authorize-interaction route alias alongside the existing /authorize_interaction remote interaction path.
- Added the DNSRBL MRF policy from upstream Pleroma, with fail-open resolver handling so local DNS configuration mistakes do not crash federation filtering.
- Added Pleroma's missing foreign-key index migration for relationship and activity lookup paths.
- Added Mastodon-compatible rule hints to instance and admin rule APIs, including schema rendering and a live-safe migration for existing rule tables.
- Added `followers.json` and `following.json` to backup archives, with `actor.json` linking to the archived local collections.
- Added Pleroma upstream `MRF.ForceMention`, with defaults for mentioning parent and quoted-post authors when the policy is enabled.
- Backported Mastodon-compatible followed hashtags, including tag follow/unfollow/list endpoints, home timeline inclusion for public posts with followed tags, and websocket fanout to followed-tag recipients.
- Added startup validation for configured MRF policy modules so missing or incorrectly named policies fail fast instead of silently weakening moderation policy.
- Backported Pleroma's search backend healthcheck worker so unhealthy external search backends pause indexing work until their health endpoint recovers.
- Added FEP-2c59 WebFinger metadata to local ActivityPub actors so compatible peers can discover the actor's acct URI directly from actor JSON.
- Backported Pleroma optional IPFS upload backend support, including gateway configuration metadata and regression coverage for upload, URL, and delete behavior.
- Backported Pleroma synchronized per-application settings storage at `/api/v1/pleroma/settings/:app`, using the existing `pleroma_settings_store` user field and OAuth-scoped read/write access.
- Backported Pleroma's plaintext alternatives for password-reset, invitation, account-confirmation, approval-pending, successful-registration, and account-backup emails so non-HTML mail clients and deliverability checks receive useful message bodies.
- Added a PostgreSQL-compatible remote-peer host index that matches the live
  stats query expression, avoiding repeated sequential scans over remote users
  when refreshing instance peer counts.
- Reworked remote peer stats refreshes to use the compact host index with a
  loose-index scan and slowed the default stats refresh cadence for large
  federation-heavy source installs.

### Changed
- Refreshed the fully resolvable dependency graph for the release gate,
  including castore, h2, hackney, mdex_native, Phoenix, LiveDashboard, and
  WebTransport.
- Classified FediGroups' documented stock limitations in the wide federation
  matrix so unsupported Delete, reaction, threaded-comment, follow, and
  moderation checks are not confused with untested local harness coverage.
- Expanded federation testing documentation with a broad public-platform smoke
  lane for PeerTube, NodeBB, Discourse, FediGroups, Hubzilla, and Friendica.
- Updated Hex dependencies to the newest resolvable releases in the current
  release train, including h2, hackney, hpax, mail, makeup, multipart, quic,
  Swoosh, and WebTransport.
- Relaxed the direct `mail` and optional `multipart` constraints to their
  current release trains so Swoosh adapter support no longer holds the lockfile
  behind.
- Backported Pleroma's ActivityPub actor `published` field so local actors advertise their creation timestamp.
- Backported Pleroma's permanent media-preview redirect behavior so GIF previews and too-small preview candidates return `301` redirects to the media proxy URL.
- Updated OpenBSD nginx ACME documentation to avoid conflicting server names during certificate acquisition.
- Removed the stale StatusNet preload-provider configuration suggestion and corrected the improved hashtag timeline cheatsheet section.
- Hardened translation and language-detection metadata so translated HTML is scrubbed before caching and language-detection features are advertised only when the detector is configured.
- Backported Pleroma's release VM busywait tuning so source releases do not waste CPU while idle.
- Backported Pleroma's auth-backend password-change flow so configured authenticators handle `/api/pleroma/change_password`, including LDAP password updates.
- Updated BSD installation docs to include libvips/vips where media-processing dependencies need it.
- Backported Pleroma's upload-dedupe sharding so new filesystem-backed media paths are spread across stable SHA-256 prefix directories instead of accumulating in one large upload directory.
- Updated OpenBSD service, relayd/httpd, nginx, ACME-renewal, login-class, PostgreSQL SCRAM/UTF-8 database initialization, daemon workdir, and dependency examples with the maintained Pleroma upstream fixes, including the corrected `/media/` alias pattern and permanent HTTP redirects.
- Backported Unix timestamp support for `date_to_asctime/1` so legacy OStatus/TwitterAPI date values emitted as integers or floats render correctly instead of falling back to an empty string.
- Restored the legacy `/api/statusnet/config(.json)` action and backported `site.safeDMMentionsEnabled` so older Pleroma-style clients can discover safe-DM mode.
- Backported reverse-proxy filename hardening so attachment responses parse common filename forms and safely quote the emitted filename.
- Backported HTTP adapter-safety handling in modern Tesla form so adapter exceptions, throws, and exits return ordinary error tuples instead of crashing callers.
- Made RichMedia background jobs unique across the full pending lifetime of the URL job, matching upstream's duplicate-work guard while preserving Unfathomably's richer RichMedia backfill pipeline.
- Backported compatible Pleroma Dialyzer cleanup around ActivityPub pipeline return types, object fetcher error specs, import-worker error wrapping, backup export unreachable branches, and CommonAPI pipeline error pass-through.
- Added Argon2 password-hash verification for Akkoma-style migrations and converted successful Argon2 logins into the local PBKDF2 password format, with regression coverage.
- Hardened LDAP SSL/STARTTLS handling so implicit LDAPS and STARTTLS both use verified certificates and hostname checks by default, support `LDAP_CACERTFILE` / `:cacertfile` CA bundle overrides, and do not continue to bind after a failed STARTTLS upgrade.
- Added direct Swoosh Mua adapter dependencies and exposed `Swoosh.Adapters.Mua` in mailer adapter suggestions.
- Kept Tesla timeout middleware off RichMedia streaming responses while preserving it for the non-streaming fallback fetch path.
- Changed follow/block/mute imports to enqueue one background job per target actor, while preserving backward compatibility for already-queued legacy batch import jobs.
- Exposed avatar and header descriptions under the `pleroma` account extension object while keeping the existing top-level fields as deprecated aliases for compatibility.
- Made outgoing ActivityPub publisher payloads include `cc: []` when the source activity has no carbon-copy recipients, matching upstream Pleroma's compatibility fix without taking the larger publisher job refactor.
- Added `multipart` as a direct optional dependency so Swoosh Mailgun support has the parser dependency it needs when configured.
- Backported Oban operational hardening from upstream Pleroma: removed the unused ingestion queue, raised background/slow queue capacity, moved slow user and instance deletion work into a dedicated delete worker, added bounded worker timeouts, and extended Oban pruner retention while preserving Lifeline.
- Added per-request Tesla middleware support to `Pleroma.HTTP` and used it to enforce configurable RichMedia HTTP timeouts.
- Made backup worker timeout configurable with a 30-minute default.
- Hardened ActivityPub C2S local `Update` validation so local clients can only update objects they are authorized to access, with rejected changesets returning clean 400 responses.
- Made the Mastodon and PieFed federation smoke harnesses more robust by using a local trusted smoke CA, avoiding executable-bit assumptions, and bounding PieFed queue-drain commands.
- Extended the PieFed federation smoke harness to resolve group-ban target actors before moderation checks, matching PieFed's requirement that banned users already be known locally before community-ban modlog entries can be applied.
- Extended Lemmy, MBin, and PieFed smoke coverage to prove local groups are advertised through the Lemmy-compatible community list and that Unfathomably group search can discover their remote communities before follow tests begin.
- Completed the reopened historical Pleroma upstream audit through row 15431, closing the 2022-2023 Rebased lineage window with explicit dispositions for every non-ancestor exception and keeping the native Vips media-preview branch deferred.
- Made the AntiMentionSpam account-age threshold configurable instead of hard-coding the upstream default.
- Rebalanced HTTP/Gun pool sizing for federation, media, uploads, and default traffic while keeping the dedicated rich-media pool.
- Removed unused RichMedia and MediaProxyWarming concurrent limiter processes after the upstream pool refactor.
- Advanced the reopened historical Pleroma upstream audit cursor through row 14800 with per-commit ancestry proof, including the inherited GoToSocial key-resolution fix.
- Aligned with upstream's object actor-strip revert so embedded object `actor` fields are preserved for compatibility.
- Backported Pleroma's PleromaAPI notification-read behavior so marking notifications read returns a simple `"ok"` response instead of re-rendering notification payloads.
- Enhanced request logging metadata for inbound ActivityPub inboxes and authenticated requests so federation logs include actor/type/path/user context without carrying low-value request IDs.
- Backported the PostgreSQL 11+ baseline cleanup by disabling PostgreSQL JIT in repo parameters, removing startup-time PostgreSQL version probing, and using `websearch_to_tsquery` directly for database search.
- Backported Pleroma's `CastAndValidate` `replace_params` option support so controllers can validate OpenAPI bodies without replacing Plug request params.
- Backported Pleroma's Dialyzer-oriented typespec cleanup across bookmarks, chats, reports, streaming, uploads, OAuth token queries, rich media, bare URI validation, and related helpers.
- Backported Pleroma's Finch redirect middleware handling and full Tesla response preservation for retryable publisher HTTP failures.
- Backported Pleroma's shared CIDR parsing helper for RemoteIp and authorized-fetch exception handling.
- Backported Pleroma's runtime-configurable test emoji loading so emoji fixtures are controlled by loader config instead of a compile-time environment branch.
- Backported Pleroma's runtime streamer send gate so stream delivery decisions use application configuration instead of a compile-time environment branch.
- Backported Pleroma's runtime-configurable uploader callback timeout so upload backend callbacks no longer depend on a compile-time Mix environment branch.
- Backported Pleroma's runtime-configurable application supervision switches so tests and smoke stacks can disable custom module loading, internal fetch initialization, background migrators, streamer registry, and all-HTTP-pool startup without compile-time environment branches.
- Kept Unfathomably's broader Misskey-family quote compatibility by retaining `_misskey_quote` emission alongside `quoteUri`, despite upstream Pleroma later dropping that extra field.
- Matched Pleroma's final media-host-validation state by not retaining the intermediate uploaded-media Host header check, avoiding breakage for alternate media-domain and reverse-proxy deployments while preserving signed media URL/path checks and sandbox headers.
- Corrected the upstream report-notification demotion audit to follow Pleroma's final query-side visibility guard instead of retaining the reverted notification-deletion hook.
- Backported Pleroma's object fetcher bang-helper cleanup so remote object normalization uses the explicit non-bang fetch result path while preserving Unfathomably's quieter transient fetch logging.
- Removed the stale `Quack.Logger` admin-config suggestion now that the Quack backend has been removed from the dependency set and ConfigDB migration path.
- Filled out Mastodon-compatible instance metadata and OpenAPI descriptions for URL character reservation, pinned-status limits, featured-tag limits, and card image descriptions.
- Tightened the default Content-Security-Policy script source so unsafe eval and wasm eval are only emitted when `:http_security, :allow_unsafe_eval` is explicitly enabled.
- Filled out Mastodon-compatible v2 instance metadata with registration URL, status URL, featured-tag limits, supported-media placeholders, and existing VAPID/translation details.
- Moved new-user digest cron work onto the background Oban queue and removed the obsolete `new_users_digest` queue entry, matching upstream Pleroma queue consolidation.
- Followed upstream Pleroma's later full revert of uploaded-media Host-header validation, avoiding alternate-domain and reverse-proxy media breakage while retaining path-safe media handling.
- Followed upstream's row-14128 revert of the temporary slow-query telemetry branch, removing the disabled-by-default hook added during the previous audit slice instead of carrying a feature upstream backed out.
- Regenerated `docs/UPSTREAM_PLEROMA_FULL_MANIFEST.md` as a compact one-row-per-upstream-commit ledger with explicit reviewed ranges, removing duplicated audit-note blocks so future Pleroma backport passes resume from a stable next-row cursor.
- Replaced stale Prometheus metrics documentation for the old `prometheus_ex` `/api/pleroma/app_metrics` path with the current PromEx `/api/metrics` endpoint and bearer-token setup.
- Kept the default source-install database pool size aligned with PostgreSQL
  limits instead of forcing the historical Soapbox dangerzone pool override
  from the shared Unfathomably defaults.

### Fixed
- Made incoming-federation regression suites explicitly enable federation so
  randomized and isolated release-test batches cannot depend on configuration
  leaked by another module.
- Fixed the admin configuration OpenAPI schema to accept floating-point JSON
  values, aligned anonymous admin tests with the 401 authentication contract,
  and refreshed admin account fixtures for alias and move metadata.
- Fixed remote ActivityPub Update side effects so omitted local-delivery
  metadata is treated as remote instead of raising during quote-authorization
  reconciliation.
- Preserved PieFed PollVote audiences on both the generated Create activity and
  its Answer object so valid audience-bearing votes pass strict addressing
  validation.
- Fixed account unfollow cleanup when a compatibility follow relationship has
  no stored `Follow` activity, so cleanup succeeds instead of returning a 500
  after removing the relationship.
- Fixed ActivityPub actor content negotiation on bare profile URLs so ActivityPub
  clients requesting actor JSON no longer receive frontend HTML.
- Fixed ActivityPub object fetches for deleted local objects so peers receive a
  `410 Gone` Tombstone response instead of a generic 404 while processing
  federated Delete activities.
- Fixed outgoing local group-root post compatibility with Discourse category
  actors by emitting Article objects for known Discourse groups while preserving
  Page objects for Threadiverse-style group peers.
- Cleaned formatting, alias ordering, numeric literal style, and line-ending
  drift so strict compile, format, and Credo validation stays clean under the
  current OTP 28 and Elixir 1.20 toolchain.
- Fixed frontend archive installation on OTP 27.1+ by skipping archive entries that resolve to directories instead of trying to write them as files.
- Removed UTF-8 BOMs from Elixir source/config files and restored corrupted controller sources that newer Elixir releases rejected or warned about during live compilation.
- Backported Pleroma's poll notification streaming improvements so completed poll notifications are created without duplicate immediate delivery and then streamed/pushed by the poll worker.
- Backported Pleroma's stricter VAPID configuration check and web-push user loading fix so push delivery no longer treats partial key configuration as enabled or requires a preloaded notification user.
- Backported Pleroma's media-proxy whitelist fallback, strict API request-path logging, `prune_code_paths: false` mix option, and PNG metadata stripping hardening.
- Removed stale MediaProxyWarmingPolicy ConcurrentLimiter configuration and synchronous test-only branching so media warming follows the upstream pool-refactor shape.
- Backported Pleroma DNSRBL, Web Push, IDNA, OAuth token, database search, and upload-filter type/spec cleanups from the May 2024 dialyzer pass.
- Backported Pleroma IPFS uploader hardening so multipart uploads use the upload HTTP pool, parse Tesla `status` correctly on delete, and report malformed gateway responses cleanly.
- Backported Pleroma's GenerateUnsetUserKeys migration safety fix so the historical migration uses a migration-local user schema instead of depending on the current Pleroma.User schema.
- Backported Pleroma's Repo.exists?-based rule validation helper so report rule_ids can be checked without loading every referenced rule.
- Fixed media proxy preview and helper fetches to respect configured HTTP client options instead of bypassing per-pool proxy settings.
- Fixed reverse proxy streaming compatibility so Cowboy-backed responses can preserve content length while other adapters keep safe chunked semantics.
- Fixed strict ApiSpec validation logging and documented missing admin notification API types for easier client/debug compatibility work.
- Fixed fake-activity notification fallback helpers to return empty receiver lists in the same shape upstream expects.
- Backported Pleroma's `pleroma_ctl` portability fix to use `realpath` instead of GNU-specific `readlink -f`.
- Stripped internal `actor` copies from outbound ActivityPub object payloads before federation, matching upstream Pleroma compatibility hardening while preserving local object storage.
- Fixed notification domain-block filtering so the relationship helper filters on the joined user actor instead of the raw activity actor binding.
- Backported Pleroma's OAuth authorization template handle rendering through `User.full_nickname/1`.
- Restored corrupted `Pleroma.Web` module references in the admin instance-document and Mastodon domain-block controllers.
- Completed object-fetch atomization for HTTP 404/410 responses by returning :not_found and keeping affected remote user/follow-counter logging at debug level.
- Completed runtime support for :activitypub, :authorized_fetch_mode_exceptions so controlled CIDR/IP exceptions are honored before unsigned ActivityPub fetches are rejected.
- Removed the stale Exiftool ReadDescription filter spec that no longer matched the upload filter callback shape.
- Fixed cached public-key helper lookups and optimistic inbox retry enqueue priority so cached users are matched correctly and Oban receives supported priorities.
- Backported Pleroma's concurrent quoteUrl object-index migration safety by disabling the migration transaction and creating the index concurrently.
- Removed stale startup checks requiring ImageMagick `mogrify` and `convert` for AnalyzeMetadata; the filter now only requires `ffprobe` in the application requirement check.
- Backported Pleroma's MRF policy module-loading guard before policy filtering and config-description introspection.
- Finished the scrobble/listen `externalLink` backport so new listens store `externalLink`, legacy `url` inputs still work, and responses expose both fields for compatibility.
- Improved chat message posting, mascot uploads, admin activation responses, and profile-directory auth skipping after the upstream Dialyzer/controller pass so client failures return explicit errors instead of opaque controller misses.
- Fixed multiple Admin, Pleroma, Twitter, and Mastodon API controllers to accept string-keyed OpenAPI-cast request bodies for affected JSON and multipart endpoints, preventing valid requests from falling through to function-clause errors.
- Fixed HTTP signature key-id fallback actor resolution so WebFinger results are matched against the current `{:ok, result}` return shape.
- Improved ActivityPub Delete side-effect diagnostics by distinguishing object deletion failures, missing deleted-object actors, and actor IDs that cannot resolve to local users.
- Hardened announcement changeset handling by backporting Pleroma's changeset entrypoint and safely accepting missing or string-keyed announcement data maps without crashing.
- Backported Pleroma's background migrator fault-rate cleanup so no-failure migration stats report 0 instead of :error.
- Fixed quote posting so quoting a status no longer implicitly mentions the
  original poster.
- Fixed server-generated frontend metadata so fallback-rendered pages advertise
  the configured favicon and /manifest.json PWA manifest.
- Backported Pleroma status language rendering so Mastodon API statuses return `null` for undetermined ActivityPub language values instead of exposing `"und"`.
- Backported Pleroma's notification enum down-migration fix so rollback recreates both `poll` and `update` notification values correctly.
- Updated rel=me metadata generation to match Pleroma's final profile-field behavior by appending profile field HTML to the bio before parsing, so profile-field rel=me links use the same selector path as bio links.
- Confirmed Pleroma's Delete side-effect notification suppression is already present, while preserving Unfathomably's intentional group and event Join notifications.
- Backported Pleroma's outbound publisher 401 handling so permanently unauthorized inbox deliveries discard cleanly instead of retrying as transient failures.
- Backported Pleroma's QTFastStart bitstring-match hardening so malformed video atoms abort fast-start rewriting and fall back to the original binary instead of raising.
- Fixed Rich Media TTL handling for Amazon URLs without query parameters so nil queries do not raise during signed-URL detection.- Corrected the remote-fetcher reachability backport so explicit remote fetch jobs can retry hosts marked unreachable while deterministic terminal misses still cancel cleanly.
- Backported Pleroma config-permission and reverse-proxy header hardening so release config checks follow symlinks and proxied responses do not forward stale upstream content-length headers.
- Backported Pleroma atom-leak fixes for PBKDF2 digest selection and import background workers by resolving only existing atoms.
- Backported Pleroma notification filtering and ReceiverWorker error wrapping fixes so notification block checks use the joined actor row and non-ok incoming federation results cannot be treated as success.
- Expanded ActivityPub empty-value filtering to drop empty lists and maps when repairing object defaults, matching newer upstream cleanup behavior.
- Cached failed media-helper framegrab URLs briefly so repeated broken video preview attempts do not keep spawning ffmpeg work.
- Backported additional Pleroma remote-fetch terminal handling so max-depth, forbidden, deleted, and deterministic remote object misses cancel cleanly, while explicit remote-fetch jobs can still probe hosts currently marked unreachable.
- Backported Pleroma signed-inbox inactive actor guards so deactivated recipients or senders receive clear bad-request responses instead of risking with-clause failures.
- Backported Pleroma account-rendering self-check behavior so hidden follow counters stay visible to the account owner even after profile HTML sanitization.
- Backported Pleroma MRF and emoji edge-case fixes for invalid subdomain regex diagnostics and extensionless stolen remote emoji filenames.
- Backported Pleroma OAuthPlug cached-user lookup cleanup so bearer-token authentication no longer performs an unused user preload before reading the cached user record.
- Backported Pleroma's Mastodon-compatible account lookup behavior so `/api/v1/accounts/lookup` skips auth and account visibility checks while retaining Unfathomably's remote group/source-aware lookup fallback.
- Backported Pleroma's StatusView stream-rendering guard so activities whose object is not loaded return `nil` through the existing safe-render path instead of crashing websocket/event rendering.
- Restored the legacy `chat:public` shout channel module behind a disabled-by-default `:shout` configuration so the existing socket route is complete without unexpectedly enabling the old public shoutbox.
- Fixed instance metadata background-image URL rendering so `/api/v1/instance` and `/api/v2/instance` preserve absolute configured URLs while still expanding local relative paths.
- Fixed AP C2S Note length validation so the configured character limit is inclusive, matching Mastodon/Pleroma expectations while still rejecting over-limit posts.
- Backported Pleroma chat-index hardening so chats whose recipient user has been deleted are filtered before rendering, matching the existing deleted-recipient regression coverage and preventing nil account rendering crashes.
- Removed fragile compile-time imports and module-plug compile dependencies from ActivityPub validators, webhook notification dispatch, and controllers so clean production compiles do not trip dependency cycles after source promotion.
- Normalized account registration reasons through the User registration changeset so all registration paths strip HTML before pending-account review storage.
- Fixed the API scope translator module so gettext placeholder macros compile without warnings under the current Elixir toolchain.
- Added actor_account_id as a deprecated alias for chat message account_id, matching older Pleroma chat API clients without changing the current response shape.
- Restored the deprecated /api/statusnet/config(.json) compatibility endpoint and legacy NodeInfo metadata.characterLimit / metadata.vapidPublicKey aliases for older Pleroma-style clients.
- Backported Pleroma's RemoteIp-aware rate-limiter fallback so missing forwarded client IP metadata disables that limiter path with a clear warning instead of rate-limiting all proxied visitors as localhost.
- Backported Pleroma's localhost/socket rate-limiter bypass so deployments bound
  to loopback without `RemoteIp` do not throttle every client behind the reverse
  proxy.
- Cleaned a stale API spec gettext require so production compilation stays
  warning-free after the rate-limiter backport.
- Fixed direct-conversation read acknowledgements so marking a conversation as
  read no longer refreshes its `updated_at` timestamp or moves it to the top of
  the conversation list.
- Backported Pleroma's ActivityPub content-type helper cleanup for local group featured and moderators collections so JSON content types keep the expected charset handling.
- Backported Pleroma's default `:instance, :chat_limit` configuration and ConfigDB description so local chat-message length enforcement always has a safe default.
- Fixed addressed inbox handling for servers that send the ActivityPub actor as an embedded object instead of a bare actor URI.
- Fixed WebFinger resolution for leading-`@` group and feed handles, and preserved actor outbox URLs for source previews discovered through WebFinger.
- Stopped feed list rendering from performing synchronous NodeInfo refreshes for hosts whose cached instance metadata is blank.
- Fixed OpenTranslate requests for posts with unknown source languages by using provider auto-detection instead of an empty source language, and by pre-detecting obvious non-Latin scripts before OpenTranslate can misread HTML as English.
- Hardened Kocaptcha validation so missing or malformed answer data returns an invalid captcha result instead of raising.
- Fixed lingering incoming federation retries from uncached object-action
  context normalization and remote featured-collection pin-limit failures so
  the receiver worker and Oban janitor classify them as terminal instead of
  retrying stale jobs.
- Fixed VAPID web-push enabled detection so valid runtime configuration is not
  mistaken for missing keys when ConfigDB or runtime loading changes keyword
  ordering or representation.
- Fixed FEP-e232 quote discovery for the specification's optional-`rel` form
  while keeping unrelated ActivityPub object links out of quote handling.
- Kept the remote post-size compatibility limit from rejecting valid local
  posts, which already pass through the instance's local character limit.
- Stopped canonicalized ActivityPub input aliases such as GoToSocial's legacy
  `approvedBy` from being restored by generic extension preservation.
- Preserved distinct Event group attribution through normalization so
  Mobilizon-style service actors can attribute events to valid same-host Group
  actors without allowing cross-host or ordinary-account claims.
- Allowed a Create actor to match a validated object's explicit actor when the
  object separately names a safe attribution, completing service-owned Event
  delivery without loosening ordinary status ownership checks.

### Security
- Wired the InboxGuard-style ActivityPub inbox guard into the runtime inbox pipeline, rejecting unsupported activity types early and limiting unsigned unknown-actor first contact to a narrow allowlist that still preserves Unfathomably group/source compatibility.
- Removed Logger runtime configuration from ConfigDB/AdminFE-facing descriptions and added a cleanup migration for persisted `:logger` ConfigDB rows, matching upstream Pleroma's hardening against live logger reconfiguration.
- Backported Pleroma's XML entity-resolution hardening by explicitly disabling entity expansion during XML parsing.
- Hardened PromEx metrics access so `/api/metrics` fails closed unless an explicit bearer token is configured, uses safe token comparison, and preserves unauthenticated metrics only as a deliberate source-config opt-in for trusted private deployments.

## [2.6.51] - 2026-06-25

### Fixed
- Reduced incoming federation retry noise by acknowledging Friendica-style `View` and `Read` receipt activities as no-op receipts.
- Fixed event API rendering so event banners and attachment links reuse the already-rendered media-proxied attachment data instead of exposing raw remote image URLs to the frontend.
- Fixed group and source list rendering so list pages use cached group counters and skip unused per-row interaction-score queries.
- Fixed remote group detail timelines so cached posts render without a synchronous remote collection refresh, embedded status group cards skip per-status interaction score queries, and uncached remote backfill work is capped to avoid minute-long page stalls.
- Fixed media proxy image failures so dead remote images can render a short-lived local placeholder instead of redirecting browsers to the original remote URL or producing noisy failed image loads.

### Changed
- Refreshed release metadata for the quiet backend compatibility, federation-health, and janitor work since 2.6.50.
- Added offset handling to federated group/source listing helpers so clients can page large source lists instead of requesting everything at once.
- Added `/api/v1/feeds` and `/api/v1/timelines/feeds` aliases for the source APIs and tightened feed classification so ordinary remote profiles stay in normal social timelines instead of the feed surface.

## [2.6.50] - 2026-06-23

### Added
- Introduced Unfathomably backend branding, package metadata, documentation links, and GitHub repository links.
- Added first-class group and source APIs for federated targets that do not behave like ordinary user accounts.
- Added group and source preview/feed support for Threadiverse-style and media-source actors.
- Added RSS and Atom feed following through synthetic source actors and scheduled refresh workers, so read-only feed entries can appear as posts that local users can boost or quote.
- Added local group membership support and group moderation surfaces.
- Added Mastodon-compatible websocket streaming support and broader streaming tests.
- Added remote replies collection refresh jobs for public remote posts, including debounced refreshes when known ancestors receive remote replies.
- Added ActivityPub alternate discovery from HTTP `Link` headers and HTML `rel="alternate"` links when object fetches land on human-readable pages.
- Added Ed25519 HTTP Signature verification for remote actors that publish W3C Multikey `publicKeyMultibase` keys or OKP `publicKeyJwk` verification methods.
- Added Mbin-compatible group collection metadata for remote and local group actors, including outbox, moderators, featured/pinned items, indexability, and moderator-only posting hints.
- Added cached remote group moderator counts from Mbin-style `attributedTo` moderator collections and exposed them in the group API.
- Added a local ActivityPub moderators collection endpoint for group actors that advertise `attributedTo`.
- Added first-class handling for Mbin-style `Lock` activities so remote software can close and reopen discussion threads.
- Added authorized Mbin-style moderator collection handling for local groups, so valid `Add`/`Remove` activities can update local group moderator roles.
- Improved Threadiverse group audience detection so public posts addressed through `audience`, `cc`, nested objects, or PeerTube-style `attributedTo` group arrays can be associated with the right local group.
- Added OpenTranslate/LibreTranslate-style translation provider documentation and Polish model coverage notes.
- Added a complete source installation guide covering Unfathomably BE, Unfathomably FE, nginx, OpenTranslate, and optional Meilisearch.
- Added a rehearsed upgrade guide for moving source installs from Rebased/Soapbox or Pleroma to Unfathomably BE and FE.
- Added Meilisearch indexing and cleanup integration for post search.
- Added janitor workers for stale remote group discussions, stale remote posts, old Oban jobs, and dormant remote-host reachability checks.

### Changed
- Updated project metadata to publish as `unfathomably-be` while retaining Pleroma-compatible module and OTP application names where clients and release tooling depend on them.
- Updated ActivityPub follower and following collection rendering to use cached counters and SQL pagination instead of loading whole collections for page rendering.
- Improved HTTP Signature key resolution for multi-key actors, separate key documents, and `verificationMethod`/`assertionMethod` style actor documents while preserving the existing RSA PEM path.
- Scoped HTTP-only fetch-origin behavior to development and test use so public production deployments keep secure fetch-origin defaults.
- Improved static-fe styling so backend-rendered post pages follow the configured site theme more closely.
- Reworked NodeInfo compatibility so Mastodon-style consumers do not need to rely on fallback behavior.

### Fixed
- Fixed remote group and source display paths that could fall back to local profile timelines.
- Fixed remote group and source item behavior so comments, likes, shares, and supported interactions can be exposed where the remote software allows them.
- Fixed remote reply discovery for group discussions where comments existed remotely but were not visible locally.
- Fixed incoming signature actor mapping for key IDs that point at separate key documents rather than the actor URL itself.
- Fixed duplicate follow insertion handling so cached follow counters are not recalculated unnecessarily.
- Fixed browser-facing issues around static asset MIME types, stale composer drafts, duplicate form IDs, and unsupported Permissions-Policy feature names.
- Fixed profile and refresh-route handling that could return server errors on deep frontend routes.
- Fixed incoming ActivityPub retry noise by treating permanent validation changeset failures as cancelled jobs and giving remote-context fetches a longer receiver timeout.
- Fixed Oban janitor cleanup for terminal incoming federation retries caused by unreachable ActivityPub objects, HTML responses, duplicate inserts, or unsafe remote update actors.
- Fixed remote object fetch races where concurrent fetches could log duplicate object insert warnings instead of returning the already-cached object.
- Fixed wrapped opaque incoming federation failures so dead remote Undo activities are cancelled instead of retrying as `{:error, :error}` forever.
- Fixed remote follow-counter refresh for NodeBB-style idless ActivityPub collections and slow partial collection responses such as Minds.
- Fixed federated target platform hints for Discourse AP actors, WordPress ActivityPub inboxes, Friendica forums, Gancio federation actors, and Lotide/Narwhal communities so working remote groups and sources keep their expected UI shape.
- Fixed Mbin HTML fallback previews to use the canonical ActivityPub thread URL as the object ID, allowing previewed magazine posts to resolve as interactable statuses when the remote serves ActivityPub JSON.
- Fixed Mbin-style group `Announce` handling so wrapped Create, Add, Remove, Like, Dislike, Undo, and Lock activities are treated as the underlying group operation rather than ordinary boosts.
- Fixed Mbin-style group `Announce` handling for wrapped Update activities.
- Fixed incoming `commentsEnabled` preservation so remote group software can accurately expose locked or open discussion threads to clients.
- Fixed stale remote actor refreshes that return an ActivityPub `Tombstone` so cached remote actors are deactivated locally instead of staying active with failed refresh noise.
- Fixed malformed cached remote public keys so signature validation fails cleanly and can fall into the retry/refresh path instead of raising from PEM decoding.
- Improved remote actor key rotation handling by preserving a bounded history of previous valid public keys and trying them as a fallback for stale signed requests.
- Reduced group/source feed query overhead by reusing cached follow lists for blocked-domain visibility checks.
- Fixed preview status resolution for remote thread mirrors whose human URL negotiates to ActivityPub with a different canonical object ID, including a guarded synthetic Create fallback for object-only previews.
- Fixed source/feed platform hints for WriteFreely collections, GoToSocial `gts.*` hosts, snac actors, verified Iceshrimp instances with opaque actor URLs, Owncast federation users, and Calckey/Misskey-family actors, allowed signed collection fetch fallback for protected source outboxes, and added cached actor-card fallback when a known profile source cannot expose preview items.
## 2.6.0

### Security

- Preload: Make generated JSON html-safe. It already was html safe because it only consists of config data that is base64 encoded, but this will keep it safe it that ever changes.
- CommonAPI: Prevent users from accessing media of other users by creating a status with reused attachment ID
- Disable XML entity resolution completely to fix a dos vulnerability

### Added

- Support for Image activities, namely from Hubzilla
- Add OAuth scope descriptions
- Allow lang attribute in status text
- OnlyMedia Upload Filter
- Implement MRF policy to reject or delist according to emojis
- (hardening) Add no_new_privs=yes to OpenRC service files
- Implement quotes
- Add unified streaming endpoint

### Fixed

- rel="me" was missing its cache
- MediaProxy responses now return a sandbox CSP header
- Filter context activities using Visibility.visible_for_user?
- UploadedMedia: Add missing disposition_type to Content-Disposition
- fix not being able to fetch flash file from remote instance
- Fix abnormal behaviour when refetching a poll
- Allow non-HTTP(s) URIs in "url" fields for compatibility with "FEP-fffd: Proxy Objects"
- Fix opengraph and twitter card meta tags
- ForceMentionsInContent: fix double mentions for Mastodon/Misskey posts
- OEmbed HTML tags are now filtered
- Restrict attachments to only uploaded files only
- Fix error 404 when deleting status of a banned user
- Fix config ownership in dockerfile to pass restriction test
- Fix user fetch completely broken if featured collection is not in a supported form
- Correctly handle the situation when a poll has both "anyOf" and "oneOf" but one of them being empty
- Fix handling report from a deactivated user
- Prevent using the .json format to bypass authorized fetch mode
- Fix mentioning punycode domains when using Markdown
- Show more informative errors when profile exceeds char limits

### Removed

- BREAKING: Support for passwords generated with `crypt(3)` (Gnu Social migration artifact)
- remove BBS/SSH feature, replaced by an external bridge.
- Remove a few unused indexes.
- Cleanup OStatus-era user upgrades and ap_enabled indicator
- Deprecate Pleroma's audio scrobbling

## 2.5.4

## Security

- Fix XML External Entity (XXE) loading vulnerability allowing to fetch arbitrary files from the server's filesystem

## 2.5.3

### Security

- Emoji pack loader sanitizes pack names
- Reduced permissions of config files and directories, distros requiring greater permissions like group-read need to pre-create the directories

## 2.5.5

## Security

- Prevent users from accessing media of other users by creating a status with reused attachment ID

## 2.5.4

## Security

- Fix XML External Entity (XXE) loading vulnerability allowing to fetch arbitrary files from the server's filesystem

## 2.5.3

### Security

- Emoji pack loader sanitizes pack names
- Reduced permissions of config files and directories, distros requiring greater permissions like group-read need to pre-create the directories

## 2.5.2

### Security

- `/proxy` endpoint now sets a Content-Security-Policy (sandbox)
- WebSocket endpoint now respects unauthenticated restrictions for streams of public posts
- OEmbed HTML tags are now filtered

### Changed

- docs: Be more explicit about the level of compatibility of OTP releases
- Set default background worker timeout to 15 minutes

### Fixed

- Atom/RSS formatting (HTML truncation, published, missing summary)
- Remove `static_fe` pipeline for `/users/:nickname/feed`
- Stop oban from retrying if validating errors occur when processing incoming data
- Make sure object refetching as used by already received polls follows MRF rules

### Removed

- BREAKING: Support for passwords generated with `crypt(3)` (Gnu Social migration artifact)

## 2.5.1

### Added

- Allow customizing instance languages

### Fixed

- Security: uploading HTTP endpoint can no longer create directories in the upload dir (internal APIs, like backup, still can do it.)
- ~ character in urls in Markdown posts are handled properly
- Exiftool upload filter will now ignore SVG files
- Fix `block_from_stranger` setting
- Fix rel="me"
- Docker images will now run properly
- Fix improper content being cached in report content
- Notification filter on object content will not operate on the ones that inherently have no content
- ZWNJ and double dots in links are parsed properly for Plain-text posts
- OTP releases will work on systems with a newer libcrypt
- Errors when running Exiftool.ReadDescription filter will not be filled into the image description

## 2.5.0 - 2022-12-23

### Removed

- MastoFE
- Quack, the logging backend that pushes to Slack channels

### Changed

- **Breaking:** Elixir >=1.11 is now required (was >= 1.9)
- Allow users to remove their emails if instance does not need email to register
- Uploadfilter `Pleroma.Upload.Filter.Exiftool` has been renamed to `Pleroma.Upload.Filter.Exiftool.StripLocation`
- **Breaking**: `/api/v1/pleroma/backups` endpoints now requires `read:backups` scope instead of `read:accounts`
- Updated the recommended pleroma.vcl configuration for Varnish to target Varnish 7.0+
- Set timeout values for Oban queues. The default is infinity and some operations may not time out on their own.
- Delete activities are federated at lowest priority
- CSP now includes wasm-unsafe-eval

### Added

- `activeMonth` and `activeHalfyear` fields in NodeInfo usage.users object
- Experimental support for Finch. Put `config :tesla, :adapter, {Tesla.Adapter.Finch, name: MyFinch}` in your secrets file to use it. Reverse Proxy will still use Hackney.
- `ForceMentionsInPostContent` MRF policy
- PleromaAPI: Add remote follow API endpoint at `POST /api/v1/pleroma/remote_interaction`
- MastoAPI: Add `GET /api/v1/accounts/lookup`
- MastoAPI: Profile Directory support
- MastoAPI: Support v2 Suggestions (handpicked accounts only)
- Ability to log slow Ecto queries by configuring `:pleroma, :telemetry, :slow_queries_logging`
- Added Phoenix LiveDashboard at `/phoenix/live_dashboard`
- Added `/manifest.json` for progressive web apps.
- MastoAPI: Support for `birthday` and `show_birthday` field in `/api/v1/accounts/update_credentials`.
- Configuration: Add `birthday_required` and `birthday_min_age` settings to provide a way to require users to enter their birth date.
- PleromaAPI: Add `GET /api/v1/pleroma/birthdays` API endpoint
- Make backend-rendered pages translatable. This includes emails. Pages returned as a HTTP response are translated using the language specified in the `userLanguage` cookie, or the `Accept-Language` header. Emails are translated using the `language` field when registering. This language can be changed by `PATCH /api/v1/accounts/update_credentials` with the `language` field.
- Add fine grained options to provide privileges to moderators and admins (e.g. delete messages, manage reports...)
- Uploadfilter `Pleroma.Upload.Filter.Exiftool.ReadDescription` returns description values to the FE so they can pre fill the image description field
- Added move account API
- Enable remote users to interact with posts
- Possibility to discover users like `user@example.org`, while Pleroma is working on `pleroma.example.org`. Additional configuration required.

### Fixed

- Subscription(Bell) Notifications: Don't create from Pipeline Ingested replies
- Handle Reject for already-accepted Follows properly
- Display OpenGraph data on alternative notice routes.
- Fix replies count for remote replies
- Fixed hashtags disappearing from the end of lines when Markdown is enabled
- ChatAPI: Add link headers
- Limited number of search results to 40 to prevent DoS attacks
- ActivityPub: fixed federation of attachment dimensions
- Fixed benchmarks
- Elixir 1.13 support
- Fixed crash when pinned_objects is nil
- Fixed slow timelines when there are a lot of deactivated users
- Fixed account deletion API
- Fixed lowercase HTTP HEAD method in the Media Proxy Preview code
- Removed useless notification call on Delete activities
- Improved performance for filtering out deactivated and invisible users
- RSS and Atom feeds for users work again
- TwitterCard meta tags conformance

## 2.4.5 - 2022-11-27

## Fixed

- Image `class` attributes not being scrubbed, allowing to exploit frontend special classes [!3792](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3792)
- Delete report notifs when demoting from superuser [!3642](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3642)
- Validate `mediaType` only by it's format rather than using a list [!3597](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3597)
- Pagination: Make mutes and blocks lists behave the same as other lists [!3693](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3693)
- Compatibility with Elixir 1.14 [!3740](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3740)
- Frontend installer: FediFE build URL [!3736](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3736)
- Streaming: Don't stream ChatMessage into the home timeline [!3738](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3738)
- Streaming: Stream local-only posts in the local timeline [!3738](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3738)
- Signatures: Fix `keyId` lookup for GoToSocial [!3725](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3725)
- Validator: Fix `replies` handling for GoToSocial [!3725](https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3725)

## 2.4.4 - 2022-08-19

### Security

- Streaming API sessions will now properly disconnect if the corresponding token is revoked

## 2.4.3 - 2022-05-06

### Security

- Private `/objects/` and `/activities/` leaking if cached by authenticated user
- SweetXML library DTD bomb

## 2.4.2 - 2022-01-10

### Fixed

- Federation issues caused by HTTP pool checkout timeouts
- Compatibility with Elixir 1.13

### Upgrade notes

1. Restart Pleroma

## 2.4.1 - 2021-08-29

### Changed

- Make `mix pleroma.database set_text_search_config` run concurrently and indefinitely

### Added

- AdminAPI: Missing configuration description for StealEmojiPolicy

### Fixed

- MastodonAPI: Stream out Create activities
- MRF ObjectAgePolicy: Fix pattern matching on "published"
- TwitterAPI: Make `change_password` and `change_email` require params on body instead of query
- Subscription(Bell) Notifications: Don't create from Pipeline Ingested replies
- AdminAPI: Fix rendering reports containing a `nil` object
- Mastodon API: Activity Search fallbacks on status fetching after a DB Timeout/Error
- Mastodon API: Fix crash in Streamer related to reblogging
- AdminAPI: List available frontends when `static/frontends` folder is missing
- Make activity search properly use language-aware GIN indexes
- AdminAPI: Fix suggestions for MRF Policies

## 2.4.0 - 2021-08-08

### Changed

- **Breaking:** Configuration: `:chat, enabled` moved to `:shout, enabled` and `:instance, chat_limit` moved to `:shout, limit`
- **Breaking** Entries for simple_policy, transparency_exclusions and quarantined_instances now list both the instance and a reason.
- Support for Erlang/OTP 24
- The `application` metadata returned with statuses is no longer hardcoded. Apps that want to display these details will now have valid data for new posts after this change.
- HTTPSecurityPlug now sends a response header to opt out of Google's FLoC (Federated Learning of Cohorts) targeted advertising.
- Email address is now returned if requesting user is the owner of the user account so it can be exposed in client and FE user settings UIs.
- Improved Twittercard and OpenGraph meta tag generation including thumbnails and image dimension metadata when available.
- AdminAPI: sort users so the newest are at the top.
- ActivityPub Client-to-Server(C2S): Limitation on the type of Activity/Object are lifted as they are now passed through ObjectValidators
- MRF (`AntiFollowbotPolicy`): Bot accounts are now also considered followbots. Users can still allow bots to follow them by first following the bot.

### Added

- MRF (`FollowBotPolicy`): New MRF Policy which makes a designated local Bot account attempt to follow all users in public Notes received by your instance. Users who require approving follower requests or have #nobot in their profile are excluded.
- Return OAuth token `id` (primary key) in POST `/oauth/token`.
- AdminAPI: return `created_at` date with users.
- AdminAPI: add DELETE `/api/v1/pleroma/admin/instances/:instance` to delete all content from a remote instance.
- `AnalyzeMetadata` upload filter for extracting image/video attachment dimensions and generating blurhashes for images. Blurhashes for videos are not generated at this time.
- Attachment dimensions and blurhashes are federated when available.
- Mastodon API: support `poll` notification.
- Pinned posts federation

### Fixed

- Don't crash so hard when email settings are invalid.
- Checking activated Upload Filters for required commands.
- Remote users can no longer reappear after being deleted.
- Deactivated users may now be deleted.
- Deleting an activity with a lot of likes/boosts no longer causes a database timeout.
- Mix task `pleroma.database prune_objects`
- Fixed rendering of JSON errors on ActivityPub endpoints.
- Linkify: Parsing crash with URLs ending in unbalanced closed paren, no path separator, and no query parameters
- Try to save exported ConfigDB settings (migrate_from_db) in the system temp directory if default location is not writable.
- Uploading custom instance thumbnail via AdminAPI/AdminFE generated invalid URL to the image
- Applying ConcurrentLimiter settings via AdminAPI
- User login failures if their `notification_settings` were in a NULL state.
- Mix task `pleroma.user delete_activities` query transaction timeout is now :infinity
- MRF (`SimplePolicy`): Embedded objects are now checked. If any embedded object would be rejected, its parent is rejected. This fixes Announces leaking posts from blocked domains.
- Fixed some Markdown issues, including trailing slash in links.

### Removed

- **Breaking**: Remove deprecated `/api/qvitter/statuses/notifications/read` (replaced by `/api/v1/pleroma/notifications/read`)

## [2.3.0] - 2021-03-01

### Security

- Fixed client user agent leaking through MediaProxy

### Removed

- `:auth, :enforce_oauth_admin_scope_usage` configuration option.

### Changed

- **Breaking**: Changed `mix pleroma.user toggle_confirmed` to `mix pleroma.user confirm`
- **Breaking**: Changed `mix pleroma.user toggle_activated` to `mix pleroma.user activate/deactivate`
- **Breaking:** NSFW hashtag is no longer added on sensitive posts
- Polls now always return a `voters_count`, even if they are single-choice.
- Admin Emails: The ap id is used as the user link in emails now.
- Improved registration workflow for email confirmation and account approval modes.
- Search: When using Postgres 11+, Pleroma will use the `websearch_to_tsvector` function to parse search queries.
- Emoji: Support the full Unicode 13.1 set of Emoji for reactions, plus regional indicators.
- Deprecated `Pleroma.Uploaders.S3, :public_endpoint`. Now `Pleroma.Upload, :base_url` is the standard configuration key for all uploaders.
- Improved Apache webserver support: updated sample configuration, MediaProxy cache invalidation verified with the included sample script
- Improve OAuth 2.0 provider support. A missing `fqn` field was added to the response, but does not expose the user's email address.
- Provide redirect of external posts from `/notice/:id` to their original URL
- Admins no longer receive notifications for reports if they are the actor making the report.
- Improved Mailer configuration setting descriptions for AdminFE.
- Updated default avatar to look nicer.

<details>
  <summary>API Changes</summary>

- **Breaking:** AdminAPI changed User field `confirmation_pending` to `is_confirmed`
- **Breaking:** AdminAPI changed User field `approval_pending` to `is_approved`
- **Breaking**: AdminAPI changed User field `deactivated` to `is_active`
- **Breaking:** AdminAPI `GET /api/pleroma/admin/users/:nickname_or_id/statuses` changed response format and added the number of total users posts.
- **Breaking:** AdminAPI `GET /api/pleroma/admin/instances/:instance/statuses` changed response format and added the number of total users posts.
- Admin API: Reports now ordered by newest
- Pleroma API: `GET /api/v1/pleroma/chats` is deprecated in favor of `GET /api/v2/pleroma/chats`.
- Pleroma API: Reroute `/api/pleroma/*` to `/api/v1/pleroma/*`

</details>
- Improved hashtag timeline performance (requires a background migration).

### Added

- Reports now generate notifications for admins and mods.
- Support for local-only statuses.
- Support pagination of blocks and mutes.
- Account backup.
- Configuration: Add `:instance, autofollowing_nicknames` setting to provide a way to make accounts automatically follow new users that register on the local Pleroma instance.
- `[:activitypub, :blockers_visible]` config to control visibility of blockers.
- Ability to view remote timelines, with ex. `/api/v1/timelines/public?instance=lain.com` and streams `public:remote` and `public:remote:media`.
- The site title is now injected as a `title` tag like preloads or metadata.
- Password reset tokens now are not accepted after a certain age.
- Mix tasks to help with displaying and removing ConfigDB entries. See `mix pleroma.config`.
- OAuth form improvements: users are remembered by their cookie, the CSS is overridable by the admin, and the style has been improved.
- OAuth improvements and fixes: more secure session-based authentication (by token that could be revoked anytime), ability to revoke belonging OAuth token from any client etc.
- Ability to set ActivityPub aliases for follower migration.
- Configurable background job limits for RichMedia (link previews) and MediaProxyWarmingPolicy
- Ability to define custom HTTP headers per each frontend
- MRF (`NoEmptyPolicy`): New MRF Policy which will deny empty statuses or statuses of only mentions from being created by local users
- New users will receive a simple email confirming their registration if no other emails will be dispatched. (e.g., Welcome, Confirmation, or Approval Required)

<details>
  <summary>API Changes</summary>
- Admin API: (`GET /api/pleroma/admin/users`) filter users by `unconfirmed` status and `actor_type`.
- Admin API: OpenAPI spec for the user-related operations
- Pleroma API: `GET /api/v2/pleroma/chats` added. It is exactly like `GET /api/v1/pleroma/chats` except supports pagination.
- Pleroma API: Add `idempotency_key` to the chat message entity that can be used for optimistic message sending.
- Pleroma API: (`GET /api/v1/pleroma/federation_status`) Add a way to get a list of unreachable instances.
- Mastodon API: User and conversation mutes can now auto-expire if `expires_in` parameter was given while adding the mute.
- Admin API: An endpoint to manage frontends.
- Streaming API: Add follow relationships updates.
- WebPush: Introduce `pleroma:chat_mention` and `pleroma:emoji_reaction` notification types.
- Mastodon API: Add monthly active users to `/api/v1/instance` (`pleroma.stats.mau`).
- Mastodon API: Home, public, hashtag & list timelines accept `only_media`, `remote` & `local` parameters for filtration.
- Mastodon API: `/api/v1/accounts/:id` & `/api/v1/mutes` endpoints accept `with_relationships` parameter and return filled `pleroma.relationship` field.
- Mastodon API: Endpoint to remove a conversation (`DELETE /api/v1/conversations/:id`).
- Mastodon API: `expires_in` in the scheduled post `params` field on `/api/v1/statuses` and `/api/v1/scheduled_statuses/:id` endpoints.
</details>

### Fixed

- Users with `is_discoverable` field set to false (default value) will appear in in-service search results but be hidden from external services (search bots etc.).
- Streaming API: Posts and notifications are not dropped, when CLI task is executing.
- Creating incorrect IPv4 address-style HTTP links when encountering certain numbers.
- Reblog API Endpoint: Do not set visibility parameter to public by default and let CommonAPI to infer it from status, so a user can reblog their private status without explicitly setting reblog visibility to private.
- Tag URLs in statuses are now absolute
- Removed duplicate jobs to purge expired activities
- File extensions of some attachments were incorrectly changed. This feature has been disabled for now.
- Mix task pleroma.instance creates missing parent directories if the configuration or SQL output paths are changed.

<details>
  <summary>API Changes</summary>
  - Mastodon API: Current user is now included in conversation if it's the only participant.
  - Mastodon API: Fixed last_status.account being not filled with account data.
  - Mastodon API: Fix not being able to add or remove multiple users at once in lists.
  - Mastodon API: Fixed own_votes being not returned with poll data.
  - Mastodon API: Fixed creation of scheduled posts with polls.
  - Mastodon API: Support for expires_in/expires_at in the Filters.
</details>

## [2.2.2] - 2021-01-18

### Fixed

- StealEmojiPolicy creates dir for emojis, if it doesn't exist.
- Updated `elixir_make` to a non-retired version

### Upgrade notes

1. Restart Pleroma

## [2.2.1] - 2020-12-22

### Changed

- Updated Pleroma FE

### Fixed

- Config generation: rename `Pleroma.Upload.Filter.ExifTool` to `Pleroma.Upload.Filter.Exiftool`.
- S3 Uploads with Elixir 1.11.
- Mix task pleroma.user delete_activities for source installations.
- Search: RUM index search speed has been fixed.
- Rich Media Previews sometimes showed the wrong preview due to a bug following redirects.
- Fixes for the autolinker.
- Forwarded reports duplication from Pleroma instances.
- Emoji Reaction activity filtering from blocked and muted accounts.

- <details>
    <summary>API</summary>
  - Statuses were not displayed for Mastodon forwarded reports.
  </details>

### Upgrade notes

1. Restart Pleroma

## [2.2.0] - 2020-11-12

### Security

- Fixed the possibility of using file uploads to spoof posts.

### Changed

- **Breaking** Requires `libmagic` (or `file`) to guess file types.
- **Breaking:** App metrics endpoint (`/api/pleroma/app_metrics`) is disabled by default, check `docs/API/prometheus.md` on enabling and configuring.
- **Breaking:** Pleroma Admin API: emoji packs and files routes changed.
- **Breaking:** Sensitive/NSFW statuses no longer disable link previews.
- Search: Users are now findable by their urls.
- Renamed `:await_up_timeout` in `:connections_pool` namespace to `:connect_timeout`, old name is deprecated.
- Renamed `:timeout` in `pools` namespace to `:recv_timeout`, old name is deprecated.
- The `discoverable` field in the `User` struct will now add a NOINDEX metatag to profile pages when false.
- Users with the `is_discoverable` field set to false will not show up in searches ([bug](https://git.pleroma.social/pleroma/pleroma/-/issues/2301)).
- Minimum lifetime for ephmeral activities changed to 10 minutes and made configurable (`:min_lifetime` option).
- Introduced optional dependencies on `ffmpeg`, `ImageMagick`, `exiftool` software packages. Please refer to `docs/installation/optional/media_graphics_packages.md`.
- <details>
  <summary>API Changes</summary>
- API: Empty parameter values for integer parameters are now ignored in non-strict validaton mode.
</details>

### Removed

- **Breaking:** `Pleroma.Workers.Cron.StatsWorker` setting from Oban `:crontab` (moved to a simpler implementation).
- **Breaking:** `Pleroma.Workers.Cron.ClearOauthTokenWorker` setting from Oban `:crontab` (moved to scheduled jobs).
- **Breaking:** `Pleroma.Workers.Cron.PurgeExpiredActivitiesWorker` setting from Oban `:crontab` (moved to scheduled jobs).
- Removed `:managed_config` option. In practice, it was accidentally removed with 2.0.0 release when frontends were
  switched to a new configuration mechanism, however it was not officially removed until now.

### Added

- Media preview proxy (requires `ffmpeg` and `ImageMagick` to be installed and media proxy to be enabled; see `:media_preview_proxy` config for more details).
- Mix tasks for controlling user account confirmation status in bulk (`mix pleroma.user confirm_all` and `mix pleroma.user unconfirm_all`)
- Mix task for sending confirmation emails to all unconfirmed users (`mix pleroma.email resend_confirmation_emails`)
- Mix task option for force-unfollowing relays
- App metrics: ability to restrict access to specified IP whitelist.

<details>
  <summary>API Changes</summary>

- Admin API: Importing emoji from a zip file
- Pleroma API: Importing the mutes users from CSV files.
- Pleroma API: Pagination for remote/local packs and emoji.

</details>

### Fixed

- Add documented-but-missing chat pagination.
- Allow sending out emails again.
- Allow sending chat messages to yourself
- OStatus / static FE endpoints: fixed inaccessibility for anonymous users on non-federating instances, switched to handling per `:restrict_unauthenticated` setting.
- Fix remote users with a whitespace name.

### Upgrade notes

1. Install libmagic and development headers (`libmagic-dev` on Ubuntu/Debian, `file-dev` on Alpine Linux)
2. Run database migrations (inside Pleroma directory):

- OTP: `./bin/pleroma_ctl migrate`
- From Source: `mix ecto.migrate`

3. Restart Pleroma

## [2.1.2] - 2020-09-17

### Security

- Fix most MRF rules either crashing or not being applied to objects passed into the Common Pipeline (ChatMessage, Question, Answer, Audio, Event).

### Fixed

- Welcome Chat messages preventing user registration with MRF Simple Policy applied to the local instance.
- Mastodon API: the public timeline returning an error when the `reply_visibility` parameter is set to `self` for an unauthenticated user.
- Mastodon Streaming API: Handler crashes on authentication failures, resulting in error logs.
- Mastodon Streaming API: Error logs on client pings.
- Rich media: Log spam on failures. Now the error is only logged once per attempt.

### Changed

- Rich Media: A HEAD request is now done to the url, to ensure it has the appropriate content type and size before proceeding with a GET.

### Upgrade notes

1. Restart Pleroma

## [2.1.1] - 2020-09-08

### Security

- Fix possible DoS in Mastodon API user search due to an error in match clauses, leading to an infinite recursion and subsequent OOM with certain inputs.
- Fix metadata leak for accounts and statuses on private instances.
- Fix possible DoS in Admin API search using an atom leak vulnerability. Authentication with admin rights was required to exploit.

### Changed

- **Breaking:** The metadata providers RelMe and Feed are no longer configurable. RelMe should always be activated and Feed only provides a <link> header tag for the actual RSS/Atom feed when the instance is public.
- Improved error message when cmake is not available at build stage.

### Added

- Rich media failure tracking (along with `:failure_backoff` option).

<details>
  <summary>Admin API Changes</summary>

- Add `PATCH /api/pleroma/admin/instance_document/:document_name` to modify the Terms of Service and Instance Panel HTML pages via Admin API
</details>

### Fixed

- Default HTTP adapter not respecting pool setting, leading to possible OOM.
- Fixed uploading webp images when the Exiftool Upload Filter is enabled by skipping them
- Mastodon API: Search parameter `following` now correctly returns the followings rather than the followers
- Mastodon API: Timelines hanging for (`number of posts with links * rich media timeout`) in the worst case.
  Reduced to just rich media timeout.
- Mastodon API: Cards being wrong for preview statuses due to cache key collision.
- Password resets no longer processed for deactivated accounts.
- Favicon scraper raising exceptions on URLs longer than 255 characters.

## [2.1.0] - 2020-08-28

### Changed

- **Breaking:** The default descriptions on uploads are now empty. The old behavior (filename as default) can be configured, see the cheat sheet.
- **Breaking:** Added the ObjectAgePolicy to the default set of MRFs. This will delist and strip the follower collection of any message received that is older than 7 days. This will stop users from seeing very old messages in the timelines. The messages can still be viewed on the user's page and in conversations. They also still trigger notifications.
- **Breaking:** Elixir >=1.9 is now required (was >= 1.8)
- **Breaking:** Configuration: `:auto_linker, :opts` moved to `:pleroma, Pleroma.Formatter`. Old config namespace is deprecated.
- **Breaking:** Configuration: `:instance, welcome_user_nickname` moved to `:welcome, :direct_message, :sender_nickname`, `:instance, :welcome_message` moved to `:welcome, :direct_message, :message`. Old config namespace is deprecated.
- **Breaking:** LDAP: Fallback to local database authentication has been removed for security reasons and lack of a mechanism to ensure the passwords are synchronized when LDAP passwords are updated.
- **Breaking** Changed defaults for `:restrict_unauthenticated` so that when `:instance, :public` is set to `false` then all `:restrict_unauthenticated` items be effectively set to `true`. If you'd like to allow unauthenticated access to specific API endpoints on a private instance, please explicitly set `:restrict_unauthenticated` to non-default value in `config/prod.secret.exs`.
- In Conversations, return only direct messages as `last_status`
- Using the `only_media` filter on timelines will now exclude reblog media
- MFR policy to set global expiration for all local Create activities
- OGP rich media parser merged with TwitterCard
- Configuration: `:instance, rewrite_policy` moved to `:mrf, policies`, `:instance, :mrf_transparency` moved to `:mrf, :transparency`, `:instance, :mrf_transparency_exclusions` moved to `:mrf, :transparency_exclusions`. Old config namespace is deprecated.
- Configuration: `:media_proxy, whitelist` format changed to host with scheme (e.g. `http://example.com` instead of `example.com`). Domain format is deprecated.

<details>
  <summary>API Changes</summary>

- **Breaking:** Pleroma API: The routes to update avatar, banner and background have been removed.
- **Breaking:** Image description length is limited now.
- **Breaking:** Emoji API: changed methods and renamed routes.
- **Breaking:** Notification Settings API for suppressing notifications has been simplified down to `block_from_strangers`.
- **Breaking:** Notification Settings API option for hiding push notification contents has been renamed to `hide_notification_contents`.
- MastodonAPI: Allow removal of avatar, banner and background.
- Streaming: Repeats of a user's posts will no longer be pushed to the user's stream.
- Mastodon API: Added `pleroma.metadata.fields_limits` to /api/v1/instance
- Mastodon API: On deletion, returns the original post text.
- Mastodon API: Add `pleroma.unread_count` to the Marker entity.
- Mastodon API: Added `pleroma.metadata.post_formats` to /api/v1/instance
- Mastodon API (legacy): Allow query parameters for `/api/v1/domain_blocks`, e.g. `/api/v1/domain_blocks?domain=badposters.zone`
- Mastodon API: Make notifications about statuses from muted users and threads read automatically
- Pleroma API: `/api/pleroma/captcha` responses now include `seconds_valid` with an integer value.

</details>

<details>
  <summary>Admin API Changes</summary>

- **Breaking** Changed relay `/api/pleroma/admin/relay` endpoints response format.
- Status visibility stats: now can return stats per instance.
- Mix task to refresh counter cache (`mix pleroma.refresh_counter_cache`)

</details>

### Removed

- **Breaking:** removed `with_move` parameter from notifications timeline.

### Added

- Frontends: Add mix task to install frontends.
- Frontends: Add configurable frontends for primary and admin fe.
- Configuration: Added a blacklist for email servers.
- Chats: Added `accepts_chat_messages` field to user, exposed in APIs and federation.
- Chats: Added support for federated chats. For details, see the docs.
- ActivityPub: Added support for existing AP ids for instances migrated from Mastodon.
- Instance: Add `background_image` to configuration and `/api/v1/instance`
- Instance: Extend `/api/v1/instance` with Pleroma-specific information.
- NodeInfo: `pleroma:api/v1/notifications:include_types_filter` to the `features` list.
- NodeInfo: `pleroma_emoji_reactions` to the `features` list.
- Configuration: `:restrict_unauthenticated` setting, restrict access for unauthenticated users to timelines (public and federate), user profiles and statuses.
- Configuration: Add `:database_config_whitelist` setting to whitelist settings which can be configured from AdminFE.
- Configuration: `filename_display_max_length` option to set filename truncate limit, if filename display enabled (0 = no limit).
- New HTTP adapter [gun](https://github.com/ninenines/gun). Gun adapter requires minimum OTP version of 22.2 otherwise Pleroma won’t start. For hackney OTP update is not required.
- Mix task to create trusted OAuth App.
- Mix task to reset MFA for user accounts
- Notifications: Added `follow_request` notification type.
- Added `:reject_deletes` group to SimplePolicy
- MRF (`EmojiStealPolicy`): New MRF Policy which allows to automatically download emojis from remote instances
- Support pagination in emoji packs API (for packs and for files in pack)
- Support for viewing instances favicons next to posts and accounts
- Added Pleroma.Upload.Filter.Exiftool as an alternate EXIF stripping mechanism targeting GPS/location metadata.
- "By approval" registrations mode.
- Configuration: Added `:welcome` settings for the welcome message to newly registered users. You can send a welcome message as a direct message, chat or email.
- Ability to hide favourites and emoji reactions in the API with `[:instance, :show_reactions]` config.

<details>
  <summary>API Changes</summary>

- Mastodon API: Add pleroma.parent_visible field to statuses.
- Mastodon API: Extended `/api/v1/instance`.
- Mastodon API: Support for `include_types` in `/api/v1/notifications`.
- Mastodon API: Added `/api/v1/notifications/:id/dismiss` endpoint.
- Mastodon API: Add support for filtering replies in public and home timelines.
- Mastodon API: Support for `bot` field in `/api/v1/accounts/update_credentials`.
- Mastodon API: Support irreversible property for filters.
- Mastodon API: Add pleroma.favicon field to accounts.
- Admin API: endpoints for create/update/delete OAuth Apps.
- Admin API: endpoint for status view.
- OTP: Add command to reload emoji packs
</details>

### Fixed

- Fix list pagination and other list issues.
- Support pagination in conversations API
- **Breaking**: SimplePolicy `:reject` and `:accept` allow deletions again
- Fix follower/blocks import when nicknames starts with @
- Filtering of push notifications on activities from blocked domains
- Resolving Peertube accounts with Webfinger
- `blob:` urls not being allowed by connect-src CSP
- Mastodon API: fix `GET /api/v1/notifications` not returning the full result set
- Rich Media Previews for Twitter links
- Admin API: fix `GET /api/pleroma/admin/users/:nickname/credentials` returning 404 when getting the credentials of a remote user while `:instance, :limit_to_local_content` is set to `:unauthenticated`
- Fix CSP policy generation to include remote Captcha services
- Fix edge case where MediaProxy truncates media, usually caused when Caddy is serving content for the other Federated instance.
- Emoji Packs could not be listed when instance was set to `public: false`
- Fix whole_word always returning false on filter get requests
- Migrations not working on OTP releases if the database was connected over ssl
- Fix relay following

## [2.0.7] - 2020-06-13

### Security

- Fix potential DoSes exploiting atom leaks in rich media parser and the `UserAllowListPolicy` MRF policy

### Fixed

- CSP: not allowing images/media from every host when mediaproxy is disabled
- CSP: not adding mediaproxy base url to image/media hosts
- StaticFE missing the CSS file

### Upgrade notes

1. Restart Pleroma

## [2.0.6] - 2020-06-09

### Security

- CSP: harden `image-src` and `media-src` when MediaProxy is used

### Fixed

- AP C2S: Fix pagination in inbox/outbox
- Various compilation errors on OTP 23
- Mastodon API streaming: Repeats from muted threads not being filtered

### Changed

- Various database performance improvements

### Upgrade notes

1. Run database migrations (inside Pleroma directory):

- OTP: `./bin/pleroma_ctl migrate`
- From Source: `mix ecto.migrate`

2. Restart Pleroma

## [2.0.5] - 2020-05-13

### Security

- Fix possible private status leaks in Mastodon Streaming API

### Fixed

- Crashes when trying to block a user if block federation is disabled
- Not being able to start the instance without `erlang-eldap` installed
- Users with bios over the limit getting rejected
- Follower counters not being updated on incoming follow accepts

### Upgrade notes

1. Restart Pleroma

## [2.0.4] - 2020-05-10

### Security

- AP C2S: Fix a potential DoS by creating nonsensical objects that break timelines

### Fixed

- Peertube user lookups not working
- `InsertSkeletonsForDeletedUsers` migration failing on some instances
- Healthcheck reporting the number of memory currently used, rather than allocated in total
- LDAP not being usable in OTP releases
- Default apache configuration having tls chain issues

### Upgrade notes

#### Apache only

1. Remove the following line from your config:

```
    SSLCertificateFile      /etc/letsencrypt/live/${servername}/cert.pem
```

#### Everyone

1. Restart Pleroma

## [2.0.3] - 2020-05-02

### Security

- Disallow re-registration of previously deleted users, which allowed viewing direct messages addressed to them
- Mastodon API: Fix `POST /api/v1/follow_requests/:id/authorize` allowing to force a follow from a local user even if they didn't request to follow
- CSP: Sandbox uploads

### Fixed

- Notifications from blocked domains
- Potential federation issues with Mastodon versions before 3.0.0
- HTTP Basic Authentication permissions issue
- Follow/Block imports not being able to find the user if the nickname started with an `@`
- Instance stats counting internal users
- Inability to run a From Source release without git
- ObjectAgePolicy didn't filter out old messages
- `blob:` urls not being allowed by CSP

### Added

- NodeInfo: ObjectAgePolicy settings to the `federation` list.
- Follow request notifications
<details>
  <summary>API Changes</summary>
- Admin API: `GET /api/pleroma/admin/need_reboot`.
</details>

### Upgrade notes

1. Restart Pleroma
2. Run database migrations (inside Pleroma directory):

- OTP: `./bin/pleroma_ctl migrate`
- From Source: `mix ecto.migrate`

3. Reset status visibility counters (inside Pleroma directory):

- OTP: `./bin/pleroma_ctl refresh_counter_cache`
- From Source: `mix pleroma.refresh_counter_cache`

## [2.0.2] - 2020-04-08

### Added

- Support for Funkwhale's `Audio` activity
- Admin API: `PATCH /api/pleroma/admin/users/:nickname/update_credentials`

### Fixed

- Blocked/muted users still generating push notifications
- Input textbox for bio ignoring newlines
- OTP: Inability to use PostgreSQL databases with SSL
- `user delete_activities` breaking when trying to delete already deleted posts
- Incorrect URL for Funkwhale channels

### Upgrade notes

1. Restart Pleroma

## [2.0.1] - 2020-03-15

### Security

- Static-FE: Fix remote posts not being sanitized

### Fixed

- Rate limiter crashes when there is no explicitly specified ip in the config
- 500 errors when no `Accept` header is present if Static-FE is enabled
- Instance panel not being updated immediately due to wrong `Cache-Control` headers
- Statuses posted with BBCode/Markdown having unnecessary newlines in Pleroma-FE
- OTP: Fix some settings not being migrated to in-database config properly
- No `Cache-Control` headers on attachment/media proxy requests
- Character limit enforcement being off by 1
- Mastodon Streaming API: hashtag timelines not working

### Changed

- BBCode and Markdown formatters will no longer return any `\n` and only use `<br/>` for newlines
- Mastodon API: Allow registration without email if email verification is not enabled

### Upgrade notes

#### Nginx only

1. Remove `proxy_ignore_headers Cache-Control;` and `proxy_hide_header  Cache-Control;` from your config.

#### Everyone

1. Run database migrations (inside Pleroma directory):

- OTP: `./bin/pleroma_ctl migrate`
- From Source: `mix ecto.migrate`

2. Restart Pleroma

## [2.0.0] - 2019-03-08

### Security

- Mastodon API: Fix being able to request enormous amount of statuses in timelines leading to DoS. Now limited to 40 per request.

### Removed

- **Breaking**: Removed 1.0+ deprecated configurations `Pleroma.Upload, :strip_exif` and `:instance, :dedupe_media`
- **Breaking**: OStatus protocol support
- **Breaking**: MDII uploader
- **Breaking**: Using third party engines for user recommendation
<details>
  <summary>API Changes</summary>

- **Breaking**: AdminAPI: migrate_from_db endpoint
</details>

### Changed

- **Breaking:** Pleroma won't start if it detects unapplied migrations
- **Breaking:** Elixir >=1.8 is now required (was >= 1.7)
- **Breaking:** `Pleroma.Plugs.RemoteIp` and `:rate_limiter` enabled by default. Please ensure your reverse proxy forwards the real IP!
- **Breaking:** attachment links (`config :pleroma, :instance, no_attachment_links` and `config :pleroma, Pleroma.Upload, link_name`) disabled by default
- **Breaking:** OAuth: defaulted `[:auth, :enforce_oauth_admin_scope_usage]` setting to `true` which demands `admin` OAuth scope to perform admin actions (in addition to `is_admin` flag on User); make sure to use bundled or newer versions of AdminFE & PleromaFE to access admin / moderator features.
- **Breaking:** Dynamic configuration has been rearchitected. The `:pleroma, :instance, dynamic_configuration` setting has been replaced with `config :pleroma, configurable_from_database`. Please backup your configuration to a file and run the migration task to ensure consistency with the new schema.
- **Breaking:** `:instance, no_attachment_links` has been replaced with `:instance, attachment_links` which still takes a boolean value but doesn't use double negative language.
- Replaced [pleroma_job_queue](https://git.pleroma.social/pleroma/pleroma_job_queue) and `Pleroma.Web.Federator.RetryQueue` with [Oban](https://github.com/sorentwo/oban) (see [`docs/config.md`](docs/config.md) on migrating customized worker / retry settings)
- Introduced [quantum](https://github.com/quantum-elixir/quantum-core) job scheduler
- Enabled `:instance, extended_nickname_format` in the default config
- Add `rel="ugc"` to all links in statuses, to prevent SEO spam
- Extract RSS functionality from OStatus
- MRF (Simple Policy): Also use `:accept`/`:reject` on the actors rather than only their activities
- OStatus: Extract RSS functionality
- Deprecated `User.Info` embedded schema (fields moved to `User`)
- Store status data inside Flag activity
- Deprecated (reorganized as `UserRelationship` entity) User fields with user AP IDs (`blocks`, `mutes`, `muted_reblogs`, `muted_notifications`, `subscribers`).
- Rate limiter is now disabled for localhost/socket (unless remoteip plug is enabled)
- Logger: default log level changed from `warn` to `info`.
- Config mix task `migrate_to_db` truncates `config` table before migrating the config file.
- Allow account registration without an email
- Default to `prepare: :unnamed` in the database configuration.
- Instance stats are now loaded on startup instead of being empty until next hourly job.
<details>
  <summary>API Changes</summary>

- **Breaking** EmojiReactions: Change endpoints and responses to align with Mastodon
- **Breaking** Admin API: `PATCH /api/pleroma/admin/users/:nickname/force_password_reset` is now `PATCH /api/pleroma/admin/users/force_password_reset` (accepts `nicknames` array in the request body)
- **Breaking:** Admin API: Return link alongside with token on password reset
- **Breaking:** Admin API: `PUT /api/pleroma/admin/reports/:id` is now `PATCH /api/pleroma/admin/reports`, see admin_api.md for details
- **Breaking:** `/api/pleroma/admin/users/invite_token` now uses `POST`, changed accepted params and returns full invite in json instead of only token string.
- **Breaking** replying to reports is now "report notes", endpoint changed from `POST /api/pleroma/admin/reports/:id/respond` to `POST /api/pleroma/admin/reports/:id/notes`
- Mastodon API: stopped sanitizing display names, field names and subject fields since they are supposed to be treated as plaintext
- Admin API: Return `total` when querying for reports
- Mastodon API: Return `pleroma.direct_conversation_id` when creating a direct message (`POST /api/v1/statuses`)
- Admin API: Return link alongside with token on password reset
- Admin API: Support authentication via `x-admin-token` HTTP header
- Mastodon API: Add `pleroma.direct_conversation_id` to the status endpoint (`GET /api/v1/statuses/:id`)
- Mastodon API: `pleroma.thread_muted` to the Status entity
- Mastodon API: Mark the direct conversation as read for the author when they send a new direct message
- Mastodon API, streaming: Add `pleroma.direct_conversation_id` to the `conversation` stream event payload.
- Admin API: Render whole status in grouped reports
- Mastodon API: User timelines will now respect blocks, unless you are getting the user timeline of somebody you blocked (which would be empty otherwise).
- Mastodon API: Favoriting / Repeating a post multiple times will now return the identical response every time. Before, executing that action twice would return an error ("already favorited") on the second try.
- Mastodon API: Limit timeline requests to 3 per timeline per 500ms per user/ip by default.
- Admin API: `PATCH /api/pleroma/admin/users/:nickname/credentials` and `GET /api/pleroma/admin/users/:nickname/credentials`
</details>

### Added

- `:chat_limit` option to limit chat characters.
- `cleanup_attachments` option to remove attachments along with statuses. Does not affect duplicate files and attachments without status. Enabling this will increase load to database when deleting statuses on larger instances.
- Refreshing poll results for remote polls
- Authentication: Added rate limit for password-authorized actions / login existence checks
- Static Frontend: Add the ability to render user profiles and notices server-side without requiring JS app.
- Mix task to re-count statuses for all users (`mix pleroma.count_statuses`)
- Mix task to list all users (`mix pleroma.user list`)
- Mix task to send a test email (`mix pleroma.email test`)
- Support for `X-Forwarded-For` and similar HTTP headers which used by reverse proxies to pass a real user IP address to the backend. Must not be enabled unless your instance is behind at least one reverse proxy (such as Nginx, Apache HTTPD or Varnish Cache).
- MRF: New module which handles incoming posts based on their age. By default, all incoming posts that are older than 2 days will be unlisted and not shown to their followers.
- User notification settings: Add `privacy_option` option.
- Support for custom Elixir modules (such as MRF policies)
- User settings: Add _This account is a_ option.
- A new users admin digest email
- OAuth: admin scopes support (relevant setting: `[:auth, :enforce_oauth_admin_scope_usage]`).
- Add an option `authorized_fetch_mode` to require HTTP signatures for AP fetches.
- ActivityPub: support for `replies` collection (output for outgoing federation & fetching on incoming federation).
- Mix task to refresh counter cache (`mix pleroma.refresh_counter_cache`)
<details>
  <summary>API Changes</summary>

- Job queue stats to the healthcheck page
- Admin API: Add ability to fetch reports, grouped by status `GET /api/pleroma/admin/grouped_reports`
- Admin API: Add ability to require password reset
- Mastodon API: Account entities now include `follow_requests_count` (planned Mastodon 3.x addition)
- Pleroma API: `GET /api/v1/pleroma/accounts/:id/scrobbles` to get a list of recently scrobbled items
- Pleroma API: `POST /api/v1/pleroma/scrobble` to scrobble a media item
- Mastodon API: Add `upload_limit`, `avatar_upload_limit`, `background_upload_limit`, and `banner_upload_limit` to `/api/v1/instance`
- Mastodon API: Add `pleroma.unread_conversation_count` to the Account entity
- OAuth: support for hierarchical permissions / [Mastodon 2.4.3 OAuth permissions](https://docs.joinmastodon.org/api/permissions/)
- Metadata Link: Atom syndication Feed
- Mix task to re-count statuses for all users (`mix pleroma.count_statuses`)
- Mastodon API: Add `exclude_visibilities` parameter to the timeline and notification endpoints
- Admin API: `/users/:nickname/toggle_activation` endpoint is now deprecated in favor of: `/users/activate`, `/users/deactivate`, both accept `nicknames` array
- Admin API: Multiple endpoints now require `nicknames` array, instead of singe `nickname`:
  - `POST/DELETE /api/pleroma/admin/users/:nickname/permission_group/:permission_group` are deprecated in favor of: `POST/DELETE /api/pleroma/admin/users/permission_group/:permission_group`
  - `DELETE /api/pleroma/admin/users` (`nickname` query param or `nickname` sent in JSON body) is deprecated in favor of: `DELETE /api/pleroma/admin/users` (`nicknames` query array param or `nicknames` sent in JSON body)
- Admin API: Add `GET /api/pleroma/admin/relay` endpoint - lists all followed relays
- Pleroma API: `POST /api/v1/pleroma/conversations/read` to mark all conversations as read
- ActivityPub: Support `Move` activities
- Mastodon API: Add `/api/v1/markers` for managing timeline read markers
- Mastodon API: Add the `recipients` parameter to `GET /api/v1/conversations`
- Configuration: `feed` option for user atom feed.
- Pleroma API: Add Emoji reactions
- Admin API: Add `/api/pleroma/admin/instances/:instance/statuses` - lists all statuses from a given instance
- Admin API: Add `/api/pleroma/admin/users/:nickname/statuses` - lists all statuses from a given user
- Admin API: `PATCH /api/pleroma/users/confirm_email` to confirm email for multiple users, `PATCH /api/pleroma/users/resend_confirmation_email` to resend confirmation email for multiple users
- ActivityPub: Configurable `type` field of the actors.
- Mastodon API: `/api/v1/accounts/:id` has `source/pleroma/actor_type` field.
- Mastodon API: `/api/v1/update_credentials` accepts `actor_type` field.
- Captcha: Support native provider
- Captcha: Enable by default
- Mastodon API: Add support for `account_id` param to filter notifications by the account
- Mastodon API: Add `emoji_reactions` property to Statuses
- Mastodon API: Change emoji reaction reply format
- Notifications: Added `pleroma:emoji_reaction` notification type
- Mastodon API: Change emoji reaction reply format once more
- Configuration: `feed.logo` option for tag feed.
- Tag feed: `/tags/:tag.rss` - list public statuses by hashtag.
- Mastodon API: Add `reacted` property to `emoji_reactions`
- Pleroma API: Add reactions for a single emoji.
- ActivityPub: `[:activitypub, :note_replies_output_limit]` setting sets the number of note self-replies to output on outgoing federation.
- Admin API: `GET /api/pleroma/admin/stats` to get status count by visibility scope
- Admin API: `GET /api/pleroma/admin/statuses` - list all statuses (accepts `godmode` and `local_only`)
</details>

### Fixed

- Report emails now include functional links to profiles of remote user accounts
- Not being able to log in to some third-party apps when logged in to MastoFE
- MRF: `Delete` activities being exempt from MRF policies
- OTP releases: Not being able to configure OAuth expired token cleanup interval
- OTP releases: Not being able to configure HTML sanitization policy
- OTP releases: Not being able to change upload limit (again)
- Favorites timeline now ordered by favorite date instead of post date
- Support for cancellation of a follow request
<details>
  <summary>API Changes</summary>

- Mastodon API: Fix private and direct statuses not being filtered out from the public timeline for an authenticated user (`GET /api/v1/timelines/public`)
- Mastodon API: Inability to get some local users by nickname in `/api/v1/accounts/:id_or_nickname`
- AdminAPI: If some status received reports both in the "new" format and "old" format it was considered reports on two different statuses (in the context of grouped reports)
- Admin API: Error when trying to update reports in the "old" format
- Mastodon API: Marking a conversation as read (`POST /api/v1/conversations/:id/read`) now no longer brings it to the top in the user's direct conversation list
</details>

## [1.1.9] - 2020-02-10

### Fixed

- OTP: Inability to set the upload limit (again)
- Not being able to pin polls
- Streaming API: incorrect handling of reblog mutes
- Rejecting the user when field length limit is exceeded
- OpenGraph provider: html entities in descriptions

## [1.1.8] - 2020-01-10

### Fixed

- Captcha generation issues
- Returned Kocaptcha endpoint to configuration
- Captcha validity is now 5 minutes

## [1.1.7] - 2019-12-13

### Fixed

- OTP: Inability to set the upload limit
- OTP: Inability to override node name/distribution type to run 2 Pleroma instances on the same machine

### Added

- Integrated captcha provider

### Changed

- Captcha enabled by default
- Default Captcha provider changed from `Pleroma.Captcha.Kocaptcha` to `Pleroma.Captcha.Native`
- Better `Cache-Control` header for static content

### Bundled Pleroma-FE Changes

#### Added

- Icons in the navigation panel

#### Fixed

- Improved support unauthenticated view of private instances

#### Removed

- Whitespace hack on empty post content

## [1.1.6] - 2019-11-19

### Fixed

- Not being able to log into to third party apps when the browser is logged into mastofe
- Email confirmation not being required even when enabled
- Mastodon API: conversations API crashing when one status is malformed

### Bundled Pleroma-FE Changes

#### Added

- About page
- Meme arrows

#### Fixed

- Image modal not closing unless clicked outside of image
- Attachment upload spinner not being centered
- Showing follow counters being 0 when they are actually hidden

## [1.1.5] - 2019-11-09

### Fixed

- Polls having different numbers in timelines/notifications/poll api endpoints due to cache desyncronization
- Pleroma API: OAuth token endpoint not being found when ".json" suffix is appended

### Changed

- Frontend bundle updated to [044c9ad0](https://git.pleroma.social/pleroma/pleroma-fe/commit/044c9ad0562af059dd961d50961a3880fca9c642)

## [1.1.4] - 2019-11-01

### Fixed

- Added a migration that fills up empty user.info fields to prevent breakage after previous unsafe migrations.
- Failure to migrate from pre-1.0.0 versions
- Mastodon API: Notification stream not including follow notifications

## [1.1.3] - 2019-10-25

### Fixed

- Blocked users showing up in notifications collapsed as if they were muted
- `pleroma_ctl` not working on Debian's default shell

## [1.1.2] - 2019-10-18

### Fixed

- `pleroma_ctl` trying to connect to a running instance when generating the config, which of course doesn't exist.

## [1.1.1] - 2019-10-18

### Fixed

- One of the migrations between 1.0.0 and 1.1.0 wiping user info of the relay user because of unexpected behavior of postgresql's `jsonb_set`, resulting in inability to post in the default configuration. If you were affected, please run the following query in postgres console, the relay user will be recreated automatically:

```
delete from users where ap_id = 'https://your.instance.hostname/relay';
```

- Bad user search matches

## [1.1.0] - 2019-10-14

**Breaking:** The stable branch has been changed from `master` to `stable`. If you want to keep using 1.0, the `release/1.0` branch will receive security updates for 6 months after 1.1 release.

**OTP Note:** `pleroma_ctl` in 1.0 defaults to `master` and doesn't support specifying arbitrary branches, making `./pleroma_ctl update` fail. To fix this, fetch a version of `pleroma_ctl` from 1.1 using the command below and proceed with the update normally:

```
curl -Lo ./bin/pleroma_ctl 'https://git.pleroma.social/pleroma/pleroma/raw/develop/rel/files/bin/pleroma_ctl'
```

### Security

- Mastodon API: respect post privacy in `/api/v1/statuses/:id/{favourited,reblogged}_by`

### Removed

- **Breaking:** GNU Social API with Qvitter extensions support
- Emoji: Remove longfox emojis.
- Remove `Reply-To` header from report emails for admins.
- ActivityPub: The `/objects/:uuid/likes` endpoint.

### Changed

- **Breaking:** Configuration: A setting to explicitly disable the mailer was added, defaulting to true, if you are using a mailer add `config :pleroma, Pleroma.Emails.Mailer, enabled: true` to your config
- **Breaking:** Configuration: `/media/` is now removed when `base_url` is configured, append `/media/` to your `base_url` config to keep the old behaviour if desired
- **Breaking:** `/api/pleroma/notifications/read` is moved to `/api/v1/pleroma/notifications/read` and now supports `max_id` and responds with Mastodon API entities.
- Configuration: added `config/description.exs`, from which `docs/config.md` is generated
- Configuration: OpenGraph and TwitterCard providers enabled by default
- Configuration: Filter.AnonymizeFilename added ability to retain file extension with custom text
- Federation: Return 403 errors when trying to request pages from a user's follower/following collections if they have `hide_followers`/`hide_follows` set
- NodeInfo: Return `skipThreadContainment` in `metadata` for the `skip_thread_containment` option
- NodeInfo: Return `mailerEnabled` in `metadata`
- Mastodon API: Unsubscribe followers when they unfollow a user
- Mastodon API: `pleroma.thread_muted` key in the Status entity
- AdminAPI: Add "godmode" while fetching user statuses (i.e. admin can see private statuses)
- Improve digest email template
  – Pagination: (optional) return `total` alongside with `items` when paginating
- The `Pleroma.FlakeId` module has been replaced with the `flake_id` library.

### Fixed

- Following from Osada
- Favorites timeline doing database-intensive queries
- Metadata rendering errors resulting in the entire page being inaccessible
- `federation_incoming_replies_max_depth` option being ignored in certain cases
- Mastodon API: Handling of search timeouts (`/api/v1/search` and `/api/v2/search`)
- Mastodon API: Misskey's endless polls being unable to render
- Mastodon API: Embedded relationships not being properly rendered in the Account entity of Status entity
- Mastodon API: Notifications endpoint crashing if one notification failed to render
- Mastodon API: `exclude_replies` is correctly handled again.
- Mastodon API: Add `account_id`, `type`, `offset`, and `limit` to search API (`/api/v1/search` and `/api/v2/search`)
- Mastodon API, streaming: Fix filtering of notifications based on blocks/mutes/thread mutes
- Mastodon API: Fix private and direct statuses not being filtered out from the public timeline for an authenticated user (`GET /api/v1/timelines/public`)
- Mastodon API: Ensure the `account` field is not empty when rendering Notification entities.
- Mastodon API: Inability to get some local users by nickname in `/api/v1/accounts/:id_or_nickname`
- Mastodon API: Blocks are now treated consistently between the Streaming API and the Timeline APIs
- Rich Media: Parser failing when no TTL can be found by image TTL setters
- Rich Media: The crawled URL is now spliced into the rich media data.
- ActivityPub S2S: sharedInbox usage has been mostly aligned with the rules in the AP specification.
- ActivityPub C2S: follower/following collection pages being inaccessible even when authentifucated if `hide_followers`/ `hide_follows` was set
- ActivityPub: Deactivated user deletion
- ActivityPub: Fix `/users/:nickname/inbox` crashing without an authenticated user
- MRF: fix ability to follow a relay when AntiFollowbotPolicy was enabled
- ActivityPub: Correct addressing of Undo.
- ActivityPub: Correct addressing of profile update activities.
- ActivityPub: Polls are now refreshed when necessary.
- Report emails now include functional links to profiles of remote user accounts
- Existing user id not being preserved on insert conflict
- Pleroma.Upload base_url was not automatically whitelisted by MediaProxy. Now your custom CDN or file hosting will be accessed directly as expected.
- Report email not being sent to admins when the reporter is a remote user
- Reverse Proxy limiting `max_body_length` was incorrectly defined and only checked `Content-Length` headers which may not be sufficient in some circumstances

### Added

- Expiring/ephemeral activities. All activities can have expires_at value set, which controls when they should be deleted automatically.
- Mastodon API: in post_status, the expires_in parameter lets you set the number of seconds until an activity expires. It must be at least one hour.
- Mastodon API: all status JSON responses contain a `pleroma.expires_at` item which states when an activity will expire. The value is only shown to the user who created the activity. To everyone else it's empty.
- Configuration: `ActivityExpiration.enabled` controls whether expired activities will get deleted at the appropriate time. Enabled by default.
- Conversations: Add Pleroma-specific conversation endpoints and status posting extensions. Run the `bump_all_conversations` task again to create the necessary data.
- MRF: Support for priming the mediaproxy cache (`Pleroma.Web.ActivityPub.MRF.MediaProxyWarmingPolicy`)
- MRF: Support for excluding specific domains from Transparency.
- MRF: Support for filtering posts based on who they mention (`Pleroma.Web.ActivityPub.MRF.MentionPolicy`)
- Mastodon API: Support for the [`tagged` filter](https://github.com/tootsuite/mastodon/pull/9755) in [`GET /api/v1/accounts/:id/statuses`](https://docs.joinmastodon.org/api/rest/accounts/#get-api-v1-accounts-id-statuses)
- Mastodon API, streaming: Add support for passing the token in the `Sec-WebSocket-Protocol` header
- Mastodon API, extension: Ability to reset avatar, profile banner, and background
- Mastodon API: Add support for `fields_attributes` API parameter (setting custom fields)
- Mastodon API: Add support for categories for custom emojis by reusing the group feature. <https://github.com/tootsuite/mastodon/pull/11196>
- Mastodon API: Add support for muting/unmuting notifications
- Mastodon API: Add support for the `blocked_by` attribute in the relationship API (`GET /api/v1/accounts/relationships`). <https://github.com/tootsuite/mastodon/pull/10373>
- Mastodon API: Add support for the `domain_blocking` attribute in the relationship API (`GET /api/v1/accounts/relationships`).
- Mastodon API: Add `pleroma.deactivated` to the Account entity
- Mastodon API: added `/auth/password` endpoint for password reset with rate limit.
- Mastodon API: /api/v1/accounts/:id/statuses now supports nicknames or user id
- Mastodon API: Improve support for the user profile custom fields
- Mastodon API: Add support for `fields_attributes` API parameter (setting custom fields)
- Mastodon API: Added an endpoint to get multiple statuses by IDs (`GET /api/v1/statuses/?ids[]=1&ids[]=2`)
- Admin API: Return users' tags when querying reports
- Admin API: Return avatar and display name when querying users
- Admin API: Allow querying user by ID
- Admin API: Added support for `tuples`.
- Admin API: Added endpoints to run mix tasks pleroma.config migrate_to_db & pleroma.config migrate_from_db
- Added synchronization of following/followers counters for external users
- Configuration: `enabled` option for `Pleroma.Emails.Mailer`, defaulting to `false`.
- Configuration: Pleroma.Plugs.RateLimiter `bucket_name`, `params` options.
- Configuration: `user_bio_length` and `user_name_length` options.
- Addressable lists
- Twitter API: added rate limit for `/api/account/password_reset` endpoint.
- ActivityPub: Add an internal service actor for fetching ActivityPub objects.
- ActivityPub: Optional signing of ActivityPub object fetches.
- Admin API: Endpoint for fetching latest user's statuses
- Pleroma API: Add `/api/v1/pleroma/accounts/confirmation_resend?email=<email>` for resending account confirmation.
- Pleroma API: Email change endpoint.
- Admin API: Added moderation log
- Web response cache (currently, enabled for ActivityPub)
- Reverse Proxy: Do not retry failed requests to limit pressure on the peer

### Changed

- Configuration: Filter.AnonymizeFilename added ability to retain file extension with custom text
- Admin API: changed json structure for saving config settings.
- RichMedia: parsers and their order are configured in `rich_media` config.
- RichMedia: add the rich media ttl based on image expiration time.

## [1.0.7] - 2019-09-26

### Fixed

- Broken federation on Erlang 22 (previous versions of hackney http client were using an option that got deprecated)

### Changed

- ActivityPub: The first page in inboxes/outboxes is no longer embedded.

## [1.0.6] - 2019-08-14

### Fixed

- MRF: fix use of unserializable keyword lists in describe() implementations
- ActivityPub S2S: POST requests are now signed with `(request-target)` pseudo-header.

## [1.0.5] - 2019-08-13

### Fixed

- Mastodon API: follower/following counters not being nullified, when `hide_follows`/`hide_followers` is set
- Mastodon API: `muted` in the Status entity, using author's account to determine if the thread was muted
- Mastodon API: return the actual profile URL in the Account entity's `url` property when appropriate
- Templates: properly style anchor tags
- Objects being re-embedded to activities after being updated (e.g faved/reposted). Running 'mix pleroma.database prune_objects' again is advised.
- Not being able to access the Mastodon FE login page on private instances
- MRF: ensure that subdomain_match calls are case-insensitive
- Fix internal server error when using the healthcheck API.

### Added

- **Breaking:** MRF describe API, which adds support for exposing configuration information about MRF policies to NodeInfo.
  Custom modules will need to be updated by adding, at the very least, `def describe, do: {:ok, %{}}` to the MRF policy modules.
- Relays: Added a task to list relay subscriptions.
- MRF: Support for filtering posts based on ActivityStreams vocabulary (`Pleroma.Web.ActivityPub.MRF.VocabularyPolicy`)
- MRF (Simple Policy): Support for wildcard domains.
- Support for wildcard domains in user domain blocks setting.
- Configuration: `quarantined_instances` support wildcard domains.
- Mix Tasks: `mix pleroma.database fix_likes_collections`
- Configuration: `federation_incoming_replies_max_depth` option

### Removed

- Federation: Remove `likes` from objects.
- **Breaking:** ActivityPub: The `accept_blocks` configuration setting.

## [1.0.4] - 2019-08-01

### Fixed

- Invalid SemVer version generation, when the current branch does not have commits ahead of tag/checked out on a tag

## [1.0.3] - 2019-07-31

### Security

- OStatus: eliminate the possibility of a protocol downgrade attack.
- OStatus: prevent following locked accounts, bypassing the approval process.
- TwitterAPI: use CommonAPI to handle remote follows instead of OStatus.

## [1.0.2] - 2019-07-28

### Fixed

- Not being able to pin unlisted posts
- Mastodon API: represent poll IDs as strings
- MediaProxy: fix matching filenames
- MediaProxy: fix filename encoding
- Migrations: fix a sporadic migration failure
- Metadata rendering errors resulting in the entire page being inaccessible
- Federation/MediaProxy not working with instances that have wrong certificate order
- ActivityPub S2S: remote user deletions now work the same as local user deletions.

### Changed

- Configuration: OpenGraph and TwitterCard providers enabled by default
- Configuration: Filter.AnonymizeFilename added ability to retain file extension with custom text

## [1.0.1] - 2019-07-14

### Security

- OStatus: fix an object spoofing vulnerability.

## [1.0.0] - 2019-06-29

### Security

- Mastodon API: Fix display names not being sanitized
- Rich media: Do not crawl private IP ranges

### Added

- Digest email for inactive users
- Add a generic settings store for frontends / clients to use.
- Explicit addressing option for posting.
- Optional SSH access mode. (Needs `erlang-ssh` package on some distributions).
- [MongooseIM](https://github.com/esl/MongooseIM) http authentication support.
- LDAP authentication
- External OAuth provider authentication
- Support for building a release using [`mix release`](https://hexdocs.pm/mix/master/Mix.Tasks.Release.html)
- A [job queue](https://git.pleroma.social/pleroma/pleroma_job_queue) for federation, emails, web push, etc.
- [Prometheus](https://prometheus.io/) metrics
- Support for Mastodon's remote interaction
- Mix Tasks: `mix pleroma.database bump_all_conversations`
- Mix Tasks: `mix pleroma.database remove_embedded_objects`
- Mix Tasks: `mix pleroma.database update_users_following_followers_counts`
- Mix Tasks: `mix pleroma.user toggle_confirmed`
- Mix Tasks: `mix pleroma.config migrate_to_db`
- Mix Tasks: `mix pleroma.config migrate_from_db`
- Federation: Support for `Question` and `Answer` objects
- Federation: Support for reports
- Configuration: `poll_limits` option
- Configuration: `pack_extensions` option
- Configuration: `safe_dm_mentions` option
- Configuration: `link_name` option
- Configuration: `fetch_initial_posts` option
- Configuration: `notify_email` option
- Configuration: Media proxy `whitelist` option
- Configuration: `report_uri` option
- Configuration: `email_notifications` option
- Configuration: `limit_to_local_content` option
- Pleroma API: User subscriptions
- Pleroma API: Healthcheck endpoint
- Pleroma API: `/api/v1/pleroma/mascot` per-user frontend mascot configuration endpoints
- Admin API: Endpoints for listing/revoking invite tokens
- Admin API: Endpoints for making users follow/unfollow each other
- Admin API: added filters (role, tags, email, name) for users endpoint
- Admin API: Endpoints for managing reports
- Admin API: Endpoints for deleting and changing the scope of individual reported statuses
- Admin API: Endpoints to view and change config settings.
- AdminFE: initial release with basic user management accessible at /pleroma/admin/
- Mastodon API: Add chat token to `verify_credentials` response
- Mastodon API: Add background image setting to `update_credentials`
- Mastodon API: [Scheduled statuses](https://docs.joinmastodon.org/api/rest/scheduled-statuses/)
- Mastodon API: `/api/v1/notifications/destroy_multiple` (glitch-soc extension)
- Mastodon API: `/api/v1/pleroma/accounts/:id/favourites` (API extension)
- Mastodon API: [Reports](https://docs.joinmastodon.org/api/rest/reports/)
- Mastodon API: `POST /api/v1/accounts` (account creation API)
- Mastodon API: [Polls](https://docs.joinmastodon.org/api/rest/polls/)
- ActivityPub C2S: OAuth endpoints
- Metadata: RelMe provider
- OAuth: added support for refresh tokens
- Emoji packs and emoji pack manager
- Object pruning (`mix pleroma.database prune_objects`)
- OAuth: added job to clean expired access tokens
- MRF: Support for rejecting reports from specific instances (`mrf_simple`)
- MRF: Support for stripping avatars and banner images from specific instances (`mrf_simple`)
- MRF: Support for running subchains.
- Configuration: `skip_thread_containment` option
- Configuration: `rate_limit` option. See `Pleroma.Plugs.RateLimiter` documentation for details.
- MRF: Support for filtering out likely spam messages by rejecting posts from new users that contain links.
- Configuration: `ignore_hosts` option
- Configuration: `ignore_tld` option
- Configuration: default syslog tag "Pleroma" is now lowercased to "pleroma"

### Changed

- **Breaking:** bind to 127.0.0.1 instead of 0.0.0.0 by default
- **Breaking:** Configuration: move from Pleroma.Mailer to Pleroma.Emails.Mailer
- Thread containment / test for complete visibility will be skipped by default.
- Enforcement of OAuth scopes
- Add multiple use/time expiring invite token
- Restyled OAuth pages to fit with Pleroma's default theme
- Link/mention/hashtag detection is now handled by [auto_linker](https://git.pleroma.social/pleroma/auto_linker)
- NodeInfo: Return `safe_dm_mentions` feature flag
- Federation: Expand the audience of delete activities to all recipients of the deleted object
- Federation: Removed `inReplyToStatusId` from objects
- Configuration: Dedupe enabled by default
- Configuration: Default log level in `prod` environment is now set to `warn`
- Configuration: Added `extra_cookie_attrs` for setting non-standard cookie attributes. Defaults to ["SameSite=Lax"] so that remote follows work.
- Timelines: Messages involving people you have blocked will be excluded from the timeline in all cases instead of just repeats.
- Admin API: Move the user related API to `api/pleroma/admin/users`
- Admin API: `POST /api/pleroma/admin/users` will take list of users
- Pleroma API: Support for emoji tags in `/api/pleroma/emoji` resulting in a breaking API change
- Mastodon API: Support for `exclude_types`, `limit` and `min_id` in `/api/v1/notifications`
- Mastodon API: Add `languages` and `registrations` to `/api/v1/instance`
- Mastodon API: Provide plaintext versions of cw/content in the Status entity
- Mastodon API: Add `pleroma.conversation_id`, `pleroma.in_reply_to_account_acct` fields to the Status entity
- Mastodon API: Add `pleroma.tags`, `pleroma.relationship{}`, `pleroma.is_moderator`, `pleroma.is_admin`, `pleroma.confirmation_pending`, `pleroma.hide_followers`, `pleroma.hide_follows`, `pleroma.hide_favorites` fields to the User entity
- Mastodon API: Add `pleroma.show_role`, `pleroma.no_rich_text` fields to the Source subentity
- Mastodon API: Add support for updating `no_rich_text`, `hide_followers`, `hide_follows`, `hide_favorites`, `show_role` in `PATCH /api/v1/update_credentials`
- Mastodon API: Add `pleroma.is_seen` to the Notification entity
- Mastodon API: Add `pleroma.local` to the Status entity
- Mastodon API: Add `preview` parameter to `POST /api/v1/statuses`
- Mastodon API: Add `with_muted` parameter to timeline endpoints
- Mastodon API: Actual reblog hiding instead of a dummy
- Mastodon API: Remove attachment limit in the Status entity
- Mastodon API: Added support max_id & since_id for bookmark timeline endpoints.
- Deps: Updated Cowboy to 2.6
- Deps: Updated Ecto to 3.0.7
- Don't ship finmoji by default, they can be installed as an emoji pack
- Hide deactivated users and their statuses
- Posts which are marked sensitive or tagged nsfw no longer have link previews.
- HTTP connection timeout is now set to 10 seconds.
- Respond with a 404 Not implemented JSON error message when requested API is not implemented
- Rich Media: crawl only https URLs.

### Fixed

- Follow requests don't get 'stuck' anymore.
- Added an FTS index on objects. Running `vacuum analyze` and setting a larger `work_mem` is recommended.
- Followers counter not being updated when a follower is blocked
- Deactivated users being able to request an access token
- Limit on request body in rich media/relme parsers being ignored resulting in a possible memory leak
- Proper Twitter Card generation instead of a dummy
- Deletions failing for users with a large number of posts
- NodeInfo: Include admins in `staffAccounts`
- ActivityPub: Crashing when requesting empty local user's outbox
- Federation: Handling of objects without `summary` property
- Federation: Add a language tag to activities as required by ActivityStreams 2.0
- Federation: Do not federate avatar/banner if set to default allowing other servers/clients to use their defaults
- Federation: Cope with missing or explicitly nulled address lists
- Federation: Explicitly ensure activities addressed to `as:Public` become addressed to the followers collection
- Federation: Better cope with actors which do not declare a followers collection and use `as:Public` with these semantics
- Federation: Follow requests from remote users who have been blocked will be automatically rejected if appropriate
- MediaProxy: Parse name from content disposition headers even for non-whitelisted types
- MediaProxy: S3 link encoding
- Rich Media: Reject any data which cannot be explicitly encoded into JSON
- Pleroma API: Importing follows from Mastodon 2.8+
- Twitter API: Exposing default scope, `no_rich_text` of the user to anyone
- Twitter API: Returning the `role` object in user entity despite `show_role = false`
- Mastodon API: `/api/v1/favourites` serving only public activities
- Mastodon API: Reblogs having `in_reply_to_id` - `null` even when they are replies
- Mastodon API: Streaming API broadcasting wrong activity id
- Mastodon API: 500 errors when requesting a card for a private conversation
- Mastodon API: Handling of `reblogs` in `/api/v1/accounts/:id/follow`
- Mastodon API: Correct `reblogged`, `favourited`, and `bookmarked` values in the reblog status JSON
- Mastodon API: Exposing default scope of the user to anyone
- Mastodon API: Make `irreversible` field default to `false` [`POST /api/v1/filters`]
- Mastodon API: Replace missing non-nullable Card attributes with empty strings
- User-Agent is now sent correctly for all HTTP requests.
- MRF: Simple policy now properly delists imported or relayed statuses

## Removed

- Configuration: `config :pleroma, :fe` in favor of the more flexible `config :pleroma, :frontend_configurations`

## [0.9.99999] - 2019-05-31

### Security

- Mastodon API: Fix lists leaking private posts

## [0.9.9999] - 2019-04-05

### Security

- Mastodon API: Fix content warnings skipping HTML sanitization

## [0.9.999] - 2019-03-13

Frontend changes only.

### Added

- Added floating action button for posting status on mobile

### Changed

- Changed user-settings icon to a pencil

### Fixed

- Keyboard shortcuts activating when typing a message
- Gaps when scrolling down on a timeline after showing new

## [0.9.99] - 2019-03-08

### Changed

- Update the frontend to the 0.9.99 tag

### Fixed

- Sign the date header in federation to fix Mastodon federation.

## [0.9.9] - 2019-02-22

This is our first stable release.
