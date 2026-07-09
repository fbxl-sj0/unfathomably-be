# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
### Fixed
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
