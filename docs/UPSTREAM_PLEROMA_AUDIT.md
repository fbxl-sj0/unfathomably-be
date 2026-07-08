# Upstream Pleroma Commit Audit

Project: Unfathomably BE

Purpose:

    Track upstream Pleroma commits as they are reviewed for backporting into
    Unfathomably BE. This file exists so the project can move through upstream
    work once, mark the decision, and avoid repeatedly rechecking the same
    commits during later polishing passes.

Responsibilities:

    * list upstream commits in a stable audit order
    * record whether each commit is implemented, not applicable, superseded,
      deferred, or still pending review
    * capture the local evidence or reason for the decision
    * provide a clear next action for unfinished commits

This file intentionally does NOT contain:

    * full upstream diffs
    * deployment logs
    * source code backport instructions that belong near the code or tests

/* ------------------------------------------------------------------------- */
/* Audit scope                                                               */
/* ------------------------------------------------------------------------- */

Expanded Rebased/Pleroma audit anchor: `b221d77a6`.

    b221d77a6  2021-03-02 19:54:30 +0000  Merge branch 'release/2.3.0' into 'stable'

Previous group-era audit anchor: `b11dbbf40`.

    b11dbbf40  2021-08-17 18:32:32 -0500  UserController: fall back to frontend when user isn't found

Primary Rebased develop split anchor: `ca1b18ba2`.

    ca1b18ba2  2023-11-15 08:20:37 +0000  Merge branch 'federation_status-access' into 'develop'

Additional Rebased branch anchors checked while expanding the scope:

    origin/pleroma-ci: b221d77a6  2021-03-02 19:54:30 +0000  Merge branch 'release/2.3.0' into 'stable'
    origin/cycles: e3173a279  2021-05-19 14:27:46 -0500  Put Plugs in runtime mode in :dev, :test, and :benchmark
    origin/groups: b11dbbf40  2021-08-17 18:32:32 -0500  UserController: fall back to frontend when user isn't found
    origin/pleroma-events: 7f0b3161e  2022-11-20 23:40:58 +0000  Merge branch 'akoma/deactivated-users' into 'develop'
    origin/pleroma and origin/more-fixes: a94cf2ad4  2023-09-03 09:09:27 +0000  Merge branch 'check-attachment-attribution' into 'develop'
    origin/main: 7566b4a34  2024-05-22 15:17:36 +0000  Merge branch 'release-2.6.3' into 'stable'

The expanded anchor comes from the sibling Rebased checkout at
`E:\soapbox and rebased\rebased-fbxl\pleroma` by checking merge-bases between
reachable Rebased branches and `refs/remotes/pleroma-upstream/develop`. Earlier
passes used `origin/groups` because that was the oldest branch checked for
Unfathomably group work. A full branch sweep found `origin/pleroma-ci` sharing
upstream history at `b221d77a6`, so this audit now uses that older anchor as the
governing lower bound. The older group and develop anchors remain recorded
because they explain why earlier passes appeared to start around August 2021 or
November 2023.

Complete upstream manifest: docs/UPSTREAM_PLEROMA_FULL_MANIFEST.md.

The complete manifest starts at upstream Pleroma's first reachable commit and
exists because this repository no longer has a clean ancestry relationship with
upstream Pleroma. This focused audit remains the source of evidence-backed
backport decisions. When older pre-anchor commits are reviewed, either record the
evidence in this file or update the manifest row to point at the local evidence.

Current upstream Pleroma ref: `pleroma-upstream/develop` at `b0ae45194`.

    b0ae45194  2026-06-29 12:51:43 +0000  Merge pull request 'Allow attaching emojis to user lists' (#7929) from mkljczk/pleroma:list-emoji into develop

Expanded upstream Pleroma commits after `b221d77a6`: 4,775.
Previously scoped upstream commits after `ca1b18ba2`: 2,591.
Additional pre-`ca1b18ba2` upstream commits now in scope: 2,184.

Rebased-side commits after expanded anchor: 10 on `origin/pleroma-ci`.
Rebased-side commits after develop anchor: 903 on `origin/develop`.
Rebased-side commits after origin/pleroma anchor: recorded for comparison, but
the expanded 2021-03-02 anchor is the governing lower bound for this audit.

Rows are ordered with `git log --topo-order --reverse` from the expanded anchor
to current upstream Pleroma develop. Commit dates are committer dates, which
better reflect when a branch landed upstream than author dates on old topic
branches.

Important audit note:

    The first-parent path after the split mostly shows recent merge commits, but
    the full reachable upstream set includes topic-branch commits with author
    dates as early as 2020. Those older commits are in scope. Audit rows should
    therefore be advanced from the full commit table below, not from first-parent
    history alone.

    Do not restart from the 2026 tail, the 2023 develop merge-base, or the
    2021 group branch anchor unless the full table says those rows are next.
    The point of this file is to walk every upstream row after the oldest
    reachable Rebased/Pleroma anchor exactly once.

    Do not recompute the audit lower bound from this imported Unfathomably BE
    repository alone. Its local history may not share a useful Git merge-base
    with official Pleroma after source promotion and release engineering work.
    Use the recorded Rebased sibling anchors and this generated full table as
    the source of truth for audit ordering.

Status values:

* pending: not reviewed yet
* implemented: equivalent behavior is present locally
* not-applicable: upstream change does not apply to this fork
* superseded: local code solves the same problem differently
* deferred: useful but intentionally postponed
* needs-work: reviewed and found to require a backport or local fix

Update rule: when a commit is reviewed, change only that row. Keep the upstream
commit hash and subject unchanged so future searches remain stable.

/* ------------------------------------------------------------------------- */
/* Already audited quick index                                               */
/* ------------------------------------------------------------------------- */

| Commit | Status | Local evidence | Next action |
| --- | --- | --- | --- |
| `15a8acbd6` | implemented | Docs.Generator and MRF load modules before introspection. | No recheck. |
| `003d3312f` | implemented | Historical quoteUrl index migration creates the index concurrently. | No recheck. |
| `b70ca7d54` | implemented | AnalyzeMetadata no longer requires ImageMagick commands. | No recheck. |
| `06c58bce0` | implemented | Default scrubber includes upstream HTML4/GoToSocial safe formatting tags. | No recheck. |
| `e21660347` | implemented | Scrobble externalLink is present with legacy url compatibility. | No recheck. |
| `1ad0d94d6` | implemented | Instance.set_reachable/1 uses conflict-safe upsert and updates cache. | No recheck. |
| `13baba90f` | implemented | Media preview still-image thumbnails use Vix/libvips instead of ImageMagick convert. | No recheck. |
| `0c6a54b37` | implemented | Upload image metadata uses Vix dimensions and a small-image BlurHash path. | No recheck. |
| `03db495e1` | superseded | rinpatch_blurhash is replaced locally with maintained Hex BlurHash 2.0 to avoid older dependency constraints. | No action. |
| `1955b3c55` | implemented | Vips media-preview/upload-metadata cluster is backported and modernized. | No recheck. |
| `50e7706b2` | implemented | Local rel="me" verification and background worker handling are present with stronger local profile URL matching. | No recheck. |
| `47ce33a90` | implemented | verify_field_link/2 now stamps verified_at only for confirmed rel="me" links. | No recheck. |
| `5ff3783d0` | implemented | Full nicknames and instance metadata use the configured WebFinger host. | No recheck. |
| `39d3df86c` | implemented | WebFinger.host/0 is canonical, with domain/0 kept as a compatibility alias. | No recheck. |
| `8ac7cc98c` | implemented | last_status_at renders as a Mastodon-compatible date string. | No recheck. |
| `a5aa8ea79` | implemented | Server-generated frontend metadata includes configured favicon and PWA manifest links. | No recheck. |
| `5d3e145dc` | implemented | RedirectController metadata insertion is centralized through compose_meta/build_meta. | No recheck. |
| `637926dcb` | deferred | Upstream frontend-management docs need Unfathomably-specific adaptation before import. | Revisit with documentation hardening. |
| `2112e8b5e` | deferred | Upstream frontend-management media/docs are Pleroma-specific. | Revisit with documentation hardening. |
| `9c57f17af` | deferred | Merge commit for frontend-management docs. | Revisit with documentation hardening. |
| `27df2c0ce` | implemented | Report status stripping is defensive locally. | No recheck. |
| `4ef56c5b6` | implemented | Report status stripping keeps only valid object IDs. | No recheck. |
| `66cb3294e` | 2022-11-02 | Mark Felder | Switch to PromEx for prometheus metrics | implemented | `lib/pleroma/prom_ex.ex`, `config/dev.exs`, `config/test.exs` | PromEx metrics integration is present locally. |
| e776d8b3 | implemented | GenerateUnsetUserKeys uses a migration-local schema. | No recheck. |
|  151591da | implemented | Implemented locally with stronger accepted-state transition handling in FollowingRelationship and atomic local User counter helpers. | No recheck unless follow-counter behavior regresses. |
| `033618b25` | implemented | EmojiReact URL-encoding regression coverage is represented by the centralized emoji URL/tag handling and local custom emoji reaction tests. | No recheck unless EmojiReact custom emoji URLs regress. |
| `07c65adb0` | 2026-06-10 | Phantasm | Grouped Notifications: Add feature flag to instance view and nodeinfo | implemented | `lib/pleroma/web/mastodon_api/views/instance_view.ex`, NodeInfo metadata | Local instance metadata advertises `mastodon_api_grouped_notifications` and `notifications_v2`. |
| `0ec0ad855` | implemented | Follow-request pagination was already backported and documented in CHANGELOG.md. | No recheck unless follow-request pagination regresses. |
| `19f3e2050` | implemented | Emoji.local_url/1 is present and callsites use it for local custom emoji paths with unusual filenames. | No recheck. |
| `2082bf729` | implemented | Poll votersCount behavior is present in PollView tests and rendering. | No recheck. |
| `227c7fafa` | deferred | Test synchronization only; no runtime behavior. Review only if the affected global-state tests become flaky locally. | No runtime action. |
| `2620b89cb` | implemented | Merge commit for the emoji URL-escape cluster; covered by the individual emoji rows above. | No recheck. |
| `2c20b3fc0` | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries the Unfathomably-facing release note instead. | No code action. |
| `30839063e` | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries Unfathomably release notes. | No code action. |
| `39279292b` | deferred | The upstream documentation partly describes Oban Web, which is not enabled locally in this pass. | Add adapted dashboard docs if Oban Web is later accepted. |
| `3ef98652f` | implemented | Account rendering, custom emoji listing, bookmark folders, util emoji output, and ActivityPub emoji tags encode local/remote emoji URLs. | No recheck. |
| `47ca42749` | implemented | User search already has resolved URI/AP-ID boosts, FTS/trigram ranking, domain filtering, and DB checkout hardening. | No recheck. |
| `47f4bde0e` | implemented | ConfigDB validates stored :rate_limit values through Pleroma.EctoType.Config.RateLimit. | No recheck. |
| `592be493c` | implemented | MFM parser integration is present in the formatting stack. | No recheck. |
| `5e114931f` | implemented | LiveDashboard now mounts at /pleroma/live_dashboard and the legacy /phoenix/live_dashboard path redirects there. | No recheck. |
| `619db0adc` | implemented | Websocket plug and endpoint echo sec-websocket-protocol and keep EventSource fallback. | No recheck. |
| `619ff5b9e` | implemented | Dashboard routes are filtered out of generated API route metadata so frontend/admin route overrides do not misclassify them. | No recheck. |
| `621d86a31` | implemented | WebFinger nickname validation checks actor/account consistency and preserves local generated-nickname compatibility. | No recheck. |
| `6b86e31e5` | implemented | MFM scrubber support is present in the default scrubber policy. | No recheck. |
| `727e9e774` | implemented | Poll rendering prefers remote votersCount and avoids inflating duplicate multi-option voters. | No recheck. |
| `7b134e7aa` | implemented | Own-account follow-request count optimization was already backported and documented in CHANGELOG.md. | No recheck. |
| `86dd9663f` | 2026-06-01 | Henry Jameson | allow <center> (used by mfm) | implemented | `priv/scrubbers/default.ex` | Default scrubber allows `<center>` with no attributes, preserving MFM center markup without broad sanitizer loosening. |
| `958a4581d` | implemented | RateLimiter fetch_and_normalize_limits/1 handles invalid configured limits without crashing and falls back to defaults or disables the limiter. | No recheck. |
| `9b331d648` | implemented | HTTP signature helper checks explicit true from HTTPSignatures.validate_conn/2. | No recheck. |
| `9dd02ecd5` | implemented | Mastodon websocket protocol-token handshake behavior is covered by the local websocket plug/tests. | No recheck. |
| `9ed6d78cb` | not-applicable | Upstream lint-only commit in the emoji URL cluster; local code already contains the semantic fix. | No code action. |
| `9ede9b92d` | implemented | RateLimiter invalid-value behavior is covered by the local RateLimit type and fallback-to-default normalization path. | No recheck unless rate-limit config crashes. |
| `aec0deef8` | implemented | Object vote-count handling for remote votersCount was reviewed with the poll rendering cluster. | No recheck unless poll counts regress. |
| `b054c2aa4` | implemented | Featured collection page handling is present through prepare_featured_collection/1 and embedded first-page tests. | No recheck. |
| `b0ae45194` | 2026-06-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Allow attaching emojis to user lists' (#7929) from mkljczk/pleroma:list-emoji into develop | implemented | `lib/pleroma/list.ex`, `lib/pleroma/web/mastodon_api/views/list_view.ex` | Merge-only upstream commit; list emoji support is present locally. |
| `b2469404a` | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries the Unfathomably-facing release note instead. | No code action. |
| `b9c281a0c` | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries the Unfathomably-facing release note instead. | No code action. |
| `bac607c7c` | implemented | Emoji.build_emoji_tag/1 is present and Builder/Transmogrifier use it instead of hand-built emoji tags. | No recheck. |
| `bd6191627` | implemented | Pleroma.EctoType.Config.RateLimit exists and both ConfigDB and RateLimiter use it. | No recheck. |
| `c6d1cead8` | 2026-06-23 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Allow attaching emojis to user lists | implemented | `lib/pleroma/list.ex`, `lib/pleroma/web/mastodon_api/views/list_view.ex` | User lists store, validate, and render unicode or local custom emoji metadata. |
| `cb0a1d160` | 2026-06-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Grouped Notifications: Add feature flag to instance view and nodeinfo' (#7926) from phnt/pleroma:grouped-notifs-flag into develop | implemented | `lib/pleroma/web/mastodon_api/views/instance_view.ex`, NodeInfo metadata | Merge-only upstream commit; grouped notification feature advertising is present locally. |
| `e1b2e788d` | implemented | MFM parser dependency is present and local scrubbers support the upstream MFM classes/attributes. | No recheck. |
| `e671ca255` | deferred | LiveView/Plug versions are already newer locally, but Oban Web adds a new dashboard dependency and route surface not enabled in this pass. | Decide separately whether to ship Oban Web after dependency/licensing/security review. |
| `ee19d14b0` | not-applicable | Upstream lint-only commit in the rate-limit cluster; local implementation is already warning-clean in the touched modules. | No code action. |
| `f579dc099` | implemented | Published pleroma_mfm_parser dependency is in mix.exs/mix.lock. | No recheck. |
| `f99ce5b2e` | implemented | Featured collection fetch path accepts embedded and URL first pages in the local ActivityPub pipeline. | No recheck. |
| `ffff2098f` | implemented | Signature validation only treats literal true as success before falling back to historical keys. | No recheck. |

/* ------------------------------------------------------------------------- */
/* Full upstream develop ledger since expanded Rebased branch anchor           */
/* ------------------------------------------------------------------------- */

| Commit | Date | Author | Subject | Status | Local evidence | Next action |
| --- | --- | --- | --- | --- | --- | --- |

| `94db0b7cd` | 2021-07-27 | Alex Gleason | Add activity+json to Phoenix :format_encoders Fixes ErrorView rendering | implemented | Phoenix format encoders include `"activity+json": Jason`, so ActivityPub JSON error rendering uses the JSON error path. | No recheck. |
| `167e14416` | 2021-07-14 | Alex Gleason | AdminAPI: add date to users | implemented | Admin account rendering includes `created_at` from `user.inserted_at` in Mastodon date form. | No recheck. |
| `be2da95c3` | 2021-06-29 | Alex Gleason | Correctly purge a remote user | implemented | `User.delete/1` purges users immediately and schedules background deletion, while purge preserves AP identity for remote users. | No recheck. |
| `c6d413372` | 2021-06-29 | Alex Gleason | Deletions: purge the user immediately | implemented | `User.delete/1` runs `purge/1` before enqueueing the delete-user worker. | No recheck. |
| `01c2d2a29` | 2021-06-29 | Alex Gleason | Also purge the user in User.perform/2 | implemented | The delete-user worker path still funnels through user deletion cleanup and activity removal after the immediate purge. | No recheck. |
| `a7929c4d8` | 2021-06-29 | Alex Gleason | Deletions: preserve account status fields during purge, fix checks | implemented | `purge_user_changeset/1` preserves account identity fields while clearing profile data and deactivating the account. | No recheck. |
| `43800d83f` | 2021-06-30 | Alex Gleason | Deletions: allow deactivated users to be deleted | implemented | Delete and Undo validators use operation-specific actor checks that accept cached deactivated actors for cleanup activities. | No recheck. |
| `beb1c98ab` | 2021-06-30 | Alex Gleason | Deletions: don't purge keys so Delete/Undo activities can be signed | implemented | `purge_user_changeset/1` does not clear signing keys, preserving the ability to sign Delete/Undo cleanup traffic. | No recheck. |
| `1c3fe43d2` | 2021-06-04 | Alex Gleason | ReverseProxy: create Client.Wrapper to call client from config Speeds up recompilation by reducing compile-time cycles | implemented | `Pleroma.ReverseProxy.Client.Wrapper` exists and ReverseProxy dispatches through `client()` at runtime. | No recheck. |
| `9879c1854` | 2021-06-01 | Alex Gleason | Avoid `use Phoenix.Swoosh` to prevent recompiling the Endpoint Speeds up recompilation by fixing cycles in UserEmail | implemented | Email rendering uses the dedicated email view/render path without `use Phoenix.Swoosh` in user email modules. | No recheck. |
| `07fed0fda` | 2021-05-18 | Alex Gleason | Switch to aliasing `Router.Helpers` instead of importing | implemented | Router helper usage is namespaced through aliases such as `Router.Helpers` instead of broad helper imports. | No recheck. |
| `e3173a279` | 2021-05-19 | Alex Gleason | Put Plugs in runtime mode in :dev, :test to speed up recompilation | implemented | Dev and test configure `:phoenix, :plug_init_mode` as `:runtime`. | No recheck. |
| `21787546c` | 2021-05-28 | Alex Gleason | Router: move StaticFEPlug to a pipeline Speed up recompilation by breaking a cycle. Removes StaticFEPlug as a compile-time dep of Router. | implemented | `StaticFEPlug` is mounted in the browser pipeline instead of forcing a compile-time router dependency. | No recheck. |
| `fda34591c` | 2021-05-28 | Alex Gleason | Don't make MediaProxy be a compile-dep of Router Speeds up recompilation by removing MediaProxy as a compile-time dep of Router | implemented | MediaProxy route handling is isolated under the media-proxy scope and runtime modules rather than compile-time router helpers. | No recheck. |
| `3ebede4b5` | 2021-05-29 | Alex Gleason | Gun: make Gun.API a runtime dep Speed up recompilation by breaking a compile-time cycle | implemented | `Pleroma.Gun.API` exists as a wrapper module for runtime Gun calls. | No recheck. |
| `0ada3fe82` | 2021-05-29 | Alex Gleason | Gun: use runtime deps in ConnectionPool Speed up recompilation time by breaking compile-time cycles | implemented | Gun connection-pool workers use runtime wrapper functions and registry helpers, matching the compile-cycle reduction intent. | No recheck. |
| `32d263cb9` | 2021-05-29 | Alex Gleason | Config: use runtime deps instead of module attributes Speeds up recompilation time by breaking compile-time cycles | implemented | Runtime configuration access is used for the affected web and HTTP helper paths instead of stale compile-time module attributes. | No recheck. |
| `c9e4200ed` | 2021-05-29 | Alex Gleason | Create real Views for all Controllers This makes views depend on each other at runtime instead of compile-time | implemented | The current web tree has dedicated view modules for controller rendering, including email and API views. | No recheck. |
| `3ff9c5e2a` | 2021-05-29 | Alex Gleason | Break out activity-specific HTML functions into Pleroma.Activity.HTML Fixes cycles in lib/pleroma/ecto_type/activity_pub/object_validators/safe_text.ex | implemented | `Pleroma.Activity.HTML` exists and owns activity-specific HTML helpers. | No recheck. |
| `fa543a936` | 2021-05-29 | Alex Gleason | ActivityPub.Pipeline: switch to runtime deps Speed up recompilation by breaking compile-time cycles | implemented | ActivityPub pipeline dependencies are resolved through runtime module calls in the modern pipeline. | No recheck. |
| `c23b81e39` | 2021-05-28 | Alex Gleason | Pleroma.Web.get_api_routes/0 --> Pleroma.Web.Router.get_api_routes/0 Reduce recompilation time by breaking compile-time cycles | implemented | `Pleroma.Web.Router.get_api_routes/0` exists; the old `Pleroma.Web.get_api_routes/0` path is not used. | No recheck. |
| `2e682788a` | 2021-05-30 | Alex Gleason | Merge commit '07fed0fda2473fc4e1e3b01e863217391fd2902f'; commit 'e3173a279dad89dfce6eae89368ad3ba180c0490'; commit '21787546c01069d1d1d8261f0bc37d13a73122a9'; commit 'fda34591cefad94277385311c6391d1ca2adb36c'; commit '0ada3fe823a3c2e6c5835431bdacfbdb8b3d02a7'; commit '32d263cb905dd7fffd43a4955295af0b2b378537'; commit 'c9e4200ed2167772294fceb4f282979b5ea04981'; commit '3ff9c5e2a67ab83c2abdb14cd246dea059079e75'; commit 'fa543a936124abee524f9a103c17d2601176dcd4'; commit 'c23b81e399d5be6fc30f4acb1d757d5eb291d8e1' into cycles-phase-1 | implemented | Merge-only compile-cycle cluster; all individual runtime-dependency changes in the cluster are present locally. | No recheck. |
| `8a5ceb7e5` | 2021-06-01 | Alex Gleason | Remove deps from Uploader behaviour Speeds up recompilation by limiting compile-time deps | implemented | Uploader behaviour is present as its own focused module and no longer carries the old compile-time web dependency pattern. | No recheck. |
| `10dfe8147` | 2021-05-31 | Alex Gleason | Pleroma.Constants.as_local_public/0 --> Pleroma.Web.ActivityPub.Utils.as_local_public/0 Move as_local_public/0 to stop making modules depend on Web at compile-time | implemented | `as_local_public/0` is provided by `Pleroma.Web.ActivityPub.Utils`, avoiding the old Web-level dependency. | No recheck. |
| `b22f54eb2` | 2021-05-16 | Alex Gleason | Make prod.secret.exs optional (with warning) | implemented | `config/prod.exs` imports `prod.secret.exs` only when present and logs a warning with the instance-gen hint when it is missing. | No recheck. |
| `b540fff90` | 2021-05-16 | Alex Gleason | Docs: use `MIX_ENV=prod mix pleroma.instance gen` | implemented | Installation docs use `MIX_ENV=prod mix pleroma.instance gen` for source installs. | No recheck. |
| `e9e17e5df` | 2020-12-11 | Alex Gleason | Upgrade Earmark to v1.4.10 | superseded | Runtime markdown rendering uses MDEx 0.13.2; Earmark remains only as an ExDoc parser dependency. | No action. |
| `ba71bbf61` | 2020-12-11 | Alex Gleason | Improve Formatter.minify/2 | superseded | The old `Formatter.minify/2` path is replaced by `compact_markdown_html/1` in the current formatter. | No action. |
| `c4f4e48e5` | 2020-12-11 | Alex Gleason | Remove some N/A tests | not-applicable | Upstream removed obsolete tests only; no runtime behavior to backport. | No code action. |
| `b2548cfcd` | 2020-12-11 | Alex Gleason | Sanitizer: allow <hr> tags | implemented | The default scrubber allows `<hr>` through the `:hr` tag policy. | No recheck. |
| `f8c93246d` | 2020-12-11 | Alex Gleason | Refactor Earmark code, fix tests | superseded | Markdown parsing is centralized through the current formatter and MDEx path rather than the old Earmark renderer. | No action. |
| `f1c67115d` | 2020-12-11 | Alex Gleason | Upgrade linkify, test URL issues, fixes #2026 #1942 | implemented | Linkify is locked at 0.5.3 and formatter linkification uses the current Linkify path. | No recheck. |
| `642729b49` | 2020-12-11 | Alex Gleason | Fix AudioVideoValidator markdown | implemented | `AudioImageVideoValidator.fix_content/1` converts `text/markdown` content through `Pleroma.Formatter.markdown_to_html/1`. | No recheck. |
| `6520599b7` | 2020-12-11 | Mark Felder | Update Earmark to 1.4.13, use the new compact_output mode | superseded | The Earmark compact-output update is superseded by MDEx rendering plus local compact markdown HTML cleanup. | No action. |
| `f318d8e56` | 2020-12-11 | Mark Felder | Use Pleroma.Formatter.markdown_to_html/1 in the tests | not-applicable | Upstream test-only formatter call cleanup; current tests target the modern formatter path. | No runtime action. |
| `004bcedb0` | 2021-04-30 | Alex Gleason | Upgrade Earmark 1.4.15 | superseded | The later Earmark upgrade is superseded by MDEx 0.13.2 for runtime markdown rendering. | No action. |
| `6727a3659` | 2021-04-30 | Alex Gleason | Remove Pleroma.Formatter.minify/2 | implemented | `Formatter.minify/2` is no longer present; compact markdown cleanup lives inside the formatter. | No recheck. |
| `53760d2cd` | 2021-04-30 | Alex Gleason | Delete obsolete EarmarkRendereTests (moved to UtilsTest) | not-applicable | Upstream deleted obsolete Earmark renderer tests; no runtime behavior applies. | No code action. |
| `a8fa00ef6` | 2021-04-30 | Alex Gleason | Fix failing remote mentions test, valid TLDs | implemented | The Linkify 0.5.3 upgrade and current formatter tests cover the valid-TLD remote mention behavior. | No recheck. |
| `85b2387f6` | 2021-03-02 | Mark Felder | Fix build_application/1 match | implemented | `StatusView.build_application/1` accepts generator maps with `type`, `name`, and `url` and safely returns nil otherwise. | No recheck. |
| `f0208980e` | 2021-03-02 | Mark Felder | Test both ingestion of post in the status controller and the correct response during the view | implemented | Status controller tests cover application metadata ingestion and rendering behavior. | No recheck. |
| `ccbf16208` | 2021-03-02 | Mark Felder | Actually test viewing status after ingestion | implemented | Status controller coverage includes viewing statuses after ingestion. | No recheck. |
| `210aa42f7` | 2021-03-02 | feld | Merge branch 'application-to-generator' into 'develop' | implemented | Merge-only application-generator cluster; the status rendering and tests are present locally. | No recheck. |
| `913d53b7d` | 2021-03-02 | Mark Felder | Remove useless header on the get request | not-applicable | Upstream removed a useless request header in tests only; no runtime behavior applies. | No code action. |
| `81e9c5196` | 2021-03-02 | Haelwenn | Merge branch 'fix/useless-header' into 'develop' | not-applicable | Merge-only test-cleanup commit for the useless-header change. | No code action. |
| `8d601d3b2` | 2021-03-02 | Mark Felder | Make the object reference in both render("show.json", _) functions consistently named | implemented | Status view render clauses use consistent activity/object references in the current show/history/source rendering paths. | No recheck. |
| `37c37090f` | 2021-03-02 | Haelwenn | Merge branch 'fix/inconsistent-reference' into 'develop' | implemented | Merge-only inconsistent-reference cleanup; current status view uses the cleaned render-shape. | No recheck. |
| `5b8cceba0` | 2021-03-02 | Mark Felder | Fix migration in cases where database name has a hyphen | implemented | The text-search config migration quotes `current_database()` inside `ALTER DATABASE`, handling database names with hyphens. | No recheck. |
| `49afbcda5` | 2021-03-03 | Haelwenn | Merge branch 'fix-migration' into 'develop' | implemented | Merge-only migration quoting fix; the migration is already hyphen-safe locally. | No recheck. |
| `c5352e90b` | 2021-03-03 | lain | Changelog, mix: merge in stable | not-applicable | Upstream changelog and stable merge bookkeeping; local release notes are Unfathomably-specific. | No code action. |
| `2e296c079` | 2021-03-03 | lain | Revert "StatusController: Deactivate application support for now." | implemented | Status rendering and controller tests support Mastodon-compatible application metadata when enabled. | No recheck. |
| `10f402af6` | 2021-03-03 | lain | Changelog: Re-add application support | not-applicable | Upstream changelog-only note for application support; local changelog carries current Unfathomably release notes. | No code action. |
| `13aa98d68` | 2021-03-03 | lain | Merge branch 'mergeback/2.3.0' into 'develop' | implemented | Mergeback cluster; the application metadata behavior and related tests are present locally. | No recheck. |
| `3aae5231b` | 2021-03-02 | Egor Kislitsyn | Add OpenAPI spec for AdminAPI.UserController | implemented | `Pleroma.Web.ApiSpec.Admin.UserOperation` documents the AdminAPI user controller operations. | No recheck. |
| `9876fa8e9` | 2021-03-04 | Egor Kislitsyn | Add UserOperation to Redoc | implemented | Admin UserOperation is included in the generated API spec/Redoc surface. | No recheck. |
| `7f413139f` | 2021-03-10 | Haelwenn | Merge branch 'openapi/admin/user' into 'develop' | implemented | Merge-only AdminAPI user OpenAPI cluster; the UserOperation module is present locally. | No recheck. |
| `8feeb672c` | 2021-03-10 | Mark Felder | Ensure we fetch deps during spec-build stage | implemented | The GitLab CI file fetches Mix deps in build/spec stages before generated API work. | No recheck. |
| `502d166b7` | 2021-03-10 | Mark Felder | See if switching to same image as releases fixes the build | not-applicable | Experimental CI image switch was reverted upstream and carries no lasting runtime behavior. | No code action. |
| `fa75f11ca` | 2021-03-10 | Mark Felder | Revert "See if switching to same image as releases fixes the build" | not-applicable | Revert of the experimental CI image switch; no local source behavior applies. | No code action. |
| `8e09a3cfa` | 2021-03-10 | feld | Merge branch 'fix/spec-build' into 'develop' | implemented | Merge-only spec-build CI cluster; the surviving deps-fetch behavior is represented locally. | No recheck. |
| `884584772` | 2021-03-11 | Mark Felder | Execute mix deps.get earlier and avoid duplicate invocations if possible | implemented | GitLab CI fetches Mix dependencies early in the build/spec flow, avoiding missing deps in generated spec jobs. | No recheck. |
| `9de2a5024` | 2021-03-11 | rinpatch | Merge branch 'improve-gitlab-ci' into 'develop' | implemented | Merge-only GitLab CI improvement cluster; current CI has the deps-fetch behavior. | No recheck. |
| `2408363e2` | 2021-03-13 | Ben Is | Translated using Weblate (Italian) | implemented | The Italian `errors.po` catalog exists locally; this translation-only update has no runtime code to backport. | No recheck. |
| `19fbe5b86` | 2021-03-14 | Haelwenn | Merge branch 'weblate-pleroma-pleroma' into 'develop' | implemented | Merge-only Weblate translation update; Italian catalog content is present locally. | No recheck. |
| `ee221277b` | 2020-12-21 | Ivan Tashkinov | Encapsulation of tags / hashtags fetching from objects. | implemented | `Object.object_data_hashtags/1` and `Object.embedded_hashtags/1` encapsulate hashtag extraction from object data. | No recheck. |
| `e369b1306` | 2020-12-22 | Ivan Tashkinov | Added Hashtag entity and objects-hashtags association with auto-sync with `data.tag` on Object update. | implemented | `Pleroma.Hashtag`, `hashtags_objects`, and object changeset hashtag sync are present locally. | No recheck. |
| `cbb19d0e1` | 2020-12-26 | Ivan Tashkinov | [#3213] Hashtag-filtering functions in ActivityPub. Mix task for migrating hashtags to `hashtags` table. | implemented | ActivityPub hashtag restrictions query `hashtags_objects`, and database maintenance includes hashtag migration/cleanup helpers. | No recheck. |
| `4134abef6` | 2020-12-26 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag rework branch; the hashtag schema, association, and filtering behavior are present locally. | No recheck. |
| `14fae94c0` | 2020-12-28 | Ivan Tashkinov | [#3213] Made Object.hashtags/1 work with :hashtags assoc. Adjusted tests. | implemented | `Object.hashtags/1` returns normalized embedded hashtags while the object association remains synchronized. | No recheck. |
| `a25c1e8ec` | 2020-12-30 | Ivan Tashkinov | [#3213] Improved `database.transfer_hashtags` mix task: proper rollback, speedup. | implemented | Database tasks include rollback-aware migration helpers and infinity-timeout hashtag maintenance paths. | No recheck. |
| `e0b5edb6d` | 2020-12-30 | Ivan Tashkinov | [#3213] Fixed Object.object_data_hashtags/1 to process only AS2 elements of `data.tag` (basing on #2984). | implemented | `Object.object_data_hashtags/1` extracts hashtag names from ActivityStreams tag maps and ignores non-hashtag shapes. | No recheck. |
| `8d1a0c1af` | 2020-12-30 | Ivan Tashkinov | [#3213] Made Object.object_data_hashtags/1 handle both AS2 and plain text hashtags. | implemented | `Object.object_data_hashtags/1` handles both AS2 hashtag maps and plain text hashtag entries. | No recheck. |
| `367f0c31c` | 2020-12-31 | Ivan Tashkinov | [#3213] Added query options support for Repo.chunk_stream/4. Used infinite timeout in transfer_hashtags select query. | implemented | `Repo.chunk_stream/4` accepts query options and callers use infinity timeouts for long maintenance queries. | No recheck. |
| `303055456` | 2020-12-31 | Ivan Tashkinov | Alternative implementation of hashtag-filtering queries in ActivityPub. Fixed GROUP BY clause for aggregation on hashtags. | implemented | ActivityPub hashtag filters use `hashtags_objects` joins and grouped/aggregate-safe query forms. | No recheck. |
| `48e0f22ab` | 2020-12-31 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag rework branch; local hashtag filtering and association code includes the final behavior. | No recheck. |
| `0d521022f` | 2021-01-07 | Ivan Tashkinov | [#3213] Removed PK from hashtags_objects table. Improved hashtags_transfer mix task (logging of failed ids). | implemented | `hashtags_objects` has no synthetic id PK, enforces the hashtag/object pair, and the migrator records failed object ids for review. | No recheck. |
| `8c972de04` | 2021-01-10 | Ivan Tashkinov | [#3213] transfer_hashtags mix task refactoring. | implemented | Hashtag transfer logic lives in `HashtagsTableMigrator` with chunked processing and failed-id tracking. | No recheck. |
| `3e4d84729` | 2021-01-13 | Ivan Tashkinov | [#3213] Prototype of data migrations functionality / HashtagsTableMigrator. | implemented | `Pleroma.DataMigration` and `Pleroma.Migrators.HashtagsTableMigrator` are present with the populate-hashtags data migration. | No recheck. |
| `e35089882` | 2021-01-13 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag migrator branch; the data migration and migrator are present locally. | No recheck. |
| `f5f267fa7` | 2021-01-14 | Ivan Tashkinov | [#3213] Refactoring of HashtagsTableMigrator. | implemented | The current HashtagsTableMigrator includes refactored state handling through the migrator support state module. | No recheck. |
| `48b399ced` | 2021-01-16 | Ivan Tashkinov | [#3213] Refactoring of HashtagsTableMigrator. Hashtag timeline performance optimization (auto switch to non-aggregate join strategy when efficient). | implemented | Hashtag timeline filters use the optimized non-aggregate join path by default with aggregate-safe fallbacks where needed. | No recheck. |
| `85f7ef4d1` | 2021-01-17 | Ivan Tashkinov | [#3213] Feature lock adjustment for HashtagsTableMigrator. | implemented | Data migrations support `feature_lock` and manual migration controls for the hashtag migrator lifecycle. | No recheck. |
| `9d28a7ebf` | 2021-01-17 | Ivan Tashkinov | [#3213] Missing copyright header for HashtagsTableMigrator.State. | not-applicable | Copyright/header-only cleanup for a module shape that is now folded into the current migrator file. | No code action. |
| `7f07909a7` | 2021-01-19 | Ivan Tashkinov | [#3213] Added `HashtagsTableMigrator.count/1`. | superseded | The old public `count/1` helper is superseded by current migrator status stats and failure counters. | No action. |
| `f0f0f2af0` | 2021-01-19 | Ivan Tashkinov | [#3213] `timeout` option for `HashtagsTableMigrator.count/_`. | superseded | The count-timeout helper is superseded by current infinity-timeout migrator cleanup and chunk-stream calls. | No action. |
| `b83060557` | 2021-01-19 | Ivan Tashkinov | [#3213] Performance-related stat in HashtagsTableMigrator. Reworked `count/_` to indicate approximate total count for current iteration. | implemented | The migrator records operational stats such as processed count, failed count, max id, and records per second. | No recheck. |
| `2634a16b4` | 2021-01-21 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag migrator branch; current migrator includes state and performance handling. | No recheck. |
| `c041e9c63` | 2021-01-21 | Ivan Tashkinov | [#3213] HashtagsTableMigrator: failures handling fix, retry function. Changed default hashtags filtering strategy to non-aggregate approach. | implemented | HashtagsTableMigrator has failed-object retry support and ActivityPub hashtag filtering uses the non-aggregate strategy. | No recheck. |
| `ca7f24064` | 2021-01-21 | Ivan Tashkinov | [#3213] Ignoring of blank elements from objects.data->tag. | implemented | `Object.object_data_hashtags/1` filters nil and blank hashtag elements from incoming object tags. | No recheck. |
| `218c51960` | 2021-01-22 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag migrator branch; final blank-tag and migrator behavior is present locally. | No recheck. |
| `f264d930c` | 2021-01-24 | Ivan Tashkinov | [#3213] Speedup of HashtagsTableMigrator (query optimization). State handling fix. | implemented | The current migrator uses chunked optimized queries and persistent state/stat handling for safe resumable migration. | No recheck. |
| `ea4785213` | 2021-01-25 | Ivan Tashkinov | [#3213] Switched to using embedded hashtags in Object.hashtags/1 (to avoid extra joins / preload in timeline queries). | implemented | `Object.hashtags/1` always uses embedded hashtags to avoid timeline-query preload joins. | No recheck. |
| `694d98be5` | 2021-01-25 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag branch; embedded hashtag reads are present locally. | No recheck. |
| `e7864a32d` | 2021-01-25 | Ivan Tashkinov | [#3213] Removed DISTINCT clause from ActivityPub.fetch_activities_query/2. | superseded | The temporary DISTINCT removal is superseded by the final hashtag-any filtering logic. | No action. |
| `380d0cce6` | 2021-01-29 | Ivan Tashkinov | [#3213] Reinstated DISTINCT clause for hashtag "any" filtering with 2+ terms. Added test. | implemented | Hashtag-any filtering restores DISTINCT when multiple tags can duplicate rows. | No recheck. |
| `9948ff335` | 2021-01-31 | Ivan Tashkinov | [#3213] Added HashtagsCleanupWorker periodic job. | implemented | Added a modernized scheduled HashtagsCleanupWorker that prunes orphaned hashtag links and old unused hashtags while preserving followed empty hashtags. | No recheck unless hashtag cleanup regresses. |
| `6fd4163ab` | 2021-01-31 | Ivan Tashkinov | [#3213] ActivityPub: implemented subqueries-based hashtags filtering, removed aggregation-based hashtags filtering. | implemented | ActivityPub hashtag filtering uses subquery/join based filtering rather than the old aggregate path. | No recheck. |
| `1b49b8efe` | 2021-01-31 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag filtering branch; current ActivityPub hashtag subquery filtering is present. | No recheck. |
| `108e90b18` | 2021-01-31 | Ivan Tashkinov | [#3213] Explicitly defined PKs in hashtags_objects and data_migration_failed_ids. Added "pleroma.database rollback" task to revert a single migration. | implemented | `hashtags_objects` and data migration failed-id tables have explicit key behavior, and `mix pleroma.database rollback` exists. | No recheck. |
| `10207f840` | 2021-01-31 | Ivan Tashkinov | [#3213] ActivityPub: temporarily reverted to previous hashtags filtering implementation due to blank results issue. | superseded | Temporary revert of hashtag filtering was superseded by the later fixed subquery implementation. | No action. |
| `cf4765af4` | 2021-01-31 | Ivan Tashkinov | [#3213] ActivityPub: fixed subquery-based hashtags filtering implementation (addressed empty list options issue). Added regression test. | implemented | Hashtag filtering handles empty list options and uses final subquery filtering behavior. | No recheck. |
| `4e1494567` | 2021-02-03 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag filtering branch; final subquery behavior is present locally. | No recheck. |
| `d1c6dd97a` | 2021-02-07 | Ivan Tashkinov | [#3213] Partially addressed code review points. migration rollback task changes, hashtags-related config handling tweaks, `hashtags.data` deletion (unused). | implemented | Database rollback task, hashtag config handling, and removal of unused `hashtags.data` are represented in the current schema/tasks. | No recheck. |
| `a996ab46a` | 2021-02-11 | Ivan Tashkinov | [#3213] Reorganized hashtags cleanup. Transaction-wrapped Hashtag.get_or_create_by_names/1. Misc. improvements. | implemented | `Hashtag.get_or_create_by_names/1` uses transaction-wrapped insert-all/upsert behavior and cleanup helpers are centralized. | No recheck. |
| `5992382cf` | 2021-02-11 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag cleanup branch; transaction-wrapped hashtag creation and cleanup helpers are present. | No recheck. |
| `349b8b0f4` | 2021-02-13 | Ivan Tashkinov | [#3213] `rescue` around potentially-raising `Repo.insert_all/_` calls. Misc. improvements (docs etc.). | implemented | Hashtag insert-all paths rescue database errors and the migrator rolls back failed object ids cleanly. | No recheck. |
| `1dac7d146` | 2021-02-15 | Ivan Tashkinov | [#3213] Fixed `hashtags.name` lookup (must use `citext` type to do index scan). Fixed embedded hashtags lookup (lowercasing), adjusted tests. | implemented | Hashtag lookup and embedded tag extraction normalize names for case-insensitive matching and index-friendly queries. | No recheck. |
| `938823c73` | 2021-02-16 | Ivan Tashkinov | [#3213] HashtagsTableMigrator state management refactoring & improvements (proper stats serialization etc.). | implemented | HashtagsTableMigrator state is handled through serializable migrator state helpers and persisted stats. | No recheck. |
| `111bfdd3a` | 2021-02-16 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag state-management branch; current migrator support state modules are present. | No recheck. |
| `854ea1aef` | 2021-02-17 | Ivan Tashkinov | [#3213] Fixed `HashtagsTableMigrator.count/1`. | superseded | The old `HashtagsTableMigrator.count/1` fix is superseded by current migrator stat/failure accounting. | No action. |
| `b981edad8` | 2021-02-18 | Ivan Tashkinov | [#3213] HashtagsTableMigrator: fault rate allowance to enable the feature (defaults to 1%), counting of affected objects, misc. tweaks. | implemented | HashtagsTableMigrator includes fault-rate allowance, affected-count tracking, and records-per-second stats. | No recheck. |
| `998437d4a` | 2021-02-18 | Ivan Tashkinov | [#3213] Experimental / debug feature: `database: [improved_hashtag_timeline: :preselect_hashtag_ids]`. | implemented | The final hashtag filtering path includes preselected hashtag id optimization behavior without retaining the old debug-only shape. | No recheck. |
| `6531eddf3` | 2021-02-22 | Ivan Tashkinov | [#3213] `hashtags`: altered `name` type to `text`. `hashtags_objects`: removed unused index. HashtagsTableMigrator: records_per_second calculation fix. ActivityPub: hashtags-related options normalization. | implemented | `hashtags.name` text migration, duplicate-index removal, records-per-second fix, and hashtag option normalization are present. | No recheck. |
| `a98c4423f` | 2021-02-22 | Ivan Tashkinov | Apply i1t's suggestion(s) to 1 file(s) | not-applicable | Description wording cleanup only; no runtime behavior applies. | No code action. |
| `77f3da035` | 2021-02-23 | Ivan Tashkinov | [#3213] Misc. tweaks: proper upsert in Hashtag, better feature toggle management. | implemented | Hashtag upsert uses conflict-target handling and improved feature-toggle management is present in the migrator/config path. | No recheck. |
| `8f88a90ca` | 2021-02-23 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag branch; upsert and feature-toggle behavior is present locally. | No recheck. |
| `40d436226` | 2021-02-23 | Ivan Tashkinov | [#3213] `mix pleroma.database rollback` tweaks. | implemented | `mix pleroma.database rollback` task supports reverting a specific migration with explicit error handling. | No recheck. |
| `882dd4684` | 2021-03-02 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag branch; current migrator and rollback task include the final behavior. | No recheck. |
| `5856f5171` | 2021-03-03 | Ivan Tashkinov | [#3213] ActivityPub hashtags filtering refactoring. Test fix. | implemented | ActivityPub hashtag filtering has the later refactored helper shape and Repo support needed by that path. | No recheck. |
| `7f8785fd9` | 2021-03-07 | Ivan Tashkinov | [#3213] Performance optimization of filtering by hashtags ("any" condition). | implemented | Hashtag any-condition filtering uses the optimized object-id preselection/subquery path. | No recheck. |
| `92526e023` | 2021-03-07 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag performance branch; optimized hashtag filtering is present locally. | No recheck. |
| `946e0aab4` | 2021-03-10 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag rework branch; local hashtag filtering and migrator code include the final branch behavior. | No recheck. |
| `fbcddd812` | 2021-03-12 | Ivan Tashkinov | Merge remote-tracking branch 'remotes/origin/develop' into feature/object-hashtags-rework | implemented | Merge-only hashtag rework branch; local code has the support migrator infrastructure and final filtering. | No recheck. |
| `3edf45021` | 2021-03-12 | Ivan Tashkinov | [#3213] Background migration infrastructure refactoring. Extracted BaseMigrator and BaseMigratorState. | implemented | `Pleroma.Migrators.Support.BaseMigrator` and `BaseMigratorState` are present and used by HashtagsTableMigrator. | No recheck. |
| `cb7345660` | 2021-03-12 | Ivan Tashkinov | [#3213] Code formatting fix. | not-applicable | Code-formatting-only cleanup in migrator support state. | No code action. |
| `8194622a7` | 2021-03-15 | rinpatch | Merge branch 'feature/object-hashtags-rework' into 'develop' | implemented | Hashtag object rework already present, including normalized hashtag storage, object links, filtering helpers, followed-hashtag preservation, and the modernized cleanup worker. | |
| `92ab72dbb` | 2021-03-05 | Egor Kislitsyn | Update OpenApiSpex dependency | implemented | Superseded by newer OpenApiSpex dependency already in Unfathomably. | |
| `a2aa30949` | 2021-03-16 | Haelwenn | Merge branch 'update_open_api_spex' into 'develop' | implemented | Merge of OpenApiSpex dependency update; superseded by newer dependency already carried locally. | |
| `b1d4b2b81` | 2021-03-15 | Haelwenn (lanodan) Monnier | Add support for actor icon being a list (Bridgy) | implemented | Actor icon/avatar handling already wraps list values before selecting usable image data, preserving Bridgy compatibility. | |
| `67bde35e7` | 2021-03-19 | rinpatch | Merge branch 'bugfix/bridgy-user-icon' into 'develop' | implemented | Merge of Bridgy list-icon support already present in local actor parsing. | |
| `3bc7d1227` | 2021-02-27 | Haelwenn (lanodan) Monnier | Remove sensitive-property setting #nsfw, create HashtagPolicy | implemented | HashtagPolicy is present and owns hashtag reject, FTL-removal, and sensitive marking behavior rather than hard-coded SimplePolicy handling. | |
| `f930e83fa` | 2021-03-19 | rinpatch | Merge branch 'fix/remove_auto_nsfw' into 'develop' | implemented | Merge of HashtagPolicy extraction; behavior is already present. | |
| `e97b34f65` | 2021-03-05 | Mark Felder | Add simple way to decode fully qualified mediaproxy URLs | implemented | MediaProxy exposes decoded URL helpers for fully qualified media-proxy URLs. | |
| `eaaa20e0f` | 2021-03-05 | Mark Felder | Make tests use it | implemented | Media proxy decode helper is available to tests and runtime code; local tests have moved on to the consolidated helper behavior. | |
| `a9bc652ab` | 2021-03-19 | rinpatch | Merge branch 'mediaproxy-decode' into 'develop' | implemented | Merge of media-proxy decode helpers already present. | |
| `ef5b0510e` | 2021-03-20 | Alexander Strizhakov | updating timex | implemented | Superseded by newer Timex 3.7.x dependency already carried locally. | |
| `8f7836152` | 2021-03-20 | feld | Merge branch 'fix/timex-retired-version' into 'develop' | implemented | Merge of Timex retired-version update; superseded by newer local dependency. | |
| `8246db2a9` | 2021-03-10 | Mark Felder | Workaround for URI.merge/2 bug https://github.com/elixir-lang/elixir/issues/10771 | implemented | Rich media card rendering already uses the final absolute/relative image URL construction path before media-proxying. | |
| `029ff6538` | 2021-03-11 | Mark Felder | Leverage function pattern matching instead | implemented | Local rich-media image URL builder uses pattern-matched URI cases for absolute versus relative URLs. | |
| `b80f868c6` | 2021-03-13 | Mark Felder | Prefer naming this function build_image_url/2 | implemented | Local StatusView carries build_image_url/2 for rich-media card image normalization. | |
| `72143dd73` | 2021-03-21 | rinpatch | Merge branch 'richmedia-workaround' into 'develop' | implemented | Merge of rich-media image URL workaround already present. | |
| `d7e51206a` | 2021-03-19 | Alexander Strizhakov | respect content-type header in finger request | implemented | WebFinger parsing selects XML or JRD JSON by response content-type and returns explicit content-type errors for unsupported responses. | |
| `572363793` | 2021-03-21 | rinpatch | Merge branch 'fix/2579-finger-content-type' into 'develop' | implemented | Merge of WebFinger content-type handling already present. | |
| `d3660b24d` | 2021-03-22 | rinpatch | Copy emoji in the subject from parent post | implemented | ActivityDraft copies parent-summary custom emoji into replies so subject emoji survive reply rendering. | |
| `c09844d3d` | 2021-03-23 | Haelwenn | Merge branch 'fix/copy-emoji-summary' into 'develop' | implemented | Merge of parent-summary emoji copy behavior already present. | |
| `03843a538` | 2021-03-23 | Alexander Strizhakov | migrating config to tmp folder | implemented | Config export writes generated database config into the system temp directory and tells admins to copy it intentionally. | |
| `4cd34d019` | 2021-03-23 | Alexander Strizhakov | suggestion | implemented | Follow-up wording/flow for tmp config migration is represented in the local config export task. | |
| `ad907254f` | 2021-03-23 | Alexander Strizhakov | changelog entry | not-applicable | Upstream changelog-only commit for tmp config migration; no source behavior to backport. | |
| `caadde3b0` | 2021-03-23 | feld | Merge branch 'fix/2585-config-migration-dir' into 'develop' | implemented | Merge of tmp config migration behavior already present locally. | |
| `b6a69b5ef` | 2021-03-24 | Alex Gleason | Return token's primary key with POST /oauth/token | implemented | OAuth token rendering includes the token primary key in POST /oauth/token responses. | |
| `8b81d6222` | 2021-03-30 | Mark Felder | Upstream original followbot implementation | implemented | FollowBot MRF policy exists locally and is configurable. | |
| `fba770b3e` | 2021-03-30 | Mark Felder | Try to handle misconfiguration scenarios gracefully | implemented | FollowBot policy handles missing or invalid follower configuration without crashing. | |
| `840dc4b44` | 2021-03-30 | Mark Felder | Document :mrf_follow_bot | implemented | FollowBot policy is documented in the configuration cheatsheet. | |
| `e78738173` | 2021-03-30 | Mark Felder | Enforce that the followbot must be marked as a bot. | implemented | FollowBot requires the configured follower account to be marked as a bot. | |
| `2557e805a` | 2021-03-30 | Mark Felder | Support for configuration via AdminFE | implemented | FollowBot configuration is exposed through config descriptions for AdminFE. | |
| `2689463c7` | 2021-03-30 | feld | Apply 1 suggestion(s) to 1 file(s) | implemented | FollowBot documentation suggestions are represented in the local cheatsheet text. | |
| `3949cfdc2` | 2021-03-30 | Mark Felder | Make the followbot only dispatch follow requests once per 30 day period | implemented | FollowBot throttles repeat follow dispatches for the same remote target. | |
| `3989ec508` | 2021-03-30 | Mark Felder | Prevent duplicates from being processed | implemented | FollowBot duplicate-processing prevention is present in the local policy and tests. | |
| `a176914c7` | 2021-03-30 | Mark Felder | Better checking of previous follow request attempts | implemented | FollowBot checks previous follow attempts before dispatching new requests. | |
| `f0dcc1ca6` | 2021-03-30 | Mark Felder | Lint | implemented | FollowBot lint cleanup is reflected in the final local policy shape. | |
| `1926d0804` | 2021-03-30 | Mark Felder | Add follow_requests_outstanding_since?/3 to Pleroma.Activity | superseded | Temporary Activity helper was reverted upstream; local FollowBot uses the final policy/test behavior without carrying the reverted helper. | |
| `86182ef8e` | 2021-03-30 | Mark Felder | Change module name to FollowbotPolicy | implemented | FollowBotPolicy naming is used by the local module, docs, and configuration description. | |
| `778010ef8` | 2021-03-30 | Mark Felder | Do not try to follow local users. Their posts are already available locally on the instance. | implemented | FollowBot avoids following local users, matching the final upstream behavior. | |
| `c252ac71d` | 2021-03-30 | Mark Felder | Revert | implemented | Revert of the temporary follow-request helper is reflected locally by the final FollowBot implementation. | |
| `f73d16678` | 2021-03-30 | Mark Felder | Only need to validate a follow request is generated for now | implemented | FollowBot policy test coverage exists in the local test tree. | |
| `4796df0bc` | 2021-03-30 | Mark Felder | Remove Task.async as it is broken here and probably a premature optimization anyway | implemented | FollowBot policy does not rely on the removed Task.async path. | |
| `fef4f3772` | 2021-03-30 | Mark Felder | More tests to validate Followbot is behaving | implemented | Additional FollowBot behavior tests are present locally, including no-bot and duplicate-style cases. | |
| `7eab98d5c` | 2021-03-30 | Mark Felder | Document new FollowBot MRF | not-applicable | Upstream changelog-only FollowBot entry; source behavior is covered by the policy rows. | |
| `03f38ac4e` | 2021-03-30 | Mark Felder | Prefer FollowBot naming convention vs Followbot | implemented | Final FollowBot naming convention is used locally. | |
| `d29f6d6b6` | 2021-03-30 | Mark Felder | Add more details to the cheatsheat for FollowBot MRF | implemented | FollowBot cheatsheet details are present locally. | |
| `bfcdcd4f6` | 2021-03-30 | Mark Felder | Temp file leaked, oops | implemented | Leaked temporary FollowBot test file is not present in the local final tree. | |
| `16a7ffb1e` | 2021-03-30 | Mark Felder | Fix function calls due to module name change | implemented | FollowBot tests reference the final module name. | |
| `4c16f5d2c` | 2021-03-30 | feld | Merge branch 'upstream/mrf-followbot' into 'develop' | implemented | Merge of FollowBot MRF branch; final behavior is present locally. | |
| `863010ea6` | 2021-03-31 | Miss Pasture | date-times are always strings | superseded | OpenAPI date-time schema change was reverted upstream; local schema remains on the final reverted shape. | |
| `c368bf6dc` | 2021-03-31 | rinpatch | Merge branch 'patch-fix-open-api-spec' into 'develop' | superseded | Merge of OpenAPI date-time schema change was reverted upstream and should not be reintroduced. | |
| `af1cd28f9` | 2021-04-01 | Haelwenn (lanodan) Monnier | object_validator: Refactor most of validate/2 to a generic block | implemented | ObjectValidator uses generic validator dispatch for supported ActivityPub activity/object types. | |
| `ce9ed6c73` | 2021-04-01 | rinpatch | Merge branch 'refactor/object_validator_validate' into 'develop' | implemented | Merge of ObjectValidator validate/2 refactor; local dispatcher carries the refactored shape. | |
| `1e3db0758` | 2021-04-01 | Haelwenn | Revert "Merge branch 'patch-fix-open-api-spec' into 'develop'" | implemented | Upstream revert of the OpenAPI date-time schema change is reflected by the local final schema shape. | |
| `96fe4dd4e` | 2021-04-01 | Haelwenn | Merge branch 'revert-c368bf6d' into 'develop' | implemented | Merge of the OpenAPI revert; no local source change needed. | |
| `4ecf6ceea` | 2021-04-01 | Mark Felder | Enforce user.notification_settings is NOT NULL | implemented | Migration enforcing non-null user notification_settings is present locally. | |
| `765f0907d` | 2021-04-01 | Mark Felder | Document user login failure fix for NULL notification_settings | not-applicable | Upstream changelog-only note for notification_settings migration. | |
| `31ce8a373` | 2021-04-01 | Mark Felder | Fix CHANGELOG entry meant for next release | not-applicable | Upstream changelog cleanup only. | |
| `f8cef7041` | 2021-04-01 | feld | Merge branch 'chore/CHANGELOG' into 'develop' | not-applicable | Upstream changelog merge only. | |
| `0feafcc20` | 2021-04-09 | Mark Felder | Use URI.merge to prevent concatenating two canonical URLs when a custom instance thumbnail was uploaded via AdminFE | implemented | Instance thumbnail rendering uses URI.merge against the endpoint URL to avoid duplicated canonical URLs. | |
| `9fbcdc15b` | 2021-04-13 | Mark Felder | Validate custom instance thumbnail set via AdminAPI produces correct URL | implemented | Instance-thumbnail AdminAPI regression coverage is represented by the local URI.merge behavior and config tests. | |
| `cdd271b06` | 2021-04-13 | Mark Felder | Fix assignment / assertion | implemented | Follow-up instance-thumbnail test assertion cleanup has no separate source delta to carry. | |
| `d2a03d3c8` | 2021-04-13 | Haelwenn | Merge branch 'fix/instance-thumbnail-url' into 'develop' | implemented | Merge of instance-thumbnail URL fix; local InstanceView carries the corrected URL construction. | |
| `905efc57e` | 2021-04-13 | Mark Felder | Initial test validating the AdminAPI issue | implemented | AdminAPI config test coverage for instance-thumbnail persistence is present in the local test suite lineage. | |
| `ee53ad4d7` | 2021-04-13 | Mark Felder | Add ConcurrentLimiter to module_name?/1 and apply string_to_elixir_types/1 to search_opts keys during update_or_create/1 | implemented | ConfigDB recognizes ConcurrentLimiter modules and normalizes nested search_opts keys through string_to_elixir_types/1. | |
| `861f19285` | 2021-04-13 | Mark Felder | Document fixed ability to save ConcurrentLimiter settings in ConfigDB | not-applicable | Upstream changelog-only note for ConfigDB ConcurrentLimiter handling. | |
| `c3b8c7796` | 2021-04-13 | Mark Felder | Improve string_to_elixir_types/1 with guards | superseded | Guard experiment for string_to_elixir_types/1 was later reverted upstream; local code follows the final shape. | |
| `f95b52255` | 2021-04-14 | Mark Felder | Revert guards on string_to_elixir_types/1, remove unnecessary assignment in test | implemented | Revert of unnecessary string_to_elixir_types guards is reflected in local ConfigDB. | |
| `1bf2b645c` | 2021-04-14 | feld | Merge branch 'fix/adminapi-concurrent-limiter' into 'develop' | implemented | Merge of AdminAPI ConcurrentLimiter fix; local ConfigDB includes the needed handling. | |
| `d9fce0133` | 2021-04-14 | Sean King | Fix Mastodon interface link | not-applicable | Documentation-only Mastodon interface link fix. | |
| `0ba8efc95` | 2021-04-15 | Haelwenn | Merge branch 'fix/mastodon-interface-docs-link' into 'develop' | not-applicable | Documentation-only merge for Mastodon interface link fix. | |
| `0a7c2a32b` | 2021-04-15 | feld | Merge branch 'develop' into 'fix/notifsettings-breaking-login' | implemented | Merge conflict resolution for notification_settings branch; local final migration is present. | |
| `152cb3074` | 2021-04-15 | Haelwenn | Merge branch 'fix/notifsettings-breaking-login' into 'develop' | implemented | Merge of notification_settings login fix; local migration enforces the invariant. | |
| `6e108b860` | 2021-03-26 | Alexander Strizhakov | reading the file, instead of config keyword | implemented | Release runtime provider reads exported configuration from the configured file path. | |
| `4d046afd2` | 2021-03-27 | Alexander Strizhakov | tests for release config provider | implemented | Release runtime provider tests and fixtures for exported config are present locally. | |
| `681a42c35` | 2021-04-08 | Alexander Strizhakov | release runtime provider fix for paths | implemented | Release runtime provider path handling fix is represented in local provider tests and options. | |
| `0ababdc06` | 2021-04-16 | rinpatch | Merge branch 'fix/2593-reading-exported-config-file' into 'develop' | implemented | Merge of release runtime provider exported-config path fix; local provider carries the behavior. | |
| `3ec1dbd92` | 2021-03-25 | Alexander Strizhakov | Let pins federate | implemented | Pinned-status federation support is present, including pinned_objects, featured collections, Add/Remove validation, and AP endpoints. | |
| `17f28c050` | 2021-03-25 | Alexander Strizhakov | mastodon pins | implemented | Mastodon featured/pinned collection compatibility is present in the local ActivityPub fetch and containment path. | |
| `ff612750b` | 2021-03-25 | Alexander Strizhakov | validator renaming & add validation for target | implemented | AddRemoveValidator validates Add/Remove target and object handling for featured collections. | |
| `d1d2744ee` | 2021-03-25 | Alexander Strizhakov | featured_address valition in AddRemoveValidator | implemented | Featured-address validation is present in AddRemoveValidator and CommonAPI pin flows. | |
| `3adb43cc2` | 2021-03-25 | Alexander Strizhakov | refetch user on incoming add/remove activity | implemented | Incoming Add/Remove handling can refetch the affected user for featured-collection updates. | |
| `16c96966e` | 2021-03-25 | Alexander Strizhakov | not needed | not-applicable | Fixture cleanup only; no source behavior to backport. | |
| `8f0778166` | 2021-03-25 | Alexander Strizhakov | moving fixture into mastodon folder | not-applicable | Fixture move only; no source behavior to backport. | |
| `5ae9b0560` | 2021-03-25 | Alexander Strizhakov | separate test file for featured collection | implemented | Featured collection Add/Remove behavior is covered by local ActivityPub validator and side-effect tests lineage. | |
| `8857242c9` | 2021-03-25 | Alexander Strizhakov | removeing corresponding add activity | implemented | Pinned-post Add/Remove side effects remove the corresponding Add activity when unpinning. | |
| `2a520ba00` | 2021-03-25 | Alexander Strizhakov | expanding AddRemoveValidator | implemented | AddRemoveValidator handles expanded featured-collection validation and CommonAPI pin/unpin paths. | |
| `1885268c9` | 2021-03-25 | Alexander Strizhakov | expanding validator | implemented | Expanded AddRemoveValidator handling is present in the final local validator/transmogrifier shape. | |
| `79376b4af` | 2021-04-16 | rinpatch | Merge branch 'feature/521-pinned-post-federation' into 'develop' | implemented | Merge of pinned-post federation branch; local featured/pinned federation behavior is present. | |
| `9015df222` | 2021-04-01 | Haelwenn (lanodan) Monnier | TagValidator: New | implemented | TagValidator is present and embedded by common ActivityPub object fields. | |
| `5ae27c845` | 2021-04-01 | Haelwenn (lanodan) Monnier | pipeline_test: Fix usage of %Activity{} | implemented | Pipeline test-era Activity struct handling is represented by the current pipeline/object-validator flow. | |
| `37a7f521f` | 2021-04-01 | Haelwenn (lanodan) Monnier | Insert string-hashtags in Pipeline | implemented | Pipeline/object validation inserts and normalizes string hashtag data through the current hashtag pipeline. | |
| `7ebfe8990` | 2021-04-01 | Haelwenn (lanodan) Monnier | object_validators: Mark validate_data as private | implemented | Validator validate_data helpers are private in the current local validator modules where applicable. | |
| `ef36f7fa5` | 2021-04-05 | Haelwenn (lanodan) Monnier | Move tag fixup to object_validator | implemented | Tag fixup lives in object validation/common fields rather than being an ad-hoc pipeline concern. | |
| `15f87cf65` | 2021-04-16 | rinpatch | Merge branch 'features/ingestion-ecto-tag' into 'develop' | implemented | Merge of ingestion Ecto tag work; local hashtag/tag validator and object-hashtag storage are already present. | |
| `2b4f958b2` | 2021-04-18 | Sean King | Add opting out of Google FLoC to HTTPSecurityPlug headers | implemented | Backported in this pass: HTTPSecurityPlug now sends Permissions-Policy interest-cohort=() to opt out of FLoC-style tracking. | |
| `efed94a23` | 2021-04-19 | Mark Felder | Fix error response which was breaking tests related to pinned posts | implemented | Pinned-post error response behavior is covered by the current CommonAPI pin/unpin flow and fallback handling. | |
| `7183655a0` | 2021-04-19 | feld | Merge branch 'fix/tests' into 'develop' | implemented | Merge of pinned-post test fix; no separate source change needed beyond current pin behavior. | |
| `d1eb1913e` | 2021-04-19 | Sean King | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into feature/opt-out-of-google-floc | implemented | Merge of FLoC opt-out branch; source header was backported in this pass. | |
| `2780cdd4e` | 2021-04-19 | Sean King | Add CHANGELOG entry | not-applicable | Upstream changelog-only FLoC entry; local changelog was updated separately for Unfathomably. | |
| `8defbe431` | 2021-04-19 | feld | Merge branch 'feature/opt-out-of-google-floc' into 'develop' | implemented | Merge of FLoC opt-out branch; local HTTPSecurityPlug now carries the header. | |
| `7eded7218` | 2021-04-20 | Mark Felder | Fix incorrect shell command | not-applicable | OTP installation documentation shell-command fix only. | |
| `b050adb5e` | 2021-04-20 | feld | Merge branch 'fix/docs' into 'develop' | not-applicable | Documentation-only merge. | |
| `0effcd2cf` | 2021-04-22 | Mark Felder | Set Repo.transaction/2 timeout to infinity. Fixes pleroma.user delete_activities mix task. | implemented | ActivityPub pipeline transactions use Utils.query_timeout/0 so mix-task and pleroma_ctl executions can run with infinite timeout. | |
| `9bc69196d` | 2021-04-22 | Mark Felder | Add utility function to return infinite timeout for SQL transactions if we detect it was called from a Mix Task | implemented | Utils.query_timeout/0 exists and detects Mix task callers. | |
| `9f711ddcf` | 2021-04-22 | Mark Felder | Try to set query timeout intelligently | implemented | Pipeline transaction timeout is selected through Utils.query_timeout/0 rather than a hard-coded infinite timeout. | |
| `99fd9c5e3` | 2021-04-22 | Mark Felder | OTP releases executing commands via pleroma_ctl show the parent of the process is :erl_eval | implemented | Utils.query_timeout/0 treats :erl_eval parent processes from OTP release task execution as infinite-timeout callers. | |
| `959dc6e6f` | 2021-04-22 | Mark Felder | Cleanup and ensure we obey custom Repo timeout | implemented | Final query-timeout cleanup is present locally and still honors the configured default timeout outside task callers. | |
| `d7a71a275` | 2021-04-22 | Mark Felder | Fixed pleroma.user delete_activities mix task. | not-applicable | Upstream changelog-only note for delete_activities timeout fix. | |
| `d9e782c18` | 2021-04-23 | Haelwenn | Merge branch 'fix/delete_activities_timeout' into 'develop' | implemented | Merge of delete_activities timeout fix; local pipeline timeout behavior is present. | |
| `b9a99ac0d` | 2021-04-27 | Alex Gleason | Cache gitlab-ci based on mix.lock | not-applicable | GitLab CI cache-key change only; no runtime source behavior. | |
| `115673bce` | 2021-04-28 | Haelwenn | Merge branch 'gitlab-ci-mix-lock' into 'develop' | not-applicable | GitLab CI cache-key merge only. | |
| `e7ac15905` | 2021-04-29 | Alex Gleason | Merge remote-tracking branch 'upstream/develop' into oauth-token-id | implemented | Merge-update row for OAuth token id branch; actual token id behavior is already marked implemented. | |
| `8c1d6e883` | 2021-04-29 | Alex Gleason | CHANGELOG: Return OAuth token `id` | not-applicable | Upstream changelog-only OAuth token id entry. | |
| `b5ae82689` | 2021-04-29 | Alex Gleason | CI: Purge pleroma build directory between runs | not-applicable | GitLab CI cleanup-only change. | |
| `2fe3bd817` | 2021-04-29 | feld | Merge branch 'maybe-fix-ci' into 'develop' | not-applicable | GitLab CI cleanup merge only. | |
| `6bc8ab225` | 2021-04-29 | Alex Gleason | Merge remote-tracking branch 'upstream/develop' into oauth-token-id | implemented | Merge-update row for OAuth token id branch; final token rendering is present locally. | |
| `377f84f36` | 2021-04-29 | feld | Merge branch 'oauth-token-id' into 'develop' | implemented | Merge of OAuth token id branch; local OAuth token view returns id. | |
| `52fc59f12` | 2021-04-30 | Alex Gleason | Merge remote-tracking branch 'upstream/develop' into earmark | implemented | Merge-update row for markdown dependency work; superseded by Unfathomably MDEx markdown stack. | |
| `dca87c5e7` | 2021-05-01 | Alex Gleason | CHANGELOG: markdown | not-applicable | Upstream changelog-only markdown entry. | |
| `d5263bfcf` | 2021-05-04 | feld | Merge branch 'earmark' into 'develop' | implemented | Merge of old Earmark markdown branch; superseded by the current MDEx-based markdown rendering stack. | |
| `c80b1aaf5` | 2021-05-03 | Alex Gleason | Don't crash when email settings are invalid Fixes: https://git.pleroma.social/pleroma/pleroma/-/issues/2606 Fixes: https://gitlab.com/soapbox-pub/soapbox/-/issues/4 | implemented | ApplicationRequirements warns and continues when welcome or confirmation email features are enabled without a working mailer. | |
| `c186b059a` | 2021-05-03 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into dont-crash-email-settings | implemented | Merge-update row for invalid-email-settings resilience; local ApplicationRequirements behavior is present. | |
| `90770e084` | 2021-05-03 | Alex Gleason | CHANGELOG: don't crash so hard when email settings are invalid | not-applicable | Upstream changelog-only invalid-email-settings entry. | |
| `745375bdc` | 2021-05-04 | feld | Merge branch 'dont-crash-email-settings' into 'develop' | implemented | Merge of invalid-email-settings resilience; local startup checks carry the warning-only behavior. | |
| `32ae8f490` | 2021-05-16 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into optional-config | implemented | Merge-update row for optional prod.secret.exs config work; optional config loading is already present locally. | |
| `44be498fe` | 2021-05-17 | lain | Merge branch 'optional-config' into 'develop' | implemented | Merge of optional config branch; local prod config already supports optional prod.secret.exs loading. | |
| `ab9eabdf2` | 2021-05-12 | Alex Gleason | Add SetMeta filter to store uploaded image sizes | implemented | Upload metadata extraction stores media width, height, and blurhash through the current AnalyzeMetadata/SetMeta path. | |
| `4c060ae73` | 2021-05-12 | Alex Gleason | Ingest remote attachment width/height | implemented | Remote attachment ingestion preserves width and height in AttachmentValidator URL metadata. | |
| `02b943649` | 2021-05-12 | Alex Gleason | Don't render media `meta` if nil | implemented | StatusView omits attachment meta when metadata is unavailable. | |
| `6f0b42656` | 2021-05-12 | Alex Gleason | Federate attachments as Links instead of Documents | implemented | Attachment federation uses Link-style URL entries with media metadata rather than losing dimensions. | |
| `543e9402d` | 2021-05-14 | Alex Gleason | Support blurhash | implemented | Blurhash support is present in upload metadata extraction, ActivityPub attachment validation, and Mastodon attachment rendering. | |
| `ff0251105` | 2021-05-12 | Alex Gleason | Merge remote-tracking branch 'upstream/develop' into attachment-meta | implemented | Merge-update row for attachment metadata; local validators and status rendering carry the final behavior. | |
| `5a57b025c` | 2021-05-12 | Alex Gleason | Changelog: attachment meta | not-applicable | Upstream changelog-only attachment metadata entry. | |
| `bcf6efce1` | 2021-05-14 | Alex Gleason | Merge remote-tracking branch 'upstream/attachment-meta' into blurhash | implemented | Merge-update row for blurhash branch; local upload and attachment rendering support blurhash. | |
| `9b6b5ac19` | 2021-05-18 | Mark Felder | Rename upload filter to AnalyzeMetadata | implemented | Upload metadata filter is named AnalyzeMetadata locally and SetMeta-era behavior is superseded by the current analyzer. | |
| `4ab3ef07d` | 2021-05-18 | Mark Felder | Check AnalyzeMetadata filter's required commands | implemented | ApplicationRequirements checks AnalyzeMetadata required command availability through the upload filter command checks. | |
| `c64cbee26` | 2021-05-18 | Mark Felder | Fixed checking for Upload Filter required commands | implemented | Upload filter required-command checking includes AnalyzeMetadata/ffprobe and other enabled filters. | |
| `0db436789` | 2021-05-18 | feld | Merge branch 'blurhash' into 'develop' | implemented | Merge of blurhash/AnalyzeMetadata branch; local upload metadata analyzer is present. | |
| `2d7f6ce6f` | 2021-05-18 | Mark Felder | Clarify AttachmentMetadata changes | not-applicable | Upstream changelog clarification only for attachment metadata. | |
| `8e9f032f2` | 2021-05-18 | feld | Merge branch 'chore/changelog' into 'develop' | not-applicable | Upstream changelog merge only. | |
| `fe40f6f29` | 2021-05-20 | Mark Felder | Switch from the deprecated "use Mix.config" to "import Config" | implemented | Config files use import Config rather than deprecated use Mix.Config. | |
| `5d0ac015d` | 2021-05-22 | Haelwenn | Merge branch 'mix_config_deprecation' into 'develop' | implemented | Merge of Mix.Config deprecation cleanup; local config files already use import Config. | |
| `05d678c07` | 2021-05-20 | Mark Felder | Expose user email address to user/owner; not publicly. | implemented | Account rendering exposes the email address only to the account owner through pleroma.email. | |
| `f34e22bba` | 2021-05-26 | Haelwenn | Merge branch 'feat/expose_email_to_self' into 'develop' | implemented | Merge of self-only email exposure; local AccountView carries owner-only email rendering. | |
| `469485376` | 2021-05-27 | Mark Felder | Provide totalItems field for featured collections | implemented | Featured collections include totalItems in ActivityPub UserView rendering. | |
| `cd4352a86` | 2021-05-27 | Mark Felder | Missing entry for pinned posts federation from MR !3312 | not-applicable | Upstream changelog-only missing pinned-post federation entry. | |
| `a01093c50` | 2021-05-27 | Haelwenn | Merge branch 'featured-totalItems' into 'develop' | implemented | Merge of featured totalItems branch; local featured collection rendering includes totalItems. | |
| `bf2ee12fd` | 2021-05-28 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-router-mediaproxy | implemented | Cycles router media-proxy merge-update row; superseded by current router organization. | |
| `9f386df83` | 2021-05-28 | feld | Merge branch 'cycles-router-mediaproxy' into 'develop' | implemented | Merge of cycles router media-proxy work; no distinct source delta missing in current router. | |
| `e885b49e3` | 2021-05-28 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-router | implemented | Cycles router merge-update row; superseded by current router organization. | |
| `7ad87571b` | 2021-05-28 | feld | Merge branch 'cycles-router' into 'develop' | implemented | Merge of cycles router work; current router has the later organization. | |
| `046179437` | 2021-05-19 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into plug-runtime-dev | implemented | Plug runtime dev merge-update row; superseded by current dev/test config shape. | |
| `a833a2d76` | 2021-05-28 | feld | Merge branch 'plug-runtime-dev' into 'develop' | implemented | Merge of plug runtime dev config changes; local dev/test configs use current Plug runtime assumptions. | |
| `ad7d4ff8b` | 2021-05-19 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into alias-router-helpers | implemented | Alias router helper merge-update row; superseded by current web/router helper organization. | |
| `edcdd15e0` | 2021-05-28 | feld | Merge branch 'alias-router-helpers' into 'develop' | implemented | Merge of alias router helper cleanup; current web helpers carry the later shape. | |
| `230ad82da` | 2021-05-16 | Alex Gleason | gitignore `config/runtime.exs` | implemented | config/runtime.exs is ignored locally. | |
| `7ac4da8dd` | 2021-05-16 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into gitignore-runtime-exs | implemented | Merge-update row for runtime.exs gitignore; local .gitignore includes the entry. | |
| `c44dd05f6` | 2021-05-28 | feld | Merge branch 'gitignore-runtime-exs' into 'develop' | implemented | Merge of runtime.exs gitignore branch; local .gitignore carries the rule. | |
| `3d742c3c1` | 2021-04-30 | Alex Gleason | SimplePolicy: filter nested objects | implemented | SimplePolicy recursively filters nested embedded objects to avoid Announce/object policy leaks. | |
| `c16c7fdb8` | 2021-04-30 | Alex Gleason | SimplePolicy: filter string Objects | implemented | SimplePolicy also filters string object IDs so blocked object hosts are rejected. | |
| `926a233cc` | 2021-04-30 | Alex Gleason | Merge remote-tracking branch 'upstream/develop' into simplepolicy-announce-leak | implemented | Merge-update row for SimplePolicy announce leak fix; local policy and tests include nested and URI object checks. | |
| `20878c7f9` | 2021-04-30 | Alex Gleason | CHANGELOG: SimplePolicy embedded objects are now checked | not-applicable | Upstream changelog-only SimplePolicy embedded-object entry. | |
| `cea44b6b3` | 2021-05-07 | Alex Gleason | Merge remote-tracking branch 'upstream/develop' into simplepolicy-announce-leak | implemented | Merge-update row for SimplePolicy announce leak fix; local behavior is present. | |
| `359ded086` | 2021-05-28 | feld | Merge branch 'simplepolicy-announce-leak' into 'develop' | implemented | Merge of SimplePolicy announce leak fix; local SimplePolicy filters embedded objects and string object IDs. | |
| `39127f15e` | 2021-05-28 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-router-api-routes | implemented | Cycles router API-routes merge-update row; superseded by current router/API route organization. | |
| `8871ca5aa` | 2021-05-28 | feld | Merge branch 'cycles-router-api-routes' into 'develop' | implemented | Merge of cycles router API-routes work; current Pleroma.Web route helpers carry the later organization. | |
| `0de6716f0` | 2021-05-29 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-pipeline | implemented | Cycles pipeline merge-update row; superseded by current ActivityPub pipeline module organization. | |
| `018dc12b4` | 2021-05-29 | feld | Merge branch 'cycles-pipeline' into 'develop' | implemented | Merge of cycles pipeline work; current pipeline carries the later organization. | |
| `cc9e456c0` | 2021-05-29 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-plugs | implemented | Cycles plugs merge-update row; superseded by current plug/module organization. | |
| `b2f5f4875` | 2021-05-29 | feld | Merge branch 'cycles-config' into 'develop' | implemented | Merge of cycles config work; current config modules carry the later organization. | |
| `e2ba852bf` | 2021-05-29 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-gun | implemented | Cycles Gun merge-update row; superseded by current HTTP/Gun pool organization. | |
| `317fe240a` | 2021-05-29 | feld | Merge branch 'cycles-gun' into 'develop' | implemented | Merge of cycles Gun work; current HTTP/Gun modules carry later cleanup. | |
| `1a69f5922` | 2021-05-29 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-html | implemented | Cycles HTML merge-update row; superseded by current HTML/status rendering organization. | |
| `b5f3a5c97` | 2021-05-29 | feld | Merge branch 'cycles-html' into 'develop' | implemented | Merge of cycles HTML work; current rendering modules carry later cleanup. | |
| `7c96c82b5` | 2021-05-29 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-views | implemented | Cycles views merge-update row; superseded by current Mastodon view/controller organization. | |
| `5d40ffe42` | 2021-05-29 | feld | Merge branch 'cycles-views' into 'develop' | implemented | Merge of cycles views work; current view/controller modules carry later cleanup. | |
| `0204ceff7` | 2021-05-30 | shibao | Add ffmpeg | implemented | Dockerfile and setup scripts include ffmpeg/ffprobe support for upload metadata analysis. | |
| `4a58cb469` | 2021-05-30 | Haelwenn | Merge branch 'ffmpeg' into 'develop' | implemented | Merge of ffmpeg Docker dependency; local Docker/build scripts include ffmpeg. | |
| `0107ec63a` | 2021-05-30 | Snow | Added translation using Weblate (Chinese (Traditional)) | implemented | Chinese Traditional gettext catalog is present locally through later translation imports. | |
| `b3209c31b` | 2021-05-30 | Snow | Translated using Weblate (Chinese (Traditional)) | implemented | Chinese Traditional gettext updates are present through later translation catalog lineage. | |
| `2fde1f254` | 2021-05-30 | Snow | Translated using Weblate (Chinese (Traditional)) | implemented | Chinese Traditional gettext updates are present through later translation catalog lineage. | |
| `e53984e44` | 2021-05-31 | Haelwenn | Merge branch 'weblate-pleroma-pleroma' into 'develop' | implemented | Merge of Weblate translation updates; local gettext catalogs carry the later translation set. | |
| `03232a822` | 2021-05-31 | Haelwenn (lanodan) Monnier | Changing references of freenode to libera.chat | not-applicable | Documentation-only migration from freenode references to libera.chat. | |
| `a0ba44904` | 2021-05-31 | Haelwenn | Merge branch 'docs/goto-libera' into 'develop' | not-applicable | Documentation-only libera.chat merge. | |
| `e56779dd8` | 2021-04-05 | Haelwenn (lanodan) Monnier | Transmogrifier: Simplify fix_explicit_addressing and fix_implicit_addressing | implemented | Transmogrifier addressing simplification is represented by the current explicit/implicit addressing helpers and CommonFixes flow. | |
| `e2a3365b5` | 2021-04-05 | Haelwenn (lanodan) Monnier | ObjectValidator.CommonFixes: Introduce fix_objects_defaults and fix_activity_defaults | implemented | CommonFixes carries object and activity default/addressing normalization, including recipient casting and context repair. | |
| `c94493267` | 2021-04-05 | Haelwenn (lanodan) Monnier | Pipeline Ingestion: Note | implemented | Pipeline Note ingestion is present through generic Create handling, Article/Note validators, and side-effect processing. | |
| `641184fc7` | 2021-04-05 | Haelwenn (lanodan) Monnier | recipients fixes/hardening for CreateGenericValidator | implemented | CreateGenericValidator recipient hardening is present, including bto/bcc/audience recipient matching and filtered follower collections. | |
| `96212b2e3` | 2021-04-05 | Haelwenn (lanodan) Monnier | Fix addressing | implemented | Addressing fix is present through cast_and_filter_recipients/4 and follower-collection filtering. | |
| `d1205406d` | 2021-04-05 | Haelwenn (lanodan) Monnier | ActivityPubControllerTest: Apply same addr changes to object | implemented | ActivityPub controller addressing behavior is represented by the current utility/object recipient normalization. | |
| `b0c778fde` | 2021-04-05 | Haelwenn (lanodan) Monnier | NoteHandlingTest: remove fix_explicit_addressing-related test | not-applicable | Upstream test removal only after addressing refactor. | |
| `461123110` | 2021-04-05 | Haelwenn (lanodan) Monnier | Object.Fetcher: Fix getting transmogrifier reject reason | implemented | Object fetcher preserves transmogrifier reject reasons instead of flattening them away. | |
| `6c9f6e62c` | 2021-04-05 | Haelwenn (lanodan) Monnier | transmogrifier: Fixing votes from Note to Answer | implemented | Incoming poll votes are normalized to Answer objects through AnswerValidator and Transmogrifier handling. | |
| `0b88accae` | 2021-04-05 | Haelwenn (lanodan) Monnier | fetcher_test: Fix missing mock function | not-applicable | Fetcher test mock maintenance only. | |
| `53193b84b` | 2021-04-05 | Haelwenn (lanodan) Monnier | utils: Fix maybe_splice_recipient when "object" isnÃ¢â‚¬â„¢t a map | implemented | maybe_splice_recipient uses Maps.safe_put_in so non-map embedded object values do not crash recipient repair. | |
| `6d6bef64b` | 2021-04-05 | Haelwenn (lanodan) Monnier | fetcher_test: Remove assert on fake Create having an ap_id | not-applicable | Fetcher test assertion cleanup only. | |
| `5ef4659b3` | 2021-04-05 | Haelwenn (lanodan) Monnier | test/pleroma/web/common_api_test.exs: Strip : around emoji key-name | not-applicable | CommonAPI emoji-key test cleanup only. | |
| `c4b425837` | 2021-06-01 | Haelwenn | Merge branch 'features/validators-note' into 'develop' | implemented | Merge of validators-note work; local validators include the final addressing, recipient, Note/Page, and Answer handling. | |
| `51a9f97e8` | 2021-05-31 | Alex Gleason | Deprecate Pleroma.Web.base_url/0 Use Pleroma.Web.Endpoint.url/0 directly instead. Reduces compiler cycles. | implemented | Pleroma.Web.base_url/0 usage has been replaced by Pleroma.Web.Endpoint.url/0 throughout the local source. | |
| `f2134e605` | 2021-05-31 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-base-url | implemented | Merge-update row for base_url cycle cleanup; local source uses Endpoint.url/0 directly. | |
| `0ddf492c5` | 2021-06-01 | feld | Merge branch 'cycles-base-url' into 'develop' | implemented | Merge of base_url cycle cleanup; local source carries the Endpoint.url/0 shape. | |
| `721c96684` | 2021-05-30 | Alex Gleason | FrontendStatic: make Router a runtime dep Speeds up recompilation by removing compile-time cycles | implemented | FrontendStatic uses runtime route discovery through Pleroma.Web.Router.get_api_routes/0 rather than compile-time route helper expansion. | |
| `595bca24a` | 2021-05-30 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-frontend-static | implemented | Merge-update row for FrontendStatic cycle cleanup; local plug carries the runtime route discovery shape. | |
| `75b94a2f3` | 2021-06-01 | feld | Merge branch 'cycles-frontend-static' into 'develop' | implemented | Merge of FrontendStatic cycle cleanup; local plug carries the behavior. | |
| `c435de426` | 2021-06-01 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-constants | implemented | Constants cycle cleanup is superseded by the current builder, validator, and CommonAPI utility organization. | |
| `ee52fc840` | 2021-06-01 | feld | Merge branch 'cycles-constants' into 'develop' | implemented | Merge of constants cycle cleanup; current source carries later module organization. | |
| `f6d2bd738` | 2021-06-01 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-uploader | implemented | Uploader cycle cleanup is superseded by the current uploader behaviour and upload module organization. | |
| `dea035dc4` | 2021-06-01 | feld | Merge branch 'cycles-uploader' into 'develop' | implemented | Merge of uploader cycle cleanup; current uploader modules carry later organization. | |
| `a744c47e9` | 2021-06-01 | Alex Gleason | Remove deps from Streaming/Persisting behaviors Speeds up recompilation by limiting compile-time deps | implemented | Streaming and Persisting behaviours contain only callbacks and do not pull in concrete dependencies. | |
| `708210b99` | 2021-06-01 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-streaming | implemented | Merge-update row for streaming/persisting behaviour dependency cleanup; local behaviours are dependency-light. | |
| `3fe6ada6f` | 2021-06-01 | feld | Merge branch 'cycles-streaming' into 'develop' | implemented | Merge of streaming/persisting behaviour dependency cleanup; local behaviour modules carry the final shape. | |
| `028017711` | 2021-06-01 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-email | implemented | Email cycle cleanup is superseded by current mailer/email module organization. | |
| `e8de1005f` | 2021-06-02 | feld | Merge branch 'cycles-email' into 'develop' | implemented | Merge of email cycle cleanup; current source carries later organization. | |
| `69aed310d` | 2021-05-29 | Snow | Adding description | not-applicable | Relay configuration description wording only. | |
| `297feb73f` | 2021-06-02 | Mark Felder | Formatting | not-applicable | Relay configuration description formatting only. | |
| `679d4c23e` | 2021-06-02 | Mark Felder | Update wording for relays in docs and config description | not-applicable | Relay documentation/config-description wording only; no runtime behavior to backport. | |
| `275af2930` | 2021-06-02 | feld | Merge branch 'Snow-develop-patch-01683' into 'develop' | not-applicable | Documentation/config-description wording merge only. | |
| `e06466a53` | 2021-06-02 | Mark Felder | Skip build, test, analysis/lint when we don't make code changes | not-applicable | GitLab CI skip rules only. | |
| `9f391da73` | 2021-06-02 | Mark Felder | Don't generate new specs unless they've changed. | not-applicable | GitLab CI spec-generation optimization only. | |
| `194a41611` | 2021-06-02 | rinpatch | Merge branch 'chore/cicd_skip_nonsense' into 'develop' | not-applicable | GitLab CI optimization merge only. | |
| `ff00b354f` | 2021-06-01 | Mark Felder | Rename the non-federating Chat feature to Shout | implemented | Backported in this pass: legacy non-federating Chat channel support is restored as ShoutChannel while keeping the chat:public topic for compatibility. | |
| `68aa56b9e` | 2021-06-01 | Mark Felder | Just call it shout | implemented | Shout configuration is now represented under :shout in local config. | |
| `36fe8950f` | 2021-06-01 | Mark Felder | Update PleromaFE settings for the old chat box | implemented | Frontend configuration keeps disableChat for PleromaFE compatibility while backend Shout settings live under :shout. | |
| `a3cff5965` | 2021-06-01 | Mark Felder | Ensure we actually start ShoutChannel | implemented | Application supervisor now starts ShoutChannel state when :shout is enabled. | |
| `4a181982c` | 2021-06-01 | Mark Felder | More confusingly named legacy chat code renamed to shout | implemented | Legacy chat/shout naming is represented by Pleroma.Web.ShoutChannel and the chat:public socket topic. | |
| `d6432a65d` | 2021-06-01 | Mark Felder | Move shout configuration from :instance, update docs and changelog | implemented | Shout configuration is documented in config descriptions and exposed separately from :instance settings; default remains disabled in Unfathomably for safer production behavior. | |
| `8ff2d8d17` | 2021-06-01 | Mark Felder | Update description file for new shout config setting location | implemented | Description metadata for :shout is present locally. | |
| `01f796f8b` | 2021-06-01 | Mark Felder | Add a test for the migration | not-applicable | Migration test for old instance chat config rename; local source carries the migration and this pass restored the runtime module. | |
| `e0bb65577` | 2021-06-01 | Roman Chvanikov | Add RenameInstanceChat migration | implemented | RenameInstanceChat migration is present locally. | |
| `d7dfa6d27` | 2021-06-01 | Roman Chvanikov | Update test for RenameInstanceChat migration | not-applicable | Migration test cleanup only. | |
| `9ce2c017c` | 2021-06-01 | Mark Felder | We want clear_config/2 in all tests now | not-applicable | Test helper cleanup only. | |
| `d9513b11d` | 2021-06-01 | Mark Felder | Forgot to move migration test when rebasing | not-applicable | Migration test move only. | |
| `48a0ea2fc` | 2021-06-01 | Mark Felder | Wire up join requests to the old "chat:public" channel into the new "shout:public" channel | implemented | ShoutChannel joins the legacy chat:public topic for client compatibility. | |
| `2743c6669` | 2021-06-01 | Mark Felder | Add "chat" back as a feature for backwards compat. | implemented | Instance feature metadata advertises chat when :shout is enabled. | |
| `0be7eada9` | 2021-06-01 | Mark Felder | Keep original Shoutbox channel name as chat:public There is no sane / high level workaround for merging users who join shout:public and chat:public. | implemented | Socket keeps the original chat:* channel namespace and routes it to ShoutChannel. | |
| `dcf84ac12` | 2021-06-01 | Mark Felder | disableChat / disableShout didn't actually do anything for PleromaFE | implemented | Shout settings are now configurable through config descriptions; legacy disableChat remains frontend config only. | |
| `a5dce42c8` | 2021-06-03 | Haelwenn | Merge branch 'chore/rename-chat' into 'develop' | implemented | Merge of chat-to-shout branch; local runtime, config, feature metadata, and compatibility topic are present. | |
| `59af07f14` | 2021-06-03 | Haelwenn (lanodan) Monnier | Update all dependencies | superseded | Old dependency update is superseded by the current modern dependency set. | |
| `166455c88` | 2021-06-03 | Haelwenn (lanodan) Monnier | mix: Switch hackney & gun to releases | superseded | Gun and Hackney are on much newer release lines locally. | |
| `168687eef` | 2021-06-03 | Haelwenn (lanodan) Monnier | media_proxy: switch from :crypto.hmac to :crypto.mac | implemented | MediaProxy uses :crypto.mac/4 rather than deprecated :crypto.hmac. | |
| `276806338` | 2021-06-03 | Haelwenn (lanodan) Monnier | mix: Update dependencies | superseded | Old dependency update is superseded by the current modern dependency set. | |
| `ab32ea44f` | 2021-06-03 | Haelwenn (lanodan) Monnier | mix.exs: Apply OTP24 fixes to web_push_encryption | implemented | web_push_encryption and WebPush handling are already on the OTP24-compatible path. | |
| `7c5e007b9` | 2021-06-03 | Haelwenn (lanodan) Monnier | mix: Update pot to ~> 1.0 | implemented | pot dependency is already on the 1.0 series locally. | |
| `5c3a0dd26` | 2021-06-03 | Haelwenn (lanodan) Monnier | factory: Fix article_factory | not-applicable | Factory test cleanup only. | |
| `24d66b60a` | 2021-06-03 | Haelwenn (lanodan) Monnier | request_builder_test: mode :read got removed | not-applicable | RequestBuilder test cleanup for removed :read mode only. | |
| `11844084d` | 2021-06-03 | Haelwenn (lanodan) Monnier | MIME.valid?(type) Ã¢â€ â€™ is_bitstring(type) && MIME.extensions(type) != [] | implemented | Attachment and transmogrifier MIME handling no longer relies on MIME.valid?/1; current validation uses the MIME Ecto type and explicit media-type checks. | |
| `922f4e3fb` | 2021-06-04 | feld | Merge branch 'bugfix/erlang-24' into 'develop' | implemented | Merge of Erlang/OTP 24 MIME compatibility; local MIME handling is compatible. | |
| `f58928cf1` | 2021-06-04 | Mark Felder | Add missing deprecation warning left out of !2842 | implemented | Backported in this pass: deprecation warning for legacy :chat / :instance chat_limit shoutbox configuration. | |
| `a07310888` | 2021-06-04 | feld | Merge branch 'fix/missing-deprecation' into 'develop' | implemented | Merge of missing deprecation warning; local warning is now present. | |
| `7eecc3b61` | 2021-03-15 | Haelwenn (lanodan) Monnier | OpenAPI: MastodonAPI Timeline Controller | implemented | Mastodon timeline OpenAPI operation module and route metadata are present locally. | |
| `3123ecdd6` | 2021-03-15 | Haelwenn (lanodan) Monnier | OpenAPI: MastodonAPI Media Controller | implemented | Mastodon media OpenAPI operation module is present locally. | |
| `e47f83cfc` | 2021-03-15 | Haelwenn (lanodan) Monnier | OpenAPI: MastodonAPI Conversation Controller | implemented | Conversation controller OpenAPI/test coverage is represented in the current Mastodon API operation/test set. | |
| `3a8404820` | 2021-03-15 | Haelwenn (lanodan) Monnier | Verify MastoFE Controller put_settings response | implemented | MastoFE put_settings response coverage is represented in the current controller behavior. | |
| `0c7c6463d` | 2021-03-15 | Haelwenn (lanodan) Monnier | OpenAPI: MastodonAPI Account Controller, excluding OAuth | implemented | Mastodon account controller OpenAPI/test coverage is represented in the current operation/test set. | |
| `ef5de5eb3` | 2021-03-15 | Haelwenn (lanodan) Monnier | OpenAPI: MastodonAPI Status Controller | implemented | Mastodon status controller OpenAPI/test coverage is represented in the current operation/test set. | |
| `e4743847a` | 2021-03-15 | Haelwenn (lanodan) Monnier | OpenAPI: PleromaAPI UserImport Controller | implemented | PleromaAPI user import OpenAPI operation module is present locally. | |
| `a22c53810` | 2021-03-15 | Haelwenn (lanodan) Monnier | Remove deprecated /api/qvitter/statuses/notifications/read | implemented | Deprecated /api/qvitter/statuses/notifications/read route is absent locally. | |
| `65cd9cb63` | 2021-03-15 | Haelwenn (lanodan) Monnier | TwitterAPI: Remove unused read notification function | implemented | Unused TwitterAPI read-notification helper is absent from the local UtilController. | |
| `55bdfb075` | 2021-03-15 | Haelwenn (lanodan) Monnier | OpenAPI: TwitterAPI Util Controller | implemented | TwitterAPI util OpenAPI operation module is present locally. | |
| `c6dcd863e` | 2021-04-16 | rinpatch | Apply rinpatch's suggestion(s) to 1 file(s) | implemented | TwitterAPI util OpenAPI suggestion cleanup is represented in the local operation module. | |
| `30b1d5093` | 2021-04-20 | Haelwenn | Apply lanodan's suggestion(s) to 1 file(s) | implemented | TwitterAPI util OpenAPI suggestion cleanup is represented in the local operation module. | |
| `e104829c2` | 2021-04-20 | Haelwenn | Apply lanodan's suggestion(s) to 1 file(s) | implemented | TwitterAPI util OpenAPI suggestion cleanup is represented in the local operation module. | |
| `42185d875` | 2021-04-20 | Haelwenn | Apply lanodan's suggestion(s) to 1 file(s) | implemented | TwitterAPI util OpenAPI suggestion cleanup is represented in the local operation module. | |
| `f9bedf559` | 2021-04-20 | Haelwenn | Apply lanodan's suggestion(s) to 1 file(s) | implemented | TwitterAPI util OpenAPI suggestion cleanup is represented in the local operation module. | |
| `0c56f9de0` | 2021-06-04 | Haelwenn | Merge branch 'tests/openapi-everywhere' into 'develop' | implemented | Merge of OpenAPI coverage expansion; local OpenAPI modules for these controllers are present. | |
| `d5daf59f8` | 2021-06-04 | Mark Felder | Fix warning for misuse of clear_config/2 | not-applicable | Test helper warning cleanup only. | |
| `5b9e13fc0` | 2021-06-04 | feld | Merge branch 'fix/clear_config_warning' into 'develop' | not-applicable | Test helper warning cleanup merge only. | |
| `eb150e7d8` | 2021-06-04 | Mark Felder | Document OTP 24 support so we remember to add it to the official release notes / announcement | implemented | OTP 24 support is already documented in the local changelog and dependency/runtime choices. | |
| `94687e239` | 2021-06-04 | feld | Merge branch 'chore/otp24-changelog' into 'develop' | implemented | Merge of OTP 24 changelog note; local changelog already carries OTP 24 support. | |
| `3be08e7c2` | 2021-06-04 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into cycles-reverse-proxy | implemented | Reverse-proxy cycle merge-update row; superseded by current reverse-proxy/media-proxy module organization. | |
| `96e85ea68` | 2021-06-07 | feld | Merge branch 'cycles-reverse-proxy' into 'develop' | implemented | Merge of reverse-proxy cycle cleanup; local source carries later organization. | |
| `879c2db0b` | 2021-06-07 | Alex Gleason | Docs: /api/v1/pleroma/notification_settings --> /api/pleroma/notification_settings | implemented | Notification-settings docs use /api/pleroma/notification_settings; stale related API-differences reference was fixed in this pass. | |
| `ca1eac01d` | 2021-06-07 | feld | Merge branch 'notification-settings-docs-fix' into 'develop' | implemented | Merge of notification-settings docs fix; local docs now point at the correct path. | |
| `7d350b73f` | 2021-06-04 | Haelwenn (lanodan) Monnier | web endpoint: Use Config.get directly instead of a tuple | implemented | Endpoint Plug.Parsers configuration reads upload limits through Config.get directly. | |
| `64bc0c69e` | 2021-06-07 | feld | Merge branch 'fix/plug_parser_multipart' into 'develop' | implemented | Merge of multipart parser config fix; local endpoint parser configuration uses Config.get directly. | |
| `fe4c4a717` | 2021-06-07 | Alex Gleason | MRF: create MRF.Policy behaviour separate from MRF module Speeds up recompilation by reducing compile-time deps | implemented | MRF.Policy behaviour exists separately and local MRF modules implement that behaviour. | |
| `6fcfa33e4` | 2021-06-07 | Alex Gleason | Fix MRF.config_descriptions/0 | implemented | MRF.config_descriptions/0 uses behaviour implementation discovery for MRF.Policy modules. | |
| `676c3c96d` | 2021-06-07 | feld | Merge branch 'cycles-mrf-policy' into 'develop' | implemented | Merge of MRF.Policy cycle cleanup; local MRF behaviour split is present. | |
| `22b2451ed` | 2021-05-08 | faried nawaz | migration: add on_delete: :delete_all to hashtags object_id fk | implemented | HashtagsObjects cascade migration is present and sets object_id foreign key on_delete: :delete_all. | |
| `a0c9a2b4c` | 2021-05-08 | faried nawaz | mix prune_objects: remove unused hashtags after pruning remote objects | implemented | prune_objects removes unused hashtags after object pruning while preserving followed hashtags. | |
| `5be9d1398` | 2021-05-08 | faried nawaz | a better query to delete from hashtags | implemented | Hashtag pruning uses the improved query shape and accounts for hashtags_objects/user_follows_hashtag state. | |
| `bc51dea42` | 2021-06-07 | feld | Update lib/mix/tasks/pleroma/database.ex | implemented | Follow-up prune-hashtags database task cleanup is represented in the local prune_objects logic. | |
| `c31338abe` | 2021-06-07 | feld | Update CHANGELOG.md | not-applicable | Upstream changelog-only prune-hashtags entry. | |
| `4ca380490` | 2021-06-07 | feld | Update CHANGELOG.md | not-applicable | Upstream changelog-only prune-hashtags entry. | |
| `84f42b92f` | 2021-06-07 | feld | Merge branch 'develop' into 'fix/prune-hashtags' | implemented | Merge-update row for prune-hashtags branch; local pruning behavior is present. | |
| `10abbf13b` | 2021-06-07 | feld | Update CHANGELOG.md | not-applicable | Upstream changelog-only prune-hashtags entry. | |
| `9a357d63f` | 2021-06-07 | feld | Update CHANGELOG.md | not-applicable | Upstream changelog-only prune-hashtags entry. | |
| `b553bfd74` | 2021-06-07 | feld | Merge branch 'fix/prune-hashtags' into 'develop' | implemented | Merge of prune-hashtags branch; local cascade migration and prune cleanup are present. | |
| `d87dfcb5f` | 2021-06-07 | Alex Gleason | Put custom guards in Web.Utils.Guards Speeds up recompilation by removing a compile-time cycle on AdminAPI.Search | implemented | Custom guards live in Pleroma.Web.Utils.Guards and are imported by current modules as needed. | |
| `371463ef0` | 2021-06-07 | feld | Merge branch 'cycles-guard' into 'develop' | implemented | Merge of custom guard cycle cleanup; local Web.Utils.Guards module is present. | |
| `da1ee5c46` | 2021-05-31 | Guy Sheffer | Add Raspberry Pi install instructions | not-applicable | Raspberry Pi installation documentation only. | |
| `30943b739` | 2021-06-07 | feld | Merge branch 'pleromapi' into 'develop' | not-applicable | Installation documentation merge only. | |
| `f5ef7fe43` | 2021-06-07 | Mark Felder | Fix test warnings | not-applicable | Test warning cleanup only. | |
| `a5ae0432e` | 2021-06-07 | Mark Felder | Test was named incorrectly and did not execute | implemented | Shout channel runtime module was restored in this audit; upstream test filename fix has no source delta to carry. | |
| `017f947fc` | 2021-06-07 | Mark Felder | Channel name was incorrect. We left it as chat:public for backwards compatibility. | implemented | ShoutChannel uses the backwards-compatible chat:public channel name locally. | |
| `4a6b49d0b` | 2021-06-07 | feld | Merge branch 'fix/config-test-warning' into 'develop' | not-applicable | Test warning cleanup merge only. | |
| `1399b82f7` | 2021-06-07 | Alex Gleason | Create WrapperAuthenticator and simplify Authenticator behaviour Speeds up recompilation by reducing compile-time cycles | implemented | WrapperAuthenticator and shared auth helpers are present locally. | |
| `ac2ed19e4` | 2021-06-08 | feld | Merge branch 'cycles-authenticator' into 'develop' | implemented | Merge of authenticator cycle cleanup; local auth wrapper/helper modules are present. | |
| `bdaa1d451` | 2021-06-07 | Alex Gleason | Upload.Filter: use generic types in @spec Speeds up recompilation by reducing compile-time deps | implemented | Upload.Filter callback specs use generic types in the current filter behaviour. | |
| `99f860558` | 2021-06-08 | feld | Merge branch 'cycles-uploads' into 'develop' | implemented | Merge of upload filter spec cycle cleanup; local Upload.Filter carries the simplified specs. | |
| `0877b120c` | 2021-06-08 | Alex Gleason | Pleroma.Web.ControllerHelper.truthy_param?/1 --> Pleroma.Web.Params.truthy_param?/1 Breaks cycle in lib/pleroma/web/api_spec/operations/status_operation.ex | implemented | truthy_param?/1 has moved out of ControllerHelper and calls through Pleroma.Web.Utils.Params. | |
| `ec65b7ae2` | 2021-06-08 | Alex Gleason | Pleroma.Web.Params --> Pleroma.Web.Utils.Params | implemented | Pleroma.Web.Utils.Params exists and owns truthy/falsy parameter helpers. | |
| `b99f60615` | 2021-06-08 | Alex Gleason | Fix order of Pleroma.Web.Utils.Params aliases | implemented | Alias ordering cleanup is represented in current modules using Pleroma.Web.Utils.Params. | |
| `5667c02fc` | 2021-06-08 | feld | Merge branch 'cycles-params' into 'develop' | implemented | Merge of params cycle cleanup; local Utils.Params helper is present and used. | |
| `2c401dafa` | 2021-06-04 | io | Improve opengraph embeds | implemented | OpenGraph/TwitterCard providers generate article metadata, proxied media tags, and non-image attachment handling. | No recheck. |
| `264458531` | 2021-06-07 | Mark Felder | Formatting | implemented | Formatting-only follow-up to the OpenGraph provider cluster; semantic provider behavior is present locally. | No recheck. |
| `939b3bfe4` | 2021-06-08 | feld | Merge branch 'improve-og-embed' into 'develop' | implemented | Merge-only row for the OpenGraph provider cluster reviewed above. | No recheck. |
| `5c27578bc` | 2021-06-08 | Mark Felder | Support metadata for video files too | implemented | AnalyzeMetadata checks ffprobe and stores video width/height in upload metadata. | No recheck. |
| `8443f8224` | 2021-06-08 | Mark Felder | Update scope of AnalyzeMetadata features | implemented | AnalyzeMetadata covers image dimensions, blurhash, and video dimensions with current Vix/ffprobe paths. | No recheck. |
| `1c4c73c6a` | 2021-06-08 | Mark Felder | Add test for AnalyzeMetadata upload filter fetching dimensions from a video | implemented | Runtime support is present and covered by local metadata extraction tests in the current upload filter suite. | No recheck. |
| `f1abe39f6` | 2021-06-08 | Mark Felder | Update test names and verify blurhash is correctly generated for images | implemented | Image blurhash generation is present through the Vix-backed AnalyzeMetadata path. | No recheck. |
| `3121ed132` | 2021-06-08 | Mark Felder | Blurhash varies slightly by computer generating it, so just validate it wasn't nil | implemented | Local tests use the modern non-nil/behavioral BlurHash assertion style rather than host-specific exact strings. | No recheck. |
| `117502368` | 2021-06-08 | feld | Merge branch 'metadata-for-all' into 'develop' | implemented | Merge-only row for the AnalyzeMetadata image/video cluster reviewed above. | No recheck. |
| `4faeec2c4` | 2021-06-08 | Alex Gleason | Create AdminAPI.UserView to avoid compile-time dep Speeds up recompilation | implemented | `Pleroma.Web.AdminAPI.UserView` delegates to AccountView and the controller renders through that view. | No recheck. |
| `4de2bd3b7` | 2021-06-08 | feld | Merge branch 'cycles-user-view' into 'develop' | implemented | Merge-only row for the AdminAPI.UserView compile-cycle cleanup. | No recheck. |
| `1be14cc45` | 2021-06-08 | Alex Gleason | Ignore runtime deps in Pleroma.Config.Loader with Module.concat/1 Speeds up recompilation | implemented | Config.Loader uses Module.concat/1 for Repo and Endpoint runtime dependencies. | No recheck. |
| `d896e45fa` | 2021-06-08 | feld | Merge branch 'cycles-config-loader-redux' into 'develop' | implemented | Merge-only row for the Config.Loader compile-cycle cleanup. | No recheck. |
| `45ab24f2d` | 2021-06-08 | Alex Gleason | Switch to runtime deps in Pleroma.Instances Speeds up recompilation by limiting compile cycles | implemented | Instances has the runtime dependency cleanup represented in the current module layout. | No recheck. |
| `d8c964fc1` | 2021-06-09 | Haelwenn | Merge branch 'cycles-instances' into 'develop' | implemented | Merge-only row for the Instances compile-cycle cleanup. | No recheck. |
| `67ec0e6c1` | 2021-06-08 | Alex Gleason | Switch to runtime deps in ActivityPub.SideEffects Speeds up recompilation by reducing compile cycles | implemented | SideEffects uses the pipeline path without retaining the old compile-time cycle shape. | No recheck. |
| `eba3c7b42` | 2021-06-09 | Haelwenn | Merge branch 'cycles-side-effects' into 'develop' | implemented | Merge-only row for the SideEffects compile-cycle cleanup. | No recheck. |
| `45b7325b9` | 2021-06-08 | Alex Gleason | Refactor skipped plugs into Pleroma.Web functions Speeds up recompilation by reducing compile cycles | implemented | `Pleroma.Web` owns skip_plug/authenticated API helpers used by controllers. | No recheck. |
| `53cf801c3` | 2021-06-09 | Haelwenn | Merge branch 'cycles-plug-deps' into 'develop' | implemented | Merge-only row for the skipped-plug compile-cycle cleanup. | No recheck. |
| `d0147eba7` | 2021-06-09 | Alex Gleason | Use eblurhash 1.1.0 from Hex | superseded | Local code uses maintained Hex `blurhash` 2.0 with Vix-backed image preprocessing instead of old eblurhash. | No action. |
| `489b8bea9` | 2021-06-09 | feld | Merge branch 'eblurhash-hex' into 'develop' | superseded | Merge-only row for an older BlurHash dependency choice superseded by local BlurHash 2.0. | No action. |
| `c839078a7` | 2021-06-09 | Haelwenn (lanodan) Monnier | ObjectValidators.{Announce,EmojiReact,Like}: Fix context, actor & addressing | implemented | Announce, EmojiReact, and Like validators call CommonFixes for actor, addressing, context, recipients, and audience repair. | No recheck. |
| `3972d7117` | 2021-06-09 | feld | Merge branch 'refactor/ingestion-activity-context' into 'develop' | implemented | Merge-only row for the object-action context/addressing repair reviewed above. | No recheck. |
| `4bb578a1d` | 2021-06-09 | Alex Gleason | Add cycles test to .gitlab-ci.yml Thank you @jb55@bitcoinhackers.org for the awk syntax | not-applicable | Upstream CI-only compile-cycle guard; local release validation is tracked outside upstream GitLab CI. | No code action. |
| `cefb952df` | 2021-06-09 | Alex Gleason | CI: echo $MIX_ENV | not-applicable | Upstream CI diagnostic-only commit. | No code action. |
| `87cd04fe0` | 2021-06-09 | Alex Gleason | Cycles CI: disable cache | not-applicable | Upstream CI-only behavior. | No code action. |
| `15e2aaa9f` | 2021-06-09 | Alex Gleason | Fix compile cycle in Pleroma.Tests.AuthTestController | not-applicable | Test-only compile-cycle cleanup; no production runtime behavior to backport. | No code action. |
| `b84873d3d` | 2021-06-09 | feld | Merge branch 'cycles-ci' into 'develop' | not-applicable | Merge-only row for upstream CI/test compile-cycle work. | No code action. |
| `5de65ce3e` | 2021-06-08 | Mark Felder | Set the correct height/width if the data is available when generating twittercard metadata | implemented | TwitterCard emits player/image width and height when upload metadata provides dimensions. | No recheck. |
| `d4ac9445c` | 2021-06-08 | Mark Felder | Twittercard metadata for images should also include dimensions if available | implemented | TwitterCard includes image dimensions when available and only falls back for supported player media. | No recheck. |
| `aa8cc4e86` | 2021-06-08 | Mark Felder | Only use fallback for videos and only add this metadata for images if we really have it. | implemented | TwitterCard media handling distinguishes audio/image/video and guards dimension tags behind metadata presence. | No recheck. |
| `d70db6308` | 2021-06-08 | Mark Felder | Set the correct height/width if the data is available when generating opengraph metadata | implemented | OpenGraph emits `og:image:*`, `og:video:*`, and `og:audio:*` dimensions when available. | No recheck. |
| `9cb896028` | 2021-06-08 | Mark Felder | Switch OGP default type from "website" to "article" | implemented | OpenGraph status/profile metadata uses `og:type` article where upstream switched from website. | No recheck. |
| `19a49dd75` | 2021-06-09 | Mark Felder | Remove Metadata.Utils.attachment_url/1 | implemented | OpenGraph/TwitterCard providers use local attachment URL helpers instead of the removed Metadata.Utils helper. | No recheck. |
| `2cf648d41` | 2021-06-09 | Mark Felder | Add a video thumbnail to the OpenGraph metadata if Media Preview Proxy is enabled. | implemented | OpenGraph adds MediaProxy preview thumbnails for videos when media preview proxy is enabled. | No recheck. |
| `dc8fe91de` | 2021-06-09 | Mark Felder | Metadata.Utils.attachment_url/1 was used in this test too | implemented | Test-only follow-up to the Metadata.Utils helper removal; provider runtime path is already local-helper based. | No recheck. |
| `86bcb87e6` | 2021-06-09 | Mark Felder | Fix incorrectly ordered arguments to the function and not properly merging lists. | implemented | Current metadata providers build media tag lists through explicit helper functions and concatenation order is correct. | No recheck. |
| `2a47156b8` | 2021-06-09 | Mark Felder | Lint | not-applicable | Upstream lint-only metadata follow-up. | No code action. |
| `5f7901cc4` | 2021-06-09 | Mark Felder | Credo | not-applicable | Upstream Credo-only metadata follow-up. | No code action. |
| `f37db2384` | 2021-06-09 | Mark Felder | Test that videos only get image thumbnails in OGP metadata when we can produce them with Preview Proxy | implemented | OpenGraph video thumbnail helper is gated on media preview proxy being enabled. | No recheck. |
| `d12e62c0b` | 2021-06-09 | Mark Felder | Add new Twittercard/OGP changes | implemented | Combined TwitterCard/OpenGraph media dimension and thumbnail behavior is present locally. | No recheck. |
| `6aa7fc15d` | 2021-06-09 | Mark Felder | Formatting of the comment | implemented | Comment-format follow-up to metadata provider code; local providers retain explanatory notes for preview behavior. | No recheck. |
| `202ee5fd7` | 2021-06-10 | Mark Felder | Add note about video thumbnails for code spelunkers unfamiliar with Media Preview Proxy | implemented | OpenGraph provider documents that media preview proxy thumbnails preserve source video dimensions. | No recheck. |
| `406dadb56` | 2021-06-10 | feld | Merge branch 'fix/twittercard-video-dimensions' into 'develop' | implemented | Merge-only row for the TwitterCard/OpenGraph media metadata cluster. | No recheck. |
| `640e1cf09` | 2021-06-11 | Alex Gleason | Cycles CI: skip unless Elixir code is modified | not-applicable | Upstream GitLab CI optimization only. | No code action. |
| `a8adc300d` | 2021-06-11 | Haelwenn | Merge branch 'cycles-ci-skip' into 'develop' | not-applicable | Merge-only row for upstream CI optimization. | No code action. |
| `6b1f7f2f5` | 2021-06-11 | Haelwenn (lanodan) Monnier | docs: Use one file to describe dependencies | deferred | Pleroma-specific dependency docs should be adapted separately to Unfathomably's source-install/build-script docs. | Revisit in documentation hardening. |
| `17f980e9a` | 2021-06-11 | Haelwenn (lanodan) Monnier | docs: Remove Erlang Solutions repository | deferred | Pleroma-specific install-doc cleanup; no runtime source change. | Revisit in documentation hardening. |
| `822196f39` | 2021-06-11 | Haelwenn (lanodan) Monnier | docs/Ã¢â‚¬Â¦/opt_en.md: Reuse /main/ repository url for the /community/ repo | deferred | Pleroma-specific install-doc cleanup; no runtime source change. | Revisit in documentation hardening. |
| `a814671e8` | 2021-06-22 | feld | Merge branch 'docs/dependencies-rewrite' into 'develop' | deferred | Merge-only row for Pleroma-specific dependency documentation. | Revisit in documentation hardening. |
| `a851a2403` | 2021-06-22 | Haelwenn (lanodan) Monnier | Downgrade Plug to 1.10.x, revert upload_limit tuple to function change | implemented | Endpoint parser length reads `Config.get([:instance, :upload_limit])`, matching runtime upload-limit changes with current Plug. | No recheck. |
| `fc6ab78a8` | 2021-06-22 | Haelwenn (lanodan) Monnier | Add test on changing [:instance, :upload_limit] | implemented | Runtime upload-limit parser path uses current Config lookup rather than a stale compile-time tuple. | No recheck. |
| `f9ae7e72e` | 2021-06-22 | Haelwenn | Merge branch 'bugfix/upload-limit-plug' into 'develop' | implemented | Merge-only row for runtime upload-limit parser behavior. | No recheck. |
| `54af52775` | 2021-06-23 | Alex Gleason | Upgrade Ecto to v3.6.2, remove deprecated ecto_explain | superseded | Local dependencies use Ecto SQL 3.14 and no longer rely on the old deprecated ecto_explain path. | No action. |
| `f97f305d0` | 2021-06-23 | feld | Merge branch 'ecto-upgrade' into 'develop' | superseded | Merge-only row for an older Ecto upgrade superseded by the current dependency train. | No action. |
| `281806de7` | 2021-06-24 | Alex Gleason | Activity deletion: fix FunctionClauseError #2686 | implemented | `Activity.delete_all_by_object_ap_id/1` and cache purge guards handle missing/non-binary IDs without FunctionClauseError. | No recheck. |
| `5717256eb` | 2021-06-25 | Haelwenn | Merge branch 'fix-2686' into 'develop' | implemented | Merge-only row for the guarded activity deletion fix. | No recheck. |
| `99cc26bb0` | 2021-06-30 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into remote-deletions | implemented | Merge-only row for remote deletion behavior represented by private purge and current deletion validators. | No recheck. |
| `310ef6b70` | 2021-06-30 | Alex Gleason | Deletions: change User.purge/1 to defp, add CHANGELOG entry | implemented | `User.purge/1` is private locally, keeping deletion internals out of the public API. | No recheck. |
| `9e1da4bf5` | 2021-07-06 | feld | Merge branch 'remote-deletions' into 'develop' | implemented | Merge-only row for remote deletion cleanup. | No recheck. |
| `64d009693` | 2021-07-08 | Mark Felder | Update Linkify to fix crash on posts with a URL we failed to parse correctly | superseded | Local dependency train uses Linkify 0.5.3, newer than the historical crash-fix bump. | No action. |
| `aa9a6c3c0` | 2021-07-08 | feld | Merge branch 'update/linkify' into 'develop' | superseded | Merge-only row for an older Linkify update superseded by the current dependency train. | No action. |
| `6dc78f5f6` | 2021-07-12 | Haelwenn (lanodan) Monnier | AP C2S: Remove restrictions and make it go through pipeline | implemented | ActivityPub C2S controller uses `Pipeline.common_pipeline/2` with explicit local handling and current safety guards. | No recheck. |
| `ebcc28fef` | 2021-07-12 | Haelwenn | Merge branch 'features/validators-apc2s' into 'develop' | implemented | Merge-only row for the AP C2S pipeline path. | No recheck. |
| `eb7313b0d` | 2021-06-04 | Haelwenn (lanodan) Monnier | Pipeline Ingestion: Page | implemented | ObjectValidator routes Article, Note, and Page through ArticleNotePageValidator; local group work further strengthens Page handling. | No recheck. |
| `173e977e2` | 2021-07-12 | Haelwenn | Merge branch 'features/ingestion-page' into 'develop' | implemented | Merge-only row for Page ingestion through the validator pipeline. | No recheck. |
| `1a2fe96d5` | 2021-07-14 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into admin-api-users-date | implemented | Admin user rendering includes Mastodon-format `created_at` dates. | No recheck. |
| `117b3edf5` | 2021-07-14 | Alex Gleason | CHANGELOG: AdminAPI return date with users | implemented | AdminAPI AccountView renders `created_at` through Mastodon date formatting. | No recheck. |
| `17d79f348` | 2021-07-14 | feld | Merge branch 'admin-api-users-date' into 'develop' | implemented | Merge-only row for AdminAPI user date rendering. | No recheck. |
| `5e8879678` | 2021-07-13 | Alex Gleason | AdminAPI: sort user results by ID descending | implemented | AdminAPI search orders user results by descending ID. | No recheck. |
| `deb3f9113` | 2021-07-13 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into admin-api-users-sort | implemented | Merge-only row for AdminAPI user result sorting. | No recheck. |
| `5681a007d` | 2021-07-13 | Alex Gleason | CHANGELOG: AdminAPI users sort | implemented | Behavior row is implemented; upstream changelog note does not need separate local code. | No recheck. |
| `3f5821364` | 2021-07-14 | feld | Merge branch 'admin-api-users-sort' into 'develop' | implemented | Merge-only row for AdminAPI user result sorting. | No recheck. |
| `6ef8e1776` | 2021-07-02 | marcin mikoÃ…â€šajczak | fix the fucking list timelines on mastofe/soapbox-fe | implemented | List timeline response pipes activities through `add_link_headers/2` before rendering. | No recheck. |
| `7acdab1f3` | 2021-07-22 | Haelwenn | Merge branch 'mkljczk-develop-patch-60115' into 'develop' | implemented | Merge-only row for list timeline link-header behavior. | No recheck. |
| `33a19c002` | 2021-07-27 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into errorview-json-fix | implemented | Phoenix format encoders include activity+json with Jason, so ActivityPub JSON errors render through JSON. | No recheck. |
| `3d8ce61fe` | 2021-07-27 | Alex Gleason | CHANGELOG: fixed JSON error rendering | implemented | Behavior row is implemented by current Phoenix activity+json format encoder. | No recheck. |
| `7495beeb4` | 2021-07-27 | feld | Merge branch 'errorview-json-fix' into 'develop' | implemented | Merge-only row for ActivityPub JSON error rendering. | No recheck. |
| `9cc8642b8` | 2021-07-27 | Alex Gleason | Visibility: check Tombstone objects in visible_for_user?/2 | implemented | Visibility marks Tombstone objects non-public and invisible to users. | No recheck. |
| `7f23dd6cc` | 2021-07-27 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into object-tombstone-visibility | implemented | Merge-only row for Tombstone visibility; current Visibility rejects Tombstone objects as public or user-visible. | No recheck. |
| `d8a986c9e` | 2021-07-27 | feld | Merge branch 'object-tombstone-visibility' into 'develop' | implemented | Merge-only row for Tombstone visibility; current Visibility rejects Tombstone objects as public or user-visible. | No recheck. |
| `5f8a9b671` | 2021-08-01 | Haelwenn (lanodan) Monnier | Update AdminFE bundle | superseded | Old bundled AdminFE static artifact update; Unfathomably manages frontend/admin assets through current frontend tooling and installable frontends. | No action. |
| `79e993cae` | 2021-08-01 | Haelwenn (lanodan) Monnier | Release 2.4.0 | not-applicable | Upstream release marker for Pleroma 2.4.0; local changelog and release train are Unfathomably-specific. | No code action. |
| `469405b7b` | 2021-08-06 | matildepark | CHANGELOG.md: Fix instances of 2020 being actually 2021 | not-applicable | Upstream changelog date correction only. | No code action. |
| `0910777d4` | 2021-08-08 | Haelwenn (lanodan) Monnier | Update PleromaFE Bundle (2.4.0) | superseded | Old bundled PleromaFE static artifact update; Unfathomably FE is maintained separately and Soapbox-derived frontend assets are not imported from this bundle. | No action. |
| `dc63aaf84` | 2021-08-08 | Haelwenn | Merge branch 'release/2.4.0' into 'stable' | not-applicable | Upstream stable-branch release merge; local audit tracks semantic commits directly. | No code action. |
| `b11dbbf40` | 2021-08-17 | Alex Gleason | UserController: fall back to frontend when user isn't found | implemented | Feed.UserController falls back through RedirectController metadata/frontend routes when the requested user is not found. | No recheck. |
| `34606d609` | 2021-08-13 | kPherox | fix: stream out Create Activity | implemented | Create side effects stream non-ChatMessage activities through `ap_streamer().stream_out/1`, preserving the upstream Create streaming fix while avoiding duplicate chat-message delivery. | No recheck. |
| `1cf89de89` | 2021-08-13 | Ilja | Make the OPT recomendation clearer | not-applicable | Upstream OTP-installation wording is superseded by Unfathomably source install and upgrade guides. | No code action. |
| `8baaa36a1` | 2021-08-13 | Haelwenn (lanodan) Monnier | ObjectAgePolicy: Fix pattern matching on published | implemented | `ObjectAgePolicy` matches `Create` activities by `object.published`, updates nested object recipients, and normalizes unusual recipient shapes. | No recheck. |
| `3961422f8` | 2021-08-13 | Haelwenn (lanodan) Monnier | TwitterAPI: Make change_password require body params instead of query | implemented | `change_password` OpenAPI and controller paths require body parameters through `body_params`. | No recheck. |
| `0e2aebd03` | 2021-08-13 | Haelwenn (lanodan) Monnier | TwitterAPI: Make change_email require body params instead of query | implemented | `change_email` OpenAPI and controller paths require body parameters through `body_params`. | No recheck. |
| `bb2d5879c` | 2021-08-13 | Haelwenn (lanodan) Monnier | maybe_notify_subscribers: Don't create notifications from ingested replies | implemented | `maybe_notify_subscribers/2` checks the normalized object and skips subscriber notifications for replies, including ingested remote replies. | No recheck. |
| `e11755116` | 2021-08-13 | Alex Gleason | AdminAPI: hotfix for nil report objects | implemented | `AdminAPI.Report.extract_report_info/1` rejects nil report objects before resolving status activities. | No recheck. |
| `27e1e4c74` | 2021-08-13 | Haelwenn (lanodan) Monnier | Activity.Search: fallback on status resolution on DB Timeout | implemented | Database search rescues local query failures and still runs URL/object fallback resolution via `maybe_fetch/3`. | No recheck. |
| `01175ef49` | 2021-08-13 | Alex Gleason | Streamer: fix crash in MastodonAPI.StatusView | implemented | `StatusView.reblogged?/2` only inspects announcements for an authenticated `%User{}` and returns false for nil/logged-out users. | No recheck. |
| `09c42ce13` | 2021-08-28 | Sam Therapy | Add Admin-FE menu for StealEmojiPolicy | implemented | `StealEmojiPolicy.config_description/0` is present and locally strengthened with explicit shortcode matching behavior. | No recheck. |
| `53b0dd4ec` | 2021-08-28 | Ilja | List available frontends also when no static/frontends folder is present yet | implemented | `FrontendController.installed/0` returns an empty list when the frontend directory does not exist, and local code also exposes installed refs. | No recheck. |
| `bd0eb1c67` | 2021-08-28 | Tusooa Zhu | Make activity search properly use GIN indexes | implemented | `Pleroma.Search.DatabaseSearch` uses two-argument `to_tsvector(?::oid::regconfig, ...)` so GIN-backed status search can use the configured text-search index. | No recheck. |
| `20084329e` | 2021-08-28 | Ilja | Selecting MRF policies didn't work as intended any more | implemented | MRF config descriptions discover implementations through `Pleroma.Web.ActivityPub.MRF.Policy`. | No recheck. |
| `cc4f20b13` | 2021-08-28 | someone | mix pleroma.database set_text_search_config now runs concurrently and infinitely | implemented | `mix pleroma.database set_text_search_config` builds the GIN index concurrently and uses infinite timeouts for long-running index/function work. | No recheck. |
| `7372609c5` | 2021-08-28 | Haelwenn (lanodan) Monnier | Release 2.4.1 | not-applicable | Upstream release-version bump only; Unfathomably carries its own release train. | No code action. |
| `0b2119d4a` | 2021-08-29 | Haelwenn | Merge branch 'release/2.4.1' into 'stable' | not-applicable | Stable release merge aggregating rows audited individually in this ledger. | No code action. |
| `991b26f49` | 2022-01-10 | lain | Merge branch 'update-hackney' into 'develop' | superseded | Old Hackney bump is superseded by the current Hackney 4.x dependency line and later HTTP client hardening. | No action. |
| `bf0b32c9a` | 2022-01-11 | lain | Merge branch 'pleroma-result-1_13' into 'develop' | implemented | `Publisher.publish_one/1` keeps the successful Tesla result in the guarded `with` match and has additional terminal-status handling. | No recheck. |
| `cd3175c7f` | 2022-01-11 | Alex Gleason | Merge branch 'fix/rich-media-test-escape-unicrud' into 'develop' | not-applicable | Upstream rich-media parser test-only cleanup; no runtime code to backport. | No code action. |
| `f4bc2f597` | 2022-01-11 | rinpatch | Add 2.4.2 changelog entry and bump mix version | not-applicable | Upstream 2.4.2 changelog/version bump only. | No code action. |
| `ea204dbca` | 2022-01-11 | rinpatch | mix.lock: sync with mix.exs | superseded | Old lockfile sync is superseded by the current dependency lock. | No action. |
| `a98a12771` | 2022-01-11 | rinpatch | Pleroma-FE bundle: update to b13d8f7e6339e877a38a28008630dc8ec64abcdf | not-applicable | Bundled Pleroma-FE static assets are not used by Unfathomably FE/BE release flow. | No code action. |
| `e4cfdfd70` | 2022-01-11 | Lain Soykaf | CI: Upload the image for all platforms | not-applicable | Upstream GitLab CI image upload change does not apply to local deployment tooling. | No code action. |
| `b34f0a6e5` | 2022-01-11 | Lain Soykaf | CI: Conservatively update release images so they keep building. | not-applicable | Upstream GitLab release-image maintenance does not apply to local deployment tooling. | No code action. |
| `62a45747d` | 2022-01-11 | rinpatch | Merge branch 'release/2.4.2' into 'stable' | not-applicable | Stable release merge aggregating version, CI, bundle, and dependency rows handled separately. | No code action. |
| `85cbf773f` | 2022-05-06 | Ilja | update sweet_xml [Security] | superseded | SweetXML security bump is superseded by current `sweet_xml` 0.7.5. | No action. |
| `4d482b765` | 2022-05-06 | Tusooa Zhu | Allow to skip cache in Cache plug | implemented | `Pleroma.Web.Plugs.Cache` honors `conn.assigns.skip_cache` while still running tracking callbacks. | No recheck. |
| `fa3157df9` | 2022-05-06 | Tusooa Zhu | Skip cache when /objects or /activities is authenticated | implemented | ActivityPub object/activity rendering calls `maybe_skip_cache/2` for authenticated requests. | No recheck. |
| `57c486014` | 2022-05-06 | Haelwenn (lanodan) Monnier | Release 2.4.3 | not-applicable | Upstream 2.4.3 release/version note only; security rows are audited separately. | No code action. |
| `b22843a98` | 2022-05-06 | Haelwenn | Merge branch 'security/2.4.3' into 'stable' | implemented | Security-release cache bypass behavior and SweetXML dependency update are present or superseded locally. | No recheck. |
| `c62a4f1c1` | 2022-08-19 | Tusooa Zhu | Disconnect streaming sessions when token is revoked | implemented | OAuth token revocation asynchronously calls `Streamer.close_streams_by_oauth_token/1`, and sockets register by token id. | No recheck. |
| `eb42e90c4` | 2022-08-19 | Tusooa Zhu | Use Websockex to replace websocket_client | implemented | `websockex` is the local websocket test client dependency. | No recheck. |
| `3522852c6` | 2022-08-19 | Tusooa Zhu | Test that server will disconnect websocket upon token revocation | not-applicable | Upstream websocket revocation test-only commit; runtime behavior is implemented by the token revocation streamer cleanup rows. | No code action. |
| `f459c1260` | 2022-08-19 | Tusooa Zhu | Lint | not-applicable | Upstream lint/test cleanup for websocket revocation branch; no runtime code to backport. | No code action. |
| `a31d6bb52` | 2022-08-19 | Tusooa Zhu | Execute session disconnect in background | implemented | Token revocation starts `Streamer.close_streams_by_oauth_token/1` under `Pleroma.TaskSupervisor`, so disconnect work runs in the background. | No recheck. |
| `5a2c8ef4c` | 2022-08-19 | Tusooa Zhu | Refactor streamer test | not-applicable | Upstream streamer test refactor only. | No code action. |
| `31fd41de0` | 2022-08-19 | Tusooa Zhu | Release 2.4.4 | not-applicable | Upstream 2.4.4 release/version bump only. | No code action. |
| `59b8c920f` | 2022-10-09 | tusooa | Merge branch 'release/2.4.4' into 'stable' | not-applicable | Stable release merge aggregating websocket revocation rows handled separately. | No code action. |
| `508b438b5` | 2022-11-27 | Haelwenn (lanodan) Monnier | scrubbers: Scrub img class attribute | implemented | Default and TwitterText scrubbers allow only the safe `emoji` class on `img` tags. | No recheck. |
| `4504c8108` | 2022-11-27 | Ilja | Delete report notifs when demoting from superuser | implemented | `Notification.destroy_multiple_from_types/2` and `User.update_and_set_cache/1` now clear `pleroma:report` notifications when a user loses `:reports_manage_reports` privilege. | No recheck. |
| `da7109200` | 2022-11-27 | Haelwenn (lanodan) Monnier | EctoType: Add MIME validator | implemented | `Pleroma.Web.ActivityPub.ObjectValidators.MIME` exists and is used for ActivityPub media-type validation. | No recheck. |
| `8640d217b` | 2022-11-27 | Haelwenn (lanodan) Monnier | AttachmentValidator: Use custom ecto type and regex for "mediaType" | implemented | `AttachmentValidator` uses the custom MIME Ecto type for attachment and URL mediaType fields. | No recheck. |
| `7ec3469be` | 2022-11-27 | Haelwenn (lanodan) Monnier | Transmogrifier: Use validating regex for "mediaType" | implemented | Transmogrifier media-type validation uses the shared MIME validation path rather than accepting arbitrary strings. | No recheck. |
| `09ab51eeb` | 2022-11-27 | Tusooa Zhu | Make mutes and blocks behave the same as other lists | implemented | Mutes and blocks paginate through `Pleroma.Pagination.fetch_paginated(params)` and render through the normal account index path. | No recheck. |
| `f12ddcd69` | 2022-11-27 | Haelwenn (lanodan) Monnier | timeline_controller_test: Fix test name for elixir 1.14 | not-applicable | Upstream Elixir 1.14 test-name cleanup only. | No code action. |
| `915c7319c` | 2022-11-27 | Haelwenn (lanodan) Monnier | mix: Switch prometheus_ex to fix/elixir-1.14 branch | superseded | Old prometheus_ex branch pin is superseded by the local PromEx metrics integration. | No action. |
| `f2221d539` | 2022-11-27 | Haelwenn (lanodan) Monnier | script_test: Fix %ErlangError for Elixir 1.14 | not-applicable | Upstream Elixir 1.14 media-proxy invalidation test cleanup only. | No code action. |
| `9b6877888` | 2022-11-27 | Sean King | Fix fedi-fe build URL | not-applicable | Upstream bundled fedi-fe build URL is not part of Unfathomably FE/BE deployment. | No code action. |
| `e46c3a059` | 2022-11-27 | Tusooa Zhu | Do not stream out Create of ChatMessage | implemented | Create side effects avoid duplicate ChatMessage streaming, while ChatMessages continue through their dedicated chat streaming path. | No recheck. |
| `11d5ad24c` | 2022-11-27 | Tusooa Zhu | Make local-only posts stream in local timeline | implemented | Local-only posts can reach local timeline streaming through the local-public recipient/topic handling. | No recheck. |
| `747311f62` | 2022-11-27 | FloatingGhost | fix resolution of GTS user keys | implemented | HTTP signature key resolution supports GoToSocial-style and multi-key actor documents in the local signature path. | No recheck. |
| `542bb1725` | 2022-11-27 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | ArticleNotePageValidator: fix replies fixing | implemented | `ArticleNotePageValidator` normalizes replies collections, extracts replies collection IDs, and drops unsupported collection objects before casting. | No recheck. |
| `2614f431b` | 2022-11-27 | Haelwenn (lanodan) Monnier | Release 2.4.5 | not-applicable | Upstream 2.4.5 release/version note only; constituent runtime rows are audited separately. | No code action. |
| `76bdb01c1` | 2022-11-27 | Haelwenn | Merge branch 'release/2.4.5' into 'stable' | not-applicable | Stable release merge aggregating 2.4.5 rows handled separately. | No code action. |
| `75c9f7770` | 2022-11-27 | Sean King | Fix changelog date | not-applicable | Upstream changelog date fix only. | No code action. |
| `d8e326467` | 2022-11-28 | Haelwenn | Merge branch 'fix/2.4.5-release-date' into 'stable' | not-applicable | Stable changelog-date merge only. | No code action. |
| `9bc1e79c5` | 2021-07-12 | Alex Gleason | Moderators: add UserIsStaffPlug | implemented | `Pleroma.Web.Plugs.UserIsStaffPlug` exists and gates staff-only admin API access. | No recheck. |
| `1f093cb21` | 2021-07-12 | Alex Gleason | Moderators: reorganize :admin_api pipeline in Router | implemented | Router `:admin_api` pipeline uses `UserIsStaffPlug`, with stricter admin-only routes layered through `:require_admin`. | No recheck. |
| `44ede0657` | 2021-08-04 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into staff-plug | not-applicable | Topic-branch mergeback with many rows handled individually elsewhere in the ledger. | No code action. |
| `5f5dc2402` | 2021-08-05 | Haelwenn | Merge branch 'staff-plug' into 'develop' | implemented | Staff-plug branch merge; local router and plug behavior are present. | No recheck. |
| `8f730f70c` | 2021-08-08 | Haelwenn (lanodan) Monnier | mix.exs: 2.4.50 | not-applicable | Upstream development version bump only. | No code action. |
| `c45b3bde9` | 2021-08-08 | Haelwenn | Merge branch 'chores/2.4.0-develop' into 'develop' | not-applicable | Upstream chores/version merge only. | No code action. |
| `647087d7f` | 2021-08-06 | Ilja | Deprectate strings for SimplePolicy | implemented | Deprecation warnings detect string-based SimplePolicy configuration and rewrite to tuple form. | No recheck. |
| `4ba0beb60` | 2021-08-06 | Ilja | Make mrfSimple work with tuples | implemented | `SimplePolicy` consumes tuple-based instance lists and normalizes them through MRF helpers. | No recheck. |
| `dd947d9bc` | 2021-08-06 | Ilja | Add tests for setting `:instance, :quarantined_instances` | not-applicable | Upstream quarantine tuple test-only commit; runtime support is covered by the adjacent rows. | No code action. |
| `27fe7b027` | 2021-08-06 | Ilja | Make quarentine work with list of tuples instead of strings | implemented | MRF helper functions normalize tuple/string instance lists, and publisher quarantine checks use the tuple-aware path. | No recheck. |
| `e0c7d7719` | 2021-08-06 | Ilja | Deprecate and rewrite settings for quarentine settings | implemented | Deprecation warnings rewrite `:instance, :quarantined_instances` string lists to tuple lists. | No recheck. |
| `dfeb3862d` | 2021-08-06 | Ilja | config :mrf, :transparency_exclusions works with tumples now | implemented | MRF transparency exclusions support tuple entries and are rendered through tuple-aware SimplePolicy metadata. | No recheck. |
| `3c5a497b1` | 2021-08-06 | Ilja | Deprecate transparency_exclusions | implemented | Deprecation warnings rewrite string transparency exclusions to tuple form. | No recheck. |
| `b674ba658` | 2021-08-06 | Ilja | make linter happy | not-applicable | Upstream lint cleanup for deprecation-warning tests only. | No code action. |
| `64002e92a` | 2021-08-06 | Ilja | config/description.exs: Update quarantine settings to tuples | implemented | Config descriptions expose tuple placeholders for quarantined instances and MRF settings. | No recheck. |
| `c0489f9fa` | 2021-08-06 | Ilja | Fixed deprecation warning checks | implemented | Config deprecation warning checks include the fixed tuple-detection/rewrite paths. | No recheck. |
| `1f52246a0` | 2021-08-06 | Ilja | Add database migrations | implemented | Database migrations for SimplePolicy, quarantined instances, and transparency exclusions string-to-tuple conversion are present. | No recheck. |
| `7fdc3cde0` | 2021-08-06 | Ilja | Return maps in node_info | implemented | NodeInfo/instance metadata returns MRF values as maps where reasons are available. | No recheck. |
| `47fc57bbc` | 2021-08-06 | Ilja | Change what nodeinfo returns without breaking backwards compatibility | implemented | NodeInfo keeps backwards-compatible simple lists while exposing richer MRF info maps. | No recheck. |
| `03030b47c` | 2021-08-06 | Ilja | quarantine instances info | implemented | Instance metadata includes quarantined instance info with reason maps. | No recheck. |
| `506bf1636` | 2021-08-06 | Ilja | Change docs | not-applicable | Upstream documentation-only tuple policy update; local docs have diverged for Unfathomably. | No code action. |
| `941842404` | 2021-08-06 | Ilja | Add transparency_exclusions also to the breaking changes | not-applicable | Upstream changelog-only transparency-exclusions note. | No code action. |
| `f4028c908` | 2021-08-06 | Ilja | Add key- and valuePlaceholders for quarantined_instances and mrf_simple | implemented | MRF and keyword/simple policy config descriptions expose key/value placeholders for tuple entry editing. | No recheck. |
| `b0926a71b` | 2021-08-06 | Ilja | Make transparency_exclusions use tuples in admin-fe | implemented | MRF transparency exclusions and KeywordPolicy config descriptions use tuple-friendly metadata. | No recheck. |
| `cd706c033` | 2021-08-06 | Ilja | improve changelog entry | not-applicable | Upstream changelog-only wording change. | No runtime BE/FE behavior to port. |
| `ee26f2c91` | 2021-08-06 | Ilja | Quarantine placeholders | implemented | `config/description.exs` already exposes quarantine and rejected-instance key/value placeholders as `instance` and `reason`. | Preserved current configuration metadata. |
| `ad09bdb37` | 2021-08-06 | Egor Kislitsyn | Improve readability | implemented | Current MRF/deprecation/instance metadata code already uses the readable tuple-reason helpers and explicit instance-info shaping from this patch family. | No source change needed. |
| `6384d7803` | 2021-08-09 | Haelwenn | Merge branch 'simple_policy_reasons_for_instance_specific_policies' into 'develop' | not-applicable | Merge-only aggregation of the simple-policy reason work handled by the surrounding individual rows. | No standalone runtime change. |
| `0114754db` | 2021-07-17 | Alex Gleason | MastodonAPI: Support poll notification | implemented | Current BE includes `poll` in notification types, notification API schema/controller/view handling, push alert types, Oban `poll_notifications` queue, and `PollWorker`. | No source change needed. |
| `cbd1a10c1` | 2021-07-18 | Alex Gleason | Poll notification: notify for polls even when block_from_strangers is set | implemented | `Notification.skip?/4` explicitly bypasses `:self` and `:block_from_strangers` suppression when `opts[:type] == "poll"`. | No source change needed. |
| `6a6e42c9b` | 2021-07-18 | Alex Gleason | PollWorker defensive checks | implemented | `PollWorker` validates job IDs, cancels missing poll activities, bounds scheduling to configured poll expiration, and discards malformed jobs. | No source change needed. |
| `0b1c05ca1` | 2021-07-18 | Alex Gleason | Poll notification: trigger PollWorker through common_pipeline | implemented | `SideEffects.handle_object_creation/3` and the local `ActivityPub.insert/4` path both schedule poll-end work through the current worker. | No source change needed. |
| `70f1496eb` | 2021-07-18 | Alex Gleason | Poll notification: only notify local users | implemented | `Notification.create_poll_notifications/1` creates poll notifications only for `%User{local: true}` poll creators and voters. | No source change needed. |
| `62bf6d67e` | 2021-07-18 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into poll-notification-fixes | not-applicable | Merge-only upstream integration commit; poll-notification behavior is handled by the surrounding individual rows. | No standalone runtime change. |
| `85d71d4f1` | 2021-07-18 | Alex Gleason | CHANGELOG: Support `poll` notification type | not-applicable | Upstream changelog-only entry for behavior already present locally. | No runtime BE/FE behavior to port. |
| `901204df2` | 2021-08-09 | Haelwenn | Merge branch 'poll-notification' into 'develop' | not-applicable | Merge-only wrapper for the poll-notification rows already handled above. | No standalone runtime change. |
| `ee5def34d` | 2021-08-09 | kPherox | fix: stream out Create Activity | implemented | `SideEffects.handle/2` streams non-chat Create activities through `ap_streamer().stream_out(activity)` after notification work. | Current code also documents why ChatMessages are streamed in their specialized object path. |
| `f4af74b0f` | 2021-08-09 | Haelwenn | Merge branch 'fix/streaming-api-for-create-activity' into 'develop' | not-applicable | Merge-only wrapper for `ee5def34d`. | No standalone runtime change. |
| `438ad0d3f` | 2021-08-10 | Ilja | Make the OPT recomendation clearer | not-applicable | Upstream installation-doc wording is superseded by Unfathomably's own install/upgrade docs and build scripts. | No BE/FE runtime behavior to port. |
| `6c0ebc65f` | 2021-08-10 | Haelwenn | Merge branch 'docs_make_otp_recommendation_clearer' into 'develop' | not-applicable | Merge-only wrapper for upstream OTP documentation wording. | Superseded by Unfathomably docs. |
| `c64eae40a` | 2021-08-10 | Haelwenn (lanodan) Monnier | ObjectAgePolicy: Fix pattern matching on published | implemented | `ObjectAgePolicy` now checks `object.published` on `Create` activities and short-circuits safely when the object lacks the field. | No source change needed. |
| `8679a57a7` | 2021-08-10 | Haelwenn | Merge branch 'bugfix/object-age-create' into 'develop' | not-applicable | Merge-only wrapper for `c64eae40a`. | No standalone runtime change. |
| `09dcb2b52` | 2021-08-10 | Haelwenn (lanodan) Monnier | TwitterAPI: Make change_password require body params instead of query | implemented | `UtilController.change_password/2` reads credentials from `body_params`, and the OpenAPI operation uses a required request body. | Avoids password leakage through query strings. |
| `197cdebca` | 2021-08-10 | Haelwenn (lanodan) Monnier | TwitterAPI: Make change_email require body params instead of query | implemented | `UtilController.change_email/2` reads the password and new email from `body_params`, and the OpenAPI operation uses a required request body. | Avoids credential leakage through query strings. |
| `7c1243178` | 2021-08-10 | Haelwenn | Merge branch 'bugfix/change_password' into 'develop' | not-applicable | Merge-only wrapper for the password/email body-param fixes. | No standalone runtime change. |
| `436fac3ba` | 2021-08-11 | Haelwenn (lanodan) Monnier | maybe_notify_subscribers: Don't create notifications from ingested messages | implemented | `CommonAPI.Utils.maybe_notify_subscribers/2` normalizes the object without fetching and only adds subscribers when `object["inReplyTo"]` is nil. | Remote ingested replies do not trigger subscriber notifications. |
| `3ca39ccf6` | 2021-08-11 | Haelwenn | Merge branch 'bugfix/subscriptions-replies' into 'develop' | not-applicable | Merge-only wrapper for `436fac3ba`. | No standalone runtime change. |
| `7247c2965` | 2021-08-11 | Alex Gleason | AdminAPI: hotfix for nil report objects | implemented | `AdminAPI.Report.extract_report_info/1` rejects nil status IDs before resolving report statuses. | Current code additionally handles embedded report objects with guarded fake activity rendering. |
| `3a7b54be4` | 2021-08-11 | Haelwenn | Merge branch 'nil-report-object-hotfix' into 'develop' | not-applicable | Merge-only wrapper for `7247c2965`. | No standalone runtime change. |
| `6455b967e` | 2021-08-12 | Haelwenn (lanodan) Monnier | Activity.Search: fallback on status resolution on DB Timeout | implemented | Search is superseded by the newer `Pleroma.Search` stack: controller searches run through bounded async tasks with fallbacks, and database search checks out one DB connection before remote fallback resolution. | Stronger than the 2021 rescue-only patch. |
| `7afabe1cc` | 2021-08-13 | rinpatch | Merge branch 'bugfix/status-search-fallback' into 'develop' | not-applicable | Merge-only wrapper for `6455b967e`. | No standalone runtime change. |
| `69ebfb29f` | 2021-07-27 | Daniel | Update dev.exs error message to write to stderr. Currently it dumps this message at the beginnig of the file when using vim-autoformat with mix format | implemented | `config/dev.exs` writes the missing `dev.secret.exs` warning through `IO.puts(:stderr, ...)`. | No source change needed. |
| `5c5571c66` | 2021-07-27 | Daniel | use puts instead warn | implemented | Current `config/dev.exs` uses `IO.puts/2` instead of `IO.warn/1` for the local dev warning. | No source change needed. |
| `21720db85` | 2021-08-13 | rinpatch | Merge branch 'dkuku-develop-patch-66061' into 'develop' | not-applicable | Merge-only wrapper for the dev stderr warning fix. | No standalone runtime change. |
| `b7bbf42ac` | 2021-08-13 | Alex Gleason | Streamer: fix crash in MastodonAPI.StatusView | implemented | `StatusView.reblogged?/2` now guards on `%User{}` and list-shaped `announcements`, returning false for logged-out users or malformed objects. | Prevents streamer rendering crashes from odd announce payloads. |
| `61ba54897` | 2021-08-13 | Haelwenn | Merge branch 'streamer-crash-fix' into 'develop' | not-applicable | Merge-only wrapper for `b7bbf42ac`. | No standalone runtime change. |
| `7a9113deb` | 2021-08-13 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Translated using Weblate (Polish) | not-applicable | Upstream Polish gettext catalog-only update. | Historical localization commits are not manually ported row-by-row; current catalogs should be synced through the localization workflow. |
| `edd2a38e5` | 2021-08-13 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Translated using Weblate (Polish) | not-applicable | Upstream Polish gettext catalog-only update. | Historical localization commits are not manually ported row-by-row; current catalogs should be synced through the localization workflow. |
| `97eb160c3` | 2021-08-13 | Haelwenn | Merge branch 'weblate-pleroma-pleroma' into 'develop' | not-applicable | Merge-only wrapper for Polish gettext catalog updates. | No BE/FE runtime behavior to port. |
| `a2eacfc52` | 2021-08-14 | Alex Gleason | CommonAPI.Utils.make_note_data/1 --> ActivityPub.Builder.note/1 | implemented | Current compose flow uses `Pleroma.Web.ActivityPub.Builder.note/1`; `CommonAPI.ActivityDraft` calls the builder instead of the old `make_note_data/1` helper. | No source change needed. |
| `ba6049aa8` | 2021-08-14 | Alex Gleason | Builder.note/1: return {:ok, map(), keyword()} like other Builder functions | implemented | `ActivityDraft` expects `{:ok, note_data, _meta} = Builder.note(draft)`, matching the normalized builder return shape. | No source change needed. |
| `773708cfe` | 2021-08-14 | Haelwenn | Merge branch 'builder-note' into 'develop' | not-applicable | Merge-only wrapper for the builder-note refactor. | No standalone runtime change. |
| `b901b7305` | 2021-08-14 | Sam Therapy | Add Admin-FE menu for StealEmojiPolicy | implemented | `StealEmojiPolicy.config_description/0` exposes `hosts`, `rejected_shortcodes`, and `size_limit` children for admin configuration surfaces. | No source change needed. |
| `2d9f803dc` | 2021-08-14 | Haelwenn | Merge branch 'StealEmojiMRF_add_adminFE' into 'develop' | not-applicable | Merge-only wrapper for the StealEmojiPolicy config metadata. | No standalone runtime change. |
| `f9bafc17f` | 2021-08-14 | Ilja | List available frontends also when no static/frontends folder is present yet | implemented | `FrontendController.available/2` checks `File.exists?(Pleroma.Frontend.dir())` before listing installed frontend directories. | No source change needed. |
| `84ec0fbea` | 2021-08-14 | Haelwenn | Merge branch 'show_frontends_also_when_no_static_frontends_folder_is_created_yet' into 'develop' | not-applicable | Merge-only wrapper for the frontend directory fallback. | No standalone runtime change. |
| `a9984c6da` | 2021-08-27 | Tusooa Zhu | Make activity search properly use GIN indexes | implemented | `Search.DatabaseSearch` separates GIN and RUM query fragments and uses `plainto_tsquery`/`websearch_to_tsquery` shapes appropriate to the selected index. | No source change needed. |
| `a80cb58ac` | 2021-08-27 | Tusooa Zhu | Add changelog for !3519 | not-applicable | Upstream changelog-only entry for the GIN search fix already present locally. | No runtime BE/FE behavior to port. |
| `018b0948d` | 2021-08-28 | Haelwenn | Merge branch 'from/develop/tusooa/2758-gin-index-search' into 'develop' | not-applicable | Merge-only wrapper for the GIN search query fix. | No standalone runtime change. |
| `5049b4272` | 2021-08-14 | Ilja | Selecting MRF policies didn't work as intended any more | implemented | MRF policy configuration suggestions use `{:list_behaviour_implementations, Pleroma.Web.ActivityPub.MRF.Policy}` so Admin-FE can choose behavior implementations rather than generated docs-only policy names. | No source change needed. |
| `6633ec816` | 2021-08-28 | Haelwenn | Merge branch 'admin_fe_dont_list_mrf_policies_any_more' into 'develop' | not-applicable | Merge-only wrapper for the MRF policy selection fix. | No standalone runtime change. |
| `61d233921` | 2021-08-11 | Haelwenn (lanodan) Monnier | ObjectValidator.stringify_keys: filter out nil values | implemented | `ObjectValidator.stringify_keys/1` filters out map entries whose values are nil before stringifying keys. | Prevents nil-valued ActivityPub fields from leaking into validator changesets. |
| `bc62a3528` | 2021-08-28 | Haelwenn | Merge branch 'features/ingestion-no-nil' into 'develop' | not-applicable | Merge-only wrapper for the nil-filtering validator fix. | No standalone runtime change. |
| `c29fc1aaf` | 2021-08-07 | Ilja | Add YunoHost to installation guides | not-applicable | Upstream installation-doc-only addition is superseded by Unfathomably's own install docs and distro build scripts. | No BE/FE runtime behavior to port. |
| `26abe96ab` | 2021-08-28 | Haelwenn | Merge branch 'docs_add_yunohost_installation' into 'develop' | not-applicable | Merge-only wrapper for upstream YunoHost documentation. | Superseded by Unfathomably docs. |
| `4b940e441` | 2021-08-15 | someone | mix pleroma.database set_text_search_config now runs concurrently and infinitely | implemented | `mix pleroma.database set_text_search_config` uses concurrent index work and `timeout: :infinity` for the long-running database maintenance queries. | No source change needed. |
| `689a59f41` | 2021-08-28 | Haelwenn | Merge branch 'set_text_search_config_timeout' into 'develop' | not-applicable | Merge-only wrapper for the text-search maintenance timeout fix. | No standalone runtime change. |
| `28a17c2dc` | 2021-08-28 | Haelwenn (lanodan) Monnier | Merge branch 'release/2.4.1' into chores/2.4.1-develop | not-applicable | Historical upstream release merge only updates old changelog/version metadata. | Superseded by Unfathomably release metadata. |
| `2e695dbe3` | 2021-08-29 | Haelwenn | Merge branch 'chores/2.4.1-develop' into 'develop' | not-applicable | Merge-only wrapper for the old 2.4.1 release metadata. | Superseded by Unfathomably release metadata. |
| `181282fb2` | 2021-09-01 | Mark Felder | Remove unused Logger | implemented | `lib/pleroma/web/preload.ex` no longer references `Logger`. | No source change needed. |
| `6b1282a82` | 2021-09-01 | Haelwenn | Merge branch 'small-cleanup' into 'develop' | not-applicable | Merge-only wrapper for the unused Logger cleanup. | No standalone runtime change. |
| `4f55d5123` | 2021-04-15 | Sean King | Remove MastoFE-related backend code and frontend pieces | implemented | Current BE has no `MastoFeController`, MastoFE template/view, or bundled MastoFE packs; Unfathomably serves its own static frontend instead. | Cleaned remaining admin/docs wording that still described asset and manifest options as MastoFE-specific. |
| `8afa3f2d1` | 2021-04-15 | Sean King | Remove no longer necessary unit tests for MastoFE | not-applicable | Test-only deletion for removed upstream MastoFE controller behavior. | Current tests target Unfathomably frontend/static behavior rather than MastoFE. |
| `ca79aab0b` | 2021-04-15 | Sean King | Remove MastoFE settings from users table | implemented | Migration `20210416051708_remove_mastofe_settings_from_users.exs` removes `users.mastofe_settings`; no runtime user schema reference remains. | No source change needed. |
| `f3b403fa9` | 2021-04-15 | Sean King | Remove MastoFE stuff from docs and default panel | implemented | Current default panel contains no MastoFE references; stale asset/manifest docs were modernized to compatible-frontend wording in this audit pass. | Updated BE changelog. |
| `bf9c4f528` | 2021-04-15 | Sean King | Add note about Mastodon FE being removed from Pleroma in changelog | not-applicable | Upstream changelog-only entry for Pleroma's removed MastoFE. | Superseded by Unfathomably changelog wording for the local cleanup. |
| `08694599a` | 2021-04-15 | Sean King | Remove bash script for downloading new MastoFE build | implemented | `installation/download-mastofe-build.sh` is absent. | No source change needed. |
| `fa2e62078` | 2021-04-15 | Sean King | Remove MastoFE configuration stuff | implemented | Runtime config has no `:masto_fe` frontend configuration block; remaining MastoFE-specific admin/docs wording was removed in this audit pass. | The still-present `showInstanceSpecificPanel` setting belongs to `pleroma_fe`, not MastoFE. |
| `a787fed8f` | 2021-04-16 | Sean King | Move changelog around | not-applicable | Historical upstream changelog organization only. | Superseded by Unfathomably changelog. |
| `0f8da39b7` | 2021-04-16 | Sean King | Remove priv/static/sounds folder | implemented | `priv/static/sounds` is absent from current BE. | Soapbox/Unfathomably runtime static assets live separately under the frontend/static path. |
| `2de41770d` | 2021-04-16 | Sean King | Remove Twemoji stuff from MastoFE | implemented | Representative MastoFE Twemoji asset `priv/static/emoji/1f004.svg` is absent, matching the removed MastoFE asset bundle. | No source change needed. |
| `dc4814f0c` | 2021-06-04 | Sean King | Fix merge conflicts with upstream | not-applicable | Upstream remove/mastofe branch conflict resolution only. | No standalone runtime behavior. |
| `839c2c6a1` | 2021-06-04 | Sean King | Fix code mistake in OAuth controller | implemented | Current OAuth controller no longer has the conflicted local-MastoFE `redirect_uri(".", ...)` special case. | No source change needed. |
| `2e310b3ec` | 2021-06-04 | Sean King | Fix more build errors | not-applicable | Build cleanup inside the historical MastoFE removal branch. | Current BE already builds without those removed modules. |
| `26d2c677b` | 2021-06-04 | Sean King | Removing trailing space on empty line in OAuth controller | not-applicable | Whitespace-only cleanup in the historical MastoFE removal branch. | No runtime behavior. |
| `5d279a22b` | 2021-07-10 | Sean King | Merge develop branch upstream | not-applicable | Merge-only update while the upstream remove/mastofe branch was in progress. | No standalone runtime behavior. |
| `9758f636b` | 2021-07-10 | Sean King | Delete MastoFE Controller Test | not-applicable | Test-only deletion for removed MastoFE controller. | No runtime behavior. |
| `1841bd838` | 2021-08-06 | Sean King | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into remove/mastofe | not-applicable | Merge-only upstream branch synchronization. | No standalone runtime behavior. |
| `6b3842cf5` | 2021-09-07 | Haelwenn | Merge branch 'remove/mastofe' into 'develop' | not-applicable | Merge-only wrapper for the MastoFE removal cluster. | Individual useful effects are handled in the rows above. |
| `36df37e05` | 2021-09-20 | Mark Felder | Update to newer buildx as current one can't be downloaded due to some Github error | not-applicable | Upstream GitLab CI buildx image pin only. | Unfathomably uses its own build scripts and current deployment flow rather than this old CI image. |
| `d86b10a5e` | 2021-09-21 | Haelwenn | Merge branch 'dockerfix' into 'develop' | not-applicable | Merge-only wrapper for the old buildx CI pin. | No runtime BE/FE behavior. |
| `ad5da6ae6` | 2021-09-12 | partev | fix a typo "Optionnal" -> "Optional" | implemented | `docs/installation/generic_dependencies.include` already uses `Optional dependencies`. | No source change needed. |
| `d2d462748` | 2021-10-06 | Haelwenn | Merge branch 'partev-develop-patch-72837' into 'develop' | not-applicable | Merge-only wrapper for the documentation typo fix. | No standalone runtime change. |
| `198250dce` | 2021-09-05 | Tusooa Zhu | Allow users to remove their emails if instance does not need email to register | implemented | `User.change_email/2` uses `maybe_validate_required_email(false)`, and the change-email OpenAPI schema documents blank email removal. | No source change needed. |
| `92a8ff59a` | 2021-10-06 | Haelwenn | Merge branch 'from/develop/tusooa/add-remove-emails' into 'develop' | not-applicable | Merge-only wrapper for the email-removal behavior. | No standalone runtime change. |
| `3b20eddcf` | 2021-10-06 | Haelwenn (lanodan) Monnier | mix: Update crypt to fix #pragma warning | not-applicable | The old `crypt` dependency is absent; current password hashing uses the modern dependency set and current `elixir_make` override. | Superseded by later dependency updates. |
| `bdaa7e539` | 2021-10-06 | Haelwenn | Merge branch 'bugfix/crypt-pragma' into 'develop' | not-applicable | Merge-only wrapper for the old `crypt` dependency bump. | Superseded by current dependency set. |
| `a17910a6c` | 2021-10-06 | Haelwenn (lanodan) Monnier | CI: Bump lint stage to elixir-1.12 | not-applicable | Historical CI/lint compatibility cleanup for Elixir 1.12-era upstream. | Superseded by current stricter compiler-warning cleanup and newer toolchain work. |
| `390ceb9f9` | 2021-10-06 | Haelwenn | Merge branch 'ci/bump-elixir-lint' into 'develop' | not-applicable | Merge-only wrapper for old CI/lint cleanup. | No standalone runtime behavior. |
| `8467065ab` | 2021-10-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Translated using Weblate (Polish) | not-applicable | Upstream gettext catalog-only update. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `477d83944` | 2021-10-06 | @liimee | Added translation using Weblate (Indonesian) | not-applicable | Upstream gettext catalog-only addition. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `e00fe5b61` | 2021-10-06 | @liimee | Translated using Weblate (Indonesian) | not-applicable | Upstream gettext catalog-only update. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `bea8a204a` | 2021-10-06 | @liimee | Translated using Weblate (Indonesian) | not-applicable | Upstream gettext catalog-only update. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `4a15fd8a0` | 2021-10-06 | @liimee | Translated using Weblate (Indonesian) | not-applicable | Upstream gettext catalog-only update. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `f2806adee` | 2021-10-06 | @liimee | Translated using Weblate (Indonesian) | not-applicable | Upstream gettext catalog-only update. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `f0d0d4f6e` | 2021-10-06 | @liimee | Translated using Weblate (Indonesian) | not-applicable | Upstream gettext catalog-only update. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `a3909f30b` | 2021-10-06 | @liimee | Translated using Weblate (Indonesian) | not-applicable | Upstream gettext catalog-only update. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `3647c8e45` | 2021-10-06 | HÃƒÂ¡Ã‚Â»Ã¢â‚¬Å“ NhÃƒÂ¡Ã‚ÂºÃ‚Â¥t Duy | Added translation using Weblate (Vietnamese) | not-applicable | Upstream gettext catalog-only addition. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `a84aa10f7` | 2021-10-06 | HÃƒÂ¡Ã‚Â»Ã¢â‚¬Å“ NhÃƒÂ¡Ã‚ÂºÃ‚Â¥t Duy | Translated using Weblate (Vietnamese) | not-applicable | Upstream gettext catalog-only update. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `84a7eb559` | 2021-10-06 | Ryo Ueno | Added translation using Weblate (Japanese) | not-applicable | Upstream gettext catalog-only addition. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `5f2aefee1` | 2021-10-06 | Ryo Ueno | Translated using Weblate (Japanese) | not-applicable | Upstream gettext catalog-only update. | Historical localization rows are deferred to localization sync rather than manually ported one by one. |
| `fee226063` | 2021-10-06 | Haelwenn | Merge branch 'weblate-pleroma-pleroma' into 'develop' | not-applicable | Merge-only wrapper for gettext catalog updates. | No runtime BE/FE behavior. |
| `3af7db9fd` | 2021-10-06 | Mark Felder | Fix typo | implemented | `lib/pleroma/maintenance.ex` no longer contains the old typo from this upstream patch. | No source change needed. |
| `d8d819ddc` | 2021-10-07 | feld | Merge branch 'typo' into 'develop' | not-applicable | none | Merge-only typo branch; no portable backend/frontend behavior to backport. |
| `23161526d` | 2021-10-10 | Haelwenn (lanodan) Monnier | object_validators: Group common fields in CommonValidations | implemented | BE | Local validators already share `ObjectValidators.CommonFields` and keep the common validation helpers separated. |
| `6b5c2d5f8` | 2021-10-10 | Haelwenn | Merge branch 'refactor/group_validator_fields' into 'develop' | not-applicable | none | Merge-only wrapper for `23161526d`; implementation evidence is recorded on that row. |
| `7dcc73f29` | 2021-11-14 | Lain Soykaf | Mix: Update crypt to fix musl builds. | not-applicable | none | The old `crypt` dependency is absent; current password/signature dependencies supersede this musl build fix. |
| `eb0f7620f` | 2021-11-14 | lain | Merge branch 'update-crypt' into 'develop' | not-applicable | none | Merge-only wrapper for a dependency that is no longer used locally. |
| `23e91ec8d` | 2021-11-10 | Haelwenn (lanodan) Monnier | activity_pub_controller: Fix misleading debug warning in post_inbox_fallback | implemented | BE | Local inbox handling has explicit invalid-signature, host-mismatch, relayed-Create, and missing-signature clauses; the misleading `post_inbox_fallback` warning path is gone. |
| `0f8b10ff5` | 2021-11-14 | lain | Merge branch 'bugfix/inbox-misleading-warning' into 'develop' | not-applicable | none | Merge-only wrapper for `23e91ec8d`; implementation evidence is recorded on that row. |
| `5c7aa4a1e` | 2021-11-14 | Lain Soykaf | CI: Conservatively update release images so they keep building. | not-applicable | none | Upstream GitLab release-image maintenance does not apply to the local source deployment and smoke-build scripts. |
| `d058e1c97` | 2021-11-14 | lain | Merge branch 'fix-releases' into 'develop' | not-applicable | none | Merge-only CI release-image wrapper; no runtime behavior to backport. |
| `bd7724398` | 2021-11-15 | lain | Merge branch 'userfeed-fe-fallback' into 'develop' | implemented | BE | HTML user feed redirects fall back to the frontend redirector when a user is missing, while known users retain metadata-aware redirects. |
| `e4ad4f0bd` | 2021-11-10 | Haelwenn (lanodan) Monnier | mix: Update http_signatures to 0.1.1 | implemented | BE | Current dependency train uses `http_signatures` 0.1.3, which supersedes the upstream 0.1.1 bump. |
| `838da53ea` | 2021-11-15 | lain | Merge branch 'bump/http_signatures-0.1.1' into 'develop' | not-applicable | none | Merge-only wrapper for a superseded dependency bump. |
| `9a0cb34c8` | 2021-07-12 | Alex Gleason | Fix Activity.delete_all_by_object_ap_id/1 timeout so users can be deleted | implemented | BE | `Activity.delete_all_by_object_ap_id/1` deletes with an infinite Repo timeout so large user/instance cleanup does not hit the old query timeout. |
| `e40b58fd5` | 2021-07-12 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into fix-object-deletion-timeout | not-applicable | none | Merge-only branch maintenance for the deletion-timeout fix. |
| `65514484c` | 2021-07-12 | Alex Gleason | CHANGELOG: fixed user deletion database timeout | not-applicable | docs | Historical upstream changelog-only commit; local behavior is covered by `9a0cb34c8`. |
| `6aff3d320` | 2021-11-15 | lain | Merge branch 'fix-object-deletion-timeout' into 'develop' | not-applicable | none | Merge-only wrapper for `9a0cb34c8`; implementation evidence is recorded on that row. |
| `25676c84b` | 2021-07-17 | Alex Gleason | Create AdminAPI.InstanceController | implemented | BE | Local Admin API has `InstanceController` for instance status listing and deletion operations. |
| `c136dc098` | 2021-07-17 | Alex Gleason | Upgrade Ecto to v3.6.2, remove deprecated ecto_explain | implemented | BE | Current Ecto stack is newer than 3.6.2 and the deprecated `ecto_explain` dependency is not used. |
| `f67d00d12` | 2021-07-17 | Alex Gleason | Add Instance.delete_users_and_activities/1 to delete all content from a remote instance | implemented | BE | `Pleroma.Instances.Instance.delete_users_and_activities/1` enqueues background instance deletion and the worker performs the cleanup. |
| `54dbcfe02` | 2021-07-17 | Alex Gleason | AdminAPI: add DELETE /instances/:instance to delete all content from a remote instance | implemented | BE | Router and controller expose `DELETE /api/v1/pleroma/admin/instances/:instance`, backed by instance deletion. |
| `bad79f79e` | 2021-07-17 | Alex Gleason | AdminAPI.InstanceController: clean up tests, rename actions | implemented | BE | Local controller uses the cleaned `list_statuses` and `delete` action names with matching router wiring. |
| `3674179b2` | 2021-07-17 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into instance-deletion | not-applicable | none | Merge-only branch maintenance for the instance-deletion work. |
| `c4efe0d2d` | 2021-07-17 | Alex Gleason | CHANGELOG: instance deletion | not-applicable | docs | Historical upstream changelog-only commit; local behavior is covered by the instance-deletion rows. |
| `6e3df1169` | 2021-11-15 | lain | Merge branch 'instance-deletion' into 'develop' | not-applicable | none | Merge-only wrapper for the instance-deletion feature set; implementation evidence is recorded on the feature rows. |
| `d2364276a` | 2020-10-10 | Alex Gleason | Blocks: always see your own posts | implemented | BE | Local block filtering preserves posts authored by the reading user even when recipients or addressed domains are blocked, with activity tests for both cases. |
| `2fc7ce3e1` | 2020-10-10 | Alex Gleason | Blocks: add blockers_visible config | implemented | BE | `:activitypub, :blockers_visible` exists in runtime config and admin configuration descriptions. |
| `7c2d0e378` | 2020-10-10 | Alex Gleason | Blocks: make blockers_visible config work | implemented | BE | `restrict_blockers_visibility/2` filters timelines when blockers are hidden and timeline controller tests cover the disabled setting. |
| `5c8d2c468` | 2020-10-10 | Alex Gleason | Blocks: update CHANGELOG | not-applicable | docs | Historical upstream changelog-only entry; local behavior is recorded in the relevant feature rows. |
| `b3d6cf902` | 2020-10-13 | Alex Gleason | Merge remote-tracking branch 'upstream/develop' into block-behavior | not-applicable | none | Intermediate upstream synchronization merge; individual portable commits are audited separately. |
| `04b7505c7` | 2020-10-26 | lain | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into alexgleason/pleroma-block-behavior | not-applicable | none | Intermediate upstream synchronization merge; no standalone block-behavior code to port. |
| `bae48c98e` | 2020-11-04 | lain | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into alexgleason/pleroma-block-behavior | not-applicable | none | Intermediate upstream synchronization merge; no standalone block-behavior code to port. |
| `2aeb229de` | 2020-11-04 | lain | Cheatsheet: Add info about :blockers_visible | implemented | docs | Local configuration cheatsheet documents `blockers_visible` under ActivityPub settings. |
| `1438fd958` | 2021-01-06 | Alex Gleason | Merge remote-tracking branch 'upstream/develop' into block-behavior | not-applicable | none | Intermediate upstream synchronization merge; individual portable commits are audited separately. |
| `cc09079ae` | 2021-01-06 | Alex Gleason | Exclude blockers from notifications when `blockers_visible: false` | implemented | BE | Notification queries call `exclude_blockers/2`, which suppresses blocker-origin notifications when `blockers_visible` is false, with controller coverage. |
| `b7b05a074` | 2021-01-06 | Alex Gleason | Oopsie whoopsie fix changelog | not-applicable | docs | Historical upstream changelog-only correction. |
| `762be6ce1` | 2021-04-29 | Alex Gleason | Merge remote-tracking branch 'upstream/develop' into block-behavior | not-applicable | none | Intermediate upstream synchronization merge; no standalone runtime change. |
| `e2772d6bf` | 2021-11-15 | lain | Merge branch 'block-behavior' into 'develop' | not-applicable | none | Merge-only wrapper for the block-behavior feature family; implementation evidence is recorded on the individual rows. |
| `26450a0be` | 2021-11-14 | Lain Soykaf | Mix: Upgrade mogrify library | implemented | BE | Current dependency train uses Mogrify 0.9.3, newer than the upstream 0.9.1 bump. |
| `2dea4a8c0` | 2021-11-14 | Lain Soykaf | StealEmojiPolicyTest: Make mocks explicit. | not-applicable | tests | Upstream test-only mock cleanup; no runtime BE/FE behavior to backport. |
| `871936b3c` | 2021-11-14 | Lain Soykaf | MediaProxyCacheControllerTest: Fix unstable tests. | not-applicable | tests | Upstream unstable-test cleanup only; local media proxy runtime fixes are tracked separately. |
| `4d341f51e` | 2021-11-15 | lain | Merge branch 'fix-tests' into 'develop' | not-applicable | none | Merge-only wrapper for one dependency bump and upstream test cleanup. |
| `f78cb6ab9` | 2021-11-15 | Lain Soykaf | CI: Upload the image for all platforms | not-applicable | none | Upstream GitLab container-publishing maintenance does not apply to local deployment/build scripts. |
| `add2b9cd8` | 2021-11-15 | lain | Merge branch 'update-elixir' into 'develop' | not-applicable | none | Merge-only CI image update; local Elixir/OTP support is handled by the current dependency and build-script work. |
| `5e15ceb49` | 2021-11-16 | Haelwenn (lanodan) Monnier | mix: Update earmark | implemented | BE | Runtime markdown rendering no longer depends on Earmark, and the remaining Earmark parser is only a current ExDoc transitive dependency. |
| `c97f99ccf` | 2021-11-16 | Haelwenn | Merge branch 'bugfix/markdown-newlines' into 'develop' | not-applicable | none | Merge-only wrapper for the superseded Earmark dependency bump. |
| `a9b002707` | 2021-11-29 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Account endorsements | implemented | BE | Endorsement relationship type, Mastodon/Pleroma account endpoints, relationship rendering, and maximum endorsed-user config are present. |
| `50e375075` | 2021-05-05 | Alex Gleason | Add notice compatibility routes for other frontends Fixes: https://git.pleroma.social/pleroma/pleroma/-/issues/1785 | implemented | BE | Static FE and compatibility tests cover `/notice/:id` status routes for frontend and remote-follow compatibility. |
| `1a45aa127` | 2021-05-05 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into notice-routes | not-applicable | none | Intermediate upstream synchronization merge; portable commits in the branch are audited separately. |
| `b15c4629f` | 2021-05-05 | Alex Gleason | CHANGELOG: notice routes | not-applicable | docs | Historical upstream changelog-only entry for behavior already present locally. |
| `cd5fb84b7` | 2021-12-02 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | remote_interaction API endpoint | implemented | BE | `UtilController.remote_interaction/2`, OpenAPI metadata, and router wiring are present; `/authorize-interaction` is also carried as a Mastodon-compatible alias. |
| `5da4f33bf` | 2021-12-03 | Alex Gleason | Restore POST /auth/password | implemented | BE | `PasswordController` exposes `POST /auth/password` and tests cover email/nickname reset paths and inactive-user rejection. |
| `182c563ed` | 2021-11-29 | NEETzsche | Force pinned_objects to be empty, not null | implemented | BE | User schema defaults `pinned_objects` to `%{}` and the migration forces the column to `null: false, default: %{}`. |
| `d486d7d09` | 2021-11-29 | lain | Merge branch 'force_pinned_objects_to_be_empty' into 'develop' | not-applicable | none | Merge-only wrapper for `182c563ed`; implementation evidence is recorded on that row. |
| `809503011` | 2021-11-29 | a1batross | Mix: upgrade Hackney to 1.18.0 | implemented | BE | Current dependency train uses Hackney 4.4.5, superseding the upstream 1.18.0 update. |
| `aaed93db2` | 2021-12-01 | lain | Merge branch 'update-hackney' into 'develop' | not-applicable | none | Merge-only wrapper for a superseded dependency bump. |
| `04aca335a` | 2021-11-15 | Alibek Omarov | nodeinfo: report activeMonth and activeHalfyear users fields | implemented | BE | NodeInfo usage metadata includes `activeMonth` and `activeHalfyear` from `User.active_user_count/1`. |
| `efc28812b` | 2021-11-17 | Alibek Omarov | Add changelog entry | not-applicable | docs | Historical upstream changelog-only entry. |
| `235c4139d` | 2021-12-02 | lain | Merge branch 'fix/2782-nodeinfo-active-users' into 'develop' | not-applicable | none | Merge-only wrapper for `04aca335a`; implementation evidence is recorded on that row. |
| `8286ceb46` | 2021-12-03 | Alex Gleason | Merge remote-tracking branch 'origin/develop' into password-reset | not-applicable | none | Intermediate upstream synchronization merge; password-reset behavior is audited on the feature rows. |
| `ba2ed3c25` | 2021-12-03 | Alex Gleason | Fix frontend_status_plug_test.exs | not-applicable | tests | Upstream test-only adjustment for frontend status plug coverage. |
| `5c573a8a2` | 2021-12-03 | lain | Merge branch 'password-reset' into 'develop' | not-applicable | none | Merge-only wrapper for `POST /auth/password`; implementation evidence is recorded on that row. |
| `cd8bdbc76` | 2021-12-06 | FloatingGhost | Make deactivated user check into a subquery | implemented | BE | Local deactivated-user filtering is already database-side via an active-user join, avoiding the old `Repo.all()` materialization this upstream patch fixed. |
| `db46913dc` | 2021-12-06 | FloatingGhost | make linter happy | not-applicable | none | Formatting-only follow-up to the deactivated-user query patch. |
| `ab60c0c6c` | 2021-12-06 | lain | Merge branch 'optimisation/deactivated-subquery' into 'develop' | not-applicable | none | Merge-only wrapper for `cd8bdbc76`; implementation evidence is recorded on that row. |
| `ce4560c2a` | 2021-12-03 | Alex Gleason | Fix benchmarks | not-applicable | benchmarks | Upstream benchmark-only maintenance; no production BE/FE behavior to backport. |
| `613f55b07` | 2021-12-06 | lain | Merge branch 'benchmark' into 'develop' | not-applicable | none | Merge-only wrapper for benchmark maintenance. |
| `ab5dee84b` | 2021-12-07 | Alex Gleason | Run `mix deps.get` | implemented | BE | Current `mix.lock` has been refreshed far beyond this upstream lock update. |
| `e219e504c` | 2021-12-07 | lain | Merge branch 'mix-lock' into 'develop' | not-applicable | none | Merge-only wrapper for an old lockfile refresh. |
| `8af53101f` | 2021-12-07 | Finn Behrens | move result into with guard | implemented | BE | Local ActivityPub publisher binds the successful HTTP `result` in the `with` match guard, avoiding the old compiler issue. |
| `500e12660` | 2021-12-07 | lain | Merge branch 'pleroma-result-1_13' into 'develop' | not-applicable | none | Merge-only wrapper for the publisher compiler cleanup. |
| `ca8c67686` | 2021-12-07 | Lain Soykaf | Linting. | implemented | BE | Local publisher keeps the cleaned, Elixir-friendly formatting of the guarded `HTTP.post/3` path. |
| `b57041c59` | 2021-12-07 | lain | Merge branch 'fixyfix' into 'develop' | not-applicable | none | Merge-only wrapper for publisher lint cleanup. |
| `d194b5b7f` | 2021-12-08 | Alex Gleason | Benchmarks: fix user timeline and tags benchmarks | not-applicable | benchmarks | Upstream benchmark-only maintenance; no production BE/FE behavior to backport. |
| `60295b58f` | 2021-12-09 | lain | Merge branch 'benchmark-fixes' into 'develop' | not-applicable | none | Merge-only wrapper for benchmark maintenance. |
| `d9349bc52` | 2021-12-07 | Alex Gleason | Transmogrifier: test fix_attachments/1 | not-applicable | tests | Upstream test-only coverage; runtime attachment behavior is tracked on the validator row. |
| `3f03d71ea` | 2021-12-07 | Alex Gleason | AttachmentValidator: ingest width and height | implemented | BE | Attachment URL validation stores `width` and `height`, and string `url`/`href` inputs are normalized with dimensions preserved. |
| `335684182` | 2021-12-07 | Alex Gleason | Fix VideoHandlingTest | not-applicable | tests | Upstream test-only adjustment for video fixture expectations. |
| `2c96668a2` | 2021-12-07 | Alex Gleason | Merge remote-tracking branch 'origin/develop' into fix-attachment-dimensions | not-applicable | none | Intermediate upstream synchronization merge; attachment behavior is recorded on `3f03d71ea`. |
| `992d9287d` | 2021-12-07 | Haelwenn | Apply alexgleason's suggestion(s) to 1 file(s) | not-applicable | none | No standalone runtime delta remained after reviewing this attachment follow-up. |
| `01cc099c8` | 2021-12-07 | Alex Gleason | VideoHandlingTest: remove nil values | not-applicable | tests | Upstream fixture expectation cleanup only. |
| `fb0aa0661` | 2021-12-09 | lain | Merge branch 'fix-attachment-dimensions' into 'develop' | not-applicable | none | Merge-only wrapper for attachment-dimension ingestion. |
| `8672ad6b0` | 2021-12-13 | Alex Gleason | TwitterAPI: allow deleting one's own account with request body | implemented | BE | `delete_account/2` accepts `body_params[:password]` before the legacy query parameter and documents why JSON body submission is preferred. |
| `6eb7d69e6` | 2021-12-15 | lain | Merge branch 'delete-account-fix' into 'develop' | not-applicable | none | Merge-only wrapper for the delete-account body-parameter fix. |
| `31b9034a2` | 2021-12-17 | a1batross | emoji/loader.ex: be more verbose about which emoji pack config is loading now | implemented | BE | Emoji loader logs whether each pack came from `pack.json`, `emoji.txt`, or file-extension scanning. |
| `8cfd52758` | 2021-12-17 | lain | Merge branch 'verbose-emoji-loader' into 'develop' | not-applicable | none | Merge-only wrapper for emoji-loader logging. |
| `ff17884c3` | 2021-12-17 | Tusooa Zhu | Bump alpine to 3.14 | not-applicable | none | Upstream container base-image maintenance; local source deployment scripts are distro-specific instead. |
| `b686d68cd` | 2021-12-18 | lain | Merge branch 'from/develop/tusooa/alpine-3.14' into 'develop' | not-applicable | none | Merge-only wrapper for upstream Alpine image maintenance. |
| `108dfd1f8` | 2021-12-12 | Alex Gleason | Search: limit number of results | implemented | BE | User search has a default result limit and passes explicit `limit`/`offset` through paginated queries. |
| `7c1d80455` | 2021-12-19 | Alex Gleason | Merge branch 'fix-search-dos' into 'develop' | not-applicable | none | Merge-only wrapper for the search result-limit fix. |
| `7e1caddc5` | 2021-11-25 | Alex Gleason | v2 Suggestions: return empty array | implemented | BE | `/api/v2/suggestions` is routed and returns a list response through `SuggestionController.index2/2`. |
| `b17360cd7` | 2021-11-26 | Alex Gleason | v2 Suggestions: rudimentary API response | implemented | BE | Suggested accounts are selected from `is_suggested` users and rendered through the Mastodon account view. |
| `e28d990ec` | 2021-11-26 | Alex Gleason | v2 Suggestions: don't skip visibility check | implemented | BE | Suggestions filter invisible, blocked, muted, dismissed, and already-followed accounts before rendering. |
| `6c0484d57` | 2021-11-26 | Alex Gleason | AdminAPI: suggest a user through the API | implemented | BE | Admin user controller exposes suggest/unsuggest actions backed by `User.set_suggestion/2`. |
| `da06e1a17` | 2021-11-26 | Alex Gleason | v2 Suggestions: add index on is_suggested column | implemented | BE | `20211126191138_add_suggestions.exs` adds `users.is_suggested` and its index. |
| `aee55b9a8` | 2021-11-26 | Alex Gleason | v2 Suggestions: dismiss a suggestion | implemented | BE | `DELETE /api/v1/suggestions/:account_id` records a `:suggestion_dismiss` relationship. |
| `437c1a5a5` | 2021-11-26 | Alex Gleason | v2 Suggestions: actually flter out dismissed suggestions | implemented | BE | Suggestion queries exclude `:suggestion_dismiss` relationships and tests cover dismissed accounts. |
| `e5a7547fb` | 2021-11-26 | Alex Gleason | v2 Suggestions: also filter out users you follow | implemented | BE | Suggestion controller tests cover excluding already-followed suggested accounts. |
| `8dc1d2201` | 2021-11-26 | Alex Gleason | Instance: add v2_suggestions feature | implemented | BE | Instance feature metadata advertises `v2_suggestions`. |
| `6519f59d9` | 2021-11-26 | Alex Gleason | v2 Suggestions: return `is_suggested` through the API | implemented | BE | Admin and Mastodon account renderers expose `is_suggested` metadata where appropriate. |
| `bd853199d` | 2021-12-19 | Alex Gleason | Merge branch 'v2-suggestions' into 'develop' | not-applicable | none | Merge-only wrapper for the v2 suggestions feature family. |
| `29d80b39f` | 2021-12-15 | Alex Gleason | Add Phoenix LiveDashboard | implemented | BE | Phoenix LiveDashboard dependency and router integration are present under `/pleroma/live_dashboard`, with the legacy path redirected. |
| `e1b89fe3a` | 2021-12-15 | Alex Gleason | Merge remote-tracking branch 'origin/develop' into live-dashboard | not-applicable | none | Intermediate upstream synchronization merge. |
| `1ff9ffed8` | 2021-12-19 | Alex Gleason | Merge branch 'live-dashboard' into 'develop' | not-applicable | none | Merge-only wrapper for LiveDashboard integration. |
| `dff435488` | 2021-12-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add link headers in ChatController.index2 | implemented | BE | `ChatController.index2/2` uses paginated chat queries and adds Link headers to the response. |
| `d1510c98d` | 2021-12-19 | Alex Gleason | Merge branch 'link-headers-chats' into 'develop' | implemented | BE | Merge-only chat pagination row; `ChatController.index2/2` uses paginated chat queries and emits Link headers. |
| `d64d1b1d4` | 2021-11-23 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix replies count for remote replies | implemented | BE | `SideEffects.handle(Create)` checks non-Answer objects before increasing the parent replies count, preserving remote reply counts. |
| `df5359aa7` | 2021-12-19 | Alex Gleason | Merge branch 'replies-count' into 'develop' | implemented | BE | Merge-only row for the remote replies-count fix covered by `d64d1b1d4`. |
| `cb9359335` | 2021-11-24 | Alex Gleason | Expose /manifest.json for PWA | implemented | BE | `ManifestController`, `ManifestView`, `/manifest.json`, and manifest controller/frontend static tests are present locally. |
| `720198d56` | 2021-11-24 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into manifest | not-applicable | Audit | Sync merge into an upstream feature branch; semantic changes are audited through their own rows. |
| `e4f9cb1c1` | 2021-12-19 | Alex Gleason | Merge remote-tracking branch 'origin/develop' into manifest | not-applicable | Audit | Sync merge into an upstream feature branch; semantic changes are audited through their own rows. |
| `b0d2b5393` | 2021-12-19 | Alex Gleason | Merge branch 'manifest' into 'develop' | implemented | BE | Merge-only row for `/manifest.json`; local manifest route, view, controller, and tests are present. |
| `555d7d57c` | 2021-09-09 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add "exposable_reactions" to features, if showing reactions | implemented | BE | `InstanceView.features/0` advertises `exposable_reactions` when `:instance, :show_reactions` is enabled. |
| `50892a198` | 2021-12-19 | Alex Gleason | Merge branch 'mkljczk-develop-patch-64464' into 'develop' | implemented | BE | Merge-only row for conditional `exposable_reactions` feature advertising. |
| `2ce7dae6d` | 2021-12-21 | Alex Gleason | Skip erratic tests | not-applicable | Tests | Upstream CI test-selection change only; no runtime behavior to backport. |
| `9c1cb87ef` | 2021-12-22 | Alex Gleason | Merge branch 'erratic-tests' into 'develop' | not-applicable | Tests | Merge-only upstream CI/test-selection row. |
| `4fe9a758f` | 2021-07-12 | Alex Gleason | Let moderators manage custom emojis | implemented | BE | Local router exposes emoji pack/file mutation through role-scoped staff privileges, superseding the older broad moderator/admin split. |
| `2b3d7794b` | 2021-07-12 | Alex Gleason | AdminAPI: let moderators actually do things | implemented | BE | Admin API routes are split into admin-only and privileged staff scopes with explicit role pipelines. |
| `b83758bd9` | 2021-08-05 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into moderators | not-applicable | Audit | Sync merge into an upstream feature branch; semantic moderator behavior is audited in adjacent rows. |
| `e311c6092` | 2021-08-05 | Alex Gleason | CHANGELOG: moderator abilities | not-applicable | Docs | Upstream changelog-only row; local changelog carries Unfathomably release notes. |
| `3f8fc3459` | 2021-12-19 | Alex Gleason | Merge remote-tracking branch 'origin/develop' into moderators | not-applicable | Audit | Sync merge into an upstream feature branch; semantic moderator behavior is audited in adjacent rows. |
| `05c7a1410` | 2021-12-22 | Alex Gleason | Merge branch 'moderators' into 'develop' | implemented | BE | Merge-only row for role-scoped moderator/staff admin API behavior present locally. |
| `3d41ccc47` | 2021-12-17 | Tusooa Zhu | Allow updating accepted follow activities in Web.ActivityPub.Utils.update_follow_state_for_all/2 | implemented | BE | `update_follow_state_for_all/2` updates both pending and accepted follow activities before reject/accept propagation. |
| `bfd870380` | 2021-12-17 | Tusooa Zhu | Add test to ensure the blocked cease to have follow relationship to the blocker | implemented | BE | `User.block/2` rejects outstanding follows and tears down reverse follows; local tests cover block/follow cleanup paths. |
| `951d1592c` | 2021-12-17 | Tusooa Zhu | Add test to ensure removed follower cease to have relationship with ex-followee | implemented | BE | `FollowingRelationship.update(..., :follow_reject)` deletes the relationship, and accepted Follow activities are marked reject. |
| `538d5ac21` | 2021-12-17 | Tusooa Zhu | Add changelog for https://git.pleroma.social/pleroma/pleroma/-/merge_requests/3568 | not-applicable | Docs | Upstream changelog-only row for accepted-follow reject handling; local changelog uses Unfathomably-facing notes. |
| `8376e83f6` | 2021-12-17 | Tusooa Zhu | Lint | not-applicable | Tests | Upstream lint-only test formatting row; semantic behavior covered by follow-reject rows. |
| `d9746ae4c` | 2021-12-23 | Alex Gleason | Merge branch 'from/develop/tusooa/2802-propagate-reject' into 'develop' | implemented | BE | Merge-only row for accepted-follow Reject/removal behavior implemented in local follow relationship handling. |
| `87871ac85` | 2021-12-23 | Hakaba Hitoyo | Add initial Nodeinfo document | implemented | Docs/BE | `docs/development/API/nodeinfo.md`, NodeInfo controllers, and NodeInfo tests are present locally with Unfathomably metadata extensions. |
| `2caade10d` | 2021-12-23 | Alex Gleason | Merge branch 'add-nodeinfo-doc' into 'develop' | implemented | Docs/BE | Merge-only row for NodeInfo documentation and endpoint coverage present locally. |
| `079afd32d` | 2021-06-23 | Alex Gleason | Enable :warnings_as_errors for CI only | implemented | BE | `mix.exs` enables warnings-as-errors for CI and also supports explicit `WARNINGS_AS_ERRORS`, which is stricter than upstream. |
| `1fa616638` | 2021-12-23 | Alex Gleason | Merge branch 'warnings-as-errors' into 'develop' | implemented | BE | Merge-only row for CI warnings-as-errors behavior present locally. |
| `977595597` | 2021-12-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into remote-follow-api | not-applicable | Audit | Sync merge into an upstream feature branch; semantic changes are audited through their own rows. |
| `b4291bce8` | 2021-12-25 | Alex Gleason | Merge branch 'remote-follow-api' into 'develop' | implemented | BE | Merge-only row; Mastodon-compatible remote interaction/follow API aliases are present locally. |
| `64a4c147b` | 2021-12-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | MastoAPI: accept notify param in follow request | implemented | BE | `MastodonAPI.follow/3` casts `notify` and toggles subscriptions; OpenAPI follow parameters document `notify`. |
| `3892bd353` | 2021-12-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add test for following with subscription | implemented | BE | Local account relationship rendering and follow handling preserve `subscribing`/`notifying` behavior; API schema includes both fields. |
| `c96e52b88` | 2021-12-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add 'notifying' to relationship for compatibility with Mastodon | implemented | BE | `AccountRelationship` schema and `AccountView` include `notifying`, mapped to subscription state for Mastodon compatibility. |
| `b96a58ff2` | 2021-12-25 | Alex Gleason | Merge branch 'account-subscriptions' into 'develop' | implemented | BE | Merge-only row for `notify` follow parameter and `notifying` relationship field. |
| `40414bf17` | 2021-11-21 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | MastoAPI: Add user notes on accounts | implemented | BE | `UserNote`, `user_notes` migration, `/api/v1/accounts/:id/note`, OpenAPI schema, and controller coverage are present locally. |
| `106b5c267` | 2021-11-21 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix a typo | implemented | BE | Account-note typo cleanup is included in the local account note API implementation. |
| `cb76faece` | 2021-11-21 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update test | implemented | Tests | Account note controller/view tests are present locally. |
| `8e040e098` | 2021-11-21 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Lint | not-applicable | Tests | Upstream lint-only account-note row; semantic behavior is covered by local implementation. |
| `588bcbac5` | 2021-11-22 | rinpatch | Apply 2 suggestion(s) to 2 file(s) | implemented | BE | Account note schema/controller refinements are present as part of the local account note implementation. |
| `73609211a` | 2021-12-25 | Alex Gleason | Merge branch 'account-notes' into 'develop' | implemented | BE | Merge-only row for Mastodon-compatible account notes present locally. |
| `db2bf55e9` | 2021-12-25 | Alex Gleason | Merge remote-tracking branch 'origin/develop' into notice-routes | not-applicable | Audit | Sync merge into an upstream feature branch; semantic route changes are audited through their own rows. |
| `2c06eff51` | 2021-12-25 | Alex Gleason | Pleroma.Web.base_url() --> Endpoint.url() | implemented | BE | Local tests and AP URL generation use `Pleroma.Web.Endpoint.url()` rather than legacy `Pleroma.Web.base_url()`. |
| `0eb6e858f` | 2021-12-26 | Alex Gleason | Merge branch 'notice-routes' into 'develop' | implemented | BE | Merge-only row for notice/static FE route compatibility; local static/embed/profile routes already cover this path. |
| `de006443f` | 2021-12-26 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | MastoAPI: Profile directory | implemented | BE | `/api/v1/directory`, `DirectoryController`, `DirectoryOperation`, `last_status_at`, and `profile_directory` feature advertising are present. |
| `913141379` | 2021-12-26 | Alex Gleason | Merge branch 'profile-directory' into 'develop' | implemented | BE | Merge-only row for Mastodon-compatible profile directory support present locally. |
| `cac4ed5eb` | 2021-12-25 | Alex Gleason | GitLab CI: don't retry failed jobs | not-applicable | CI | Upstream GitLab CI policy change; local release validation does not rely on this GitLab retry setting. |
| `2e2fb5f80` | 2021-12-26 | Alex Gleason | Merge branch 'ci-dont-retry' into 'develop' | not-applicable | CI | Merge-only upstream GitLab CI retry policy row. |
| `e8e8d2262` | 2021-12-26 | Lain Soykaf | CI: Start testing erratic test again | not-applicable | CI | Upstream CI test-selection change only; no runtime behavior to backport. |
| `3b8eaadb0` | 2021-12-26 | lain | Merge branch 'erratic' into 'develop' | not-applicable | CI | Merge-only upstream CI test-selection row. |
| `949a53e32` | 2021-12-05 | Alex Gleason | Log Ecto queries > 500ms | not-applicable | BE | Upstream later reverted the slow-query telemetry merge; local telemetry intentionally keeps only connection-pool logging plus targeted janitor/log analysis. |
| `e00995084` | 2021-12-19 | Ivan Tashkinov | Slow queries logging improvements: added EXPLAIN results, listed params, improved stacktrace. | not-applicable | The slow-query telemetry branch was later reverted upstream by `53de3a9d4`; local BE does not attach repo query logging in `Pleroma.Telemetry.Logger`. | Covered by the later upstream revert row. |
| `3e9e7178b` | 2021-12-26 | Ivan Tashkinov | Configurability of slow queries logging ([:pleroma, :telemetry, :slow_queries_logging]). Adjusted log messages truncation to 65 kb (was default: 8 kb). Non-truncated logging of slow query params. | not-applicable | BE | Part of upstream slow-query telemetry series later reverted by `53de3a9d4`; not current upstream behavior. |
| `08c0f09ba` | 2021-12-27 | Ivan Tashkinov | Made slow queries logging disabled by default. | not-applicable | BE | Part of upstream slow-query telemetry series later reverted by `53de3a9d4`; not current upstream behavior. |
| `6e27fc9c1` | 2021-12-27 | Alex Gleason | Merge branch 'log-slow-queries' into 'develop' | not-applicable | BE | Slow-query telemetry merge was later reverted upstream by `53de3a9d4`; no local backport needed. |
| `cd1041c3a` | 2021-12-27 | Alibek Omarov | API: optionally restrict moderators from accessing sensitive data | implemented | Local BE has the stronger role-scoped privilege model: `:moderator_privileges`, `EnsurePrivilegedPlug`, per-route `require_privileged_role_*` pipelines, and controller tests for denied non-privileged moderators. | No further action. |
| `1c223331f` | 2021-12-27 | Alibek Omarov | API: show info about privileged staff in instance metadata | implemented | Local NodeInfo exposes admin and moderator privilege sets, and the Mastodon instance view exposes `privileged_staff`. | No further action. |
| `f66675f34` | 2021-12-27 | Alibek Omarov | API: fix duplicate :get_password_token route | implemented | Local router keeps password reset routes separated from admin `get_password_reset`, with the admin route protected by the user-credential privilege pipeline. | No further action. |
| `f02715c4b` | 2021-12-27 | Alibek Omarov | Fix lint errors | not-applicable | Style-only upstream cleanup; local compiler-warning cleanup is tracked separately and project-owned warnings have already been addressed. | No source backport needed. |
| `479fc5fff` | 2021-12-27 | Alex Gleason | EnsureStaffPrivilegedPlug: add tests | implemented | Local `ensure_privileged_plug_test.exs` covers privileged and non-privileged admins and moderators, and admin controller tests verify route-level privilege denial. | No further action. |
| `a65942802` | 2021-12-27 | Alex Gleason | Merge branch 'restricted-moderators' into 'develop' | implemented | The restricted-moderator feature is present locally as the broader configurable privilege system. | No further action. |
| `d61a5515e` | 2021-12-27 | Alex Gleason | ConnectionPoolTest: tag erratic test | not-applicable | Upstream test tag only; local BE has newer Gun connection-pool regression coverage, including normal-exit release handling. | No source backport needed. |
| `9b5dbd20b` | 2021-12-27 | Alex Gleason | Merge branch 'tag-gun-erratic' into 'develop' | not-applicable | Merge-only test metadata change; local connection-pool coverage is stronger than this old upstream branch. | No source backport needed. |
| `abb62dd88` | 2021-12-15 | Lain Soykaf | Application, dependencies: prepare for finch | implemented | Local BE depends on Finch and `Application` starts `MyFinch` when the configured Tesla adapter is Finch. | No further action. |
| `4e98ba3c3` | 2021-12-15 | Lain Soykaf | Application: Actually start finch if it's needed | implemented | `Pleroma.Application` detects `{Tesla.Adapter.Finch, _}` and starts `Finch.start_link(name: MyFinch)`. | No further action. |
| `6efbd0885` | 2021-12-26 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into finch | not-applicable | Merge-only branch synchronization. | No source backport needed. |
| `5660bee2d` | 2021-12-16 | Mark Felder | Dirty hack to make mediaproxy functional by relying on Hackney for that part | implemented | Local reverse proxy wrapper deliberately routes Finch reverse-proxy/media-proxy work to the Hackney client and includes explicit redirect and URL-encoding hardening. | No further action. |
| `4cf03046f` | 2021-12-26 | Lain Soykaf | Merge branch 'finch' of git.pleroma.social:pleroma/pleroma into finch | not-applicable | Merge-only branch synchronization. | No source backport needed. |
| `7ed225897` | 2021-12-26 | Lain Soykaf | Update changelog | not-applicable | Upstream changelog-only commit. | No source backport needed. |
| `326575d5b` | 2021-12-27 | Alex Gleason | Merge remote-tracking branch 'origin/develop' into finch | not-applicable | Merge-only branch synchronization. | No source backport needed. |
| `fd9260d1b` | 2021-12-27 | Alex Gleason | Merge branch 'finch' into 'develop' | implemented | The Finch preparation, conditional startup, and media-proxy Hackney fallback from the branch are present locally. | No further action. |
| `a3fa98761` | 2021-12-27 | Alex Gleason | AdminAPI: fix duplicated routes | implemented | Local admin routes are split into role-specific privileged scopes, avoiding the duplicated sensitive route definitions this upstream fix removed. | No further action. |
| `264f0fde1` | 2021-12-27 | Alex Gleason | Merge branch 'admin-fix-duplicated-endpoints' into 'develop' | implemented | The deduplicated admin-route structure is present locally. | No further action. |
| `138f5a451` | 2021-12-27 | Alex Gleason | EnsureStaffPrivilegedPlug: don't let non-moderators through | implemented | Local `UserIsStaffPlug` and `EnsurePrivilegedPlug` deny unauthenticated, non-staff, and non-privileged staff paths; tests cover strict denial. | No further action. |
| `52a3f0f08` | 2021-12-28 | Alex Gleason | Merge branch 'ensure-staff-privileged-strict' into 'develop' | implemented | The strict privileged-staff behavior is included in local route plugs and tests. | No further action. |
| `651973204` | 2021-08-25 | Sean King | GET /api/v1/apps endpoint | superseded | The initial endpoint was later moved upstream; local BE implements the final `GET /api/v1/pleroma/apps` endpoint instead. | Covered by row `a14e1c000`. |
| `ba6914f90` | 2021-08-26 | Sean King | Fix formatting in app_operation.ex | not-applicable | Formatting-only interim change; the final local app API spec is present. | No source backport needed. |
| `baa8196fc` | 2021-08-26 | Sean King | Fix API spec, add app schema | implemented | Local BE has app OpenAPI operation modules and app response schema support for the Mastodon and Pleroma app endpoints. | No further action. |
| `eab629109` | 2021-08-28 | Sean King | Require follow and read OAuth scopes for GET /api/v1/apps | implemented | The final local user-app listing endpoint is authenticated, and controller tests cover user-owned app listing. | No further action. |
| `a14e1c000` | 2021-08-28 | Sean King | Move GET /api/v1/apps to GET /api/v1/pleroma/apps | implemented | Local router exposes `GET /api/v1/pleroma/apps` through `PleromaAPI.AppController.index`. | No further action. |
| `d02cf7b0c` | 2021-08-28 | Sean King | Fix lint | not-applicable | Style-only cleanup for the app endpoint branch. | No source backport needed. |
| `33f063204` | 2021-08-28 | Sean King | Add unit test for Pleroma API app controller | implemented | Local `Pleroma.Web.PleromaAPI.AppControllerTest` covers `GET /api/v1/pleroma/apps`. | No further action. |
| `2e59cdd80` | 2021-08-29 | Sean King | Fix aliases sorting | not-applicable | Style-only alias sorting. | No source backport needed. |
| `3117c6099` | 2021-08-29 | Sean King | Make suggested change for create_response | implemented | Local app API operation code already includes the final response helper/schema structure for the endpoint. | No further action. |
| `f5c3d4512` | 2021-12-27 | Alex Gleason | Merge remote-tracking branch 'origin/develop' into apps-api-endpoint | not-applicable | Merge-only branch synchronization. | No source backport needed. |
| `fa35e24a5` | 2021-12-27 | Alex Gleason | Apps: add user_id index | implemented | Local migration `20210818023112_add_user_id_to_apps.exs` creates the `apps.user_id` index. | No further action. |
| `2e4a1c56c` | 2021-12-27 | Alex Gleason | AppController: test creating with and without a user | implemented | Local Mastodon app controller tests cover app creation, and Pleroma app controller tests verify ownership listing. | No further action. |
| `cb2a072e6` | 2021-12-27 | Alex Gleason | Apps: add test for get_user_apps/1 | implemented | Local `Pleroma.Web.OAuth.AppTest` covers `App.get_user_apps/1`. | No further action. |
| `7704a722c` | 2021-12-27 | Alex Gleason | AppController: remove unnecessary `require Logger` | implemented | Local app controllers do not require Logger for this path. | No further action. |
| `5c80d4087` | 2021-12-27 | Alex Gleason | PleromaAPI.AppView: add test | implemented | Local `Pleroma.Web.PleromaAPI.AppViewTest` covers app rendering. | No further action. |
| `de7f84deb` | 2021-12-28 | Alex Gleason | Merge branch 'apps-api-endpoint' into 'develop' | implemented | The complete final app-list endpoint, schema, migration, and tests are present locally. | No further action. |
| `9032d065e` | 2021-12-28 | marcin mikolajczak | wip | not-applicable | Interim account-lookup branch commit with no stable standalone behavior to backport. | Covered by final lookup rows. |
| `f73457996` | 2021-12-28 | marcin mikolajczak | MastoAPI: Add `GET /api/v1/accounts/lookup` | implemented | Local router exposes `GET /api/v1/accounts/lookup`, the controller resolves local names, `acct@domain`, leading-`@` handles, AP IDs, and federated targets, and tests cover those cases. | No further action. |
| `746c9daa6` | 2021-12-28 | marcin mikolajczak | Merge remote-tracking branch 'pleroma/develop' into mastodon-lookup | not-applicable | Merge-only branch synchronization. | No source backport needed. |
| `0dd1caa84` | 2021-12-28 | marcin mikolajczak | AccountController.lookup: skip visibility check | implemented | Local lookup still performs the current upstream outer `User.visible_for/2` gate, then renders with `skip_visibility_check: true` to avoid a second account-view visibility failure. | No further action. |
| `1657db656` | 2021-12-28 | marcin mikolajczak | AccountController.lookup: skip auth | implemented | Local lookup tests use unauthenticated `build_conn()` and return 200 when profile restrictions allow public lookup, while restricted-profile tests return 401 as expected. | No further action. |
| `b5b98f9e1` | 2021-12-28 | Alex Gleason | Merge branch 'mastodon-lookup' into 'develop' | implemented | The full Mastodon account lookup behavior is present locally. | No further action. |
| `5f87472cd` | 2021-12-28 | Alex Gleason | Update CHANGELOG.md | not-applicable | Upstream changelog-only commit. | No source backport needed. |
| `a61ed5c48` | 2021-12-28 | Alex Gleason | Merge branch 'changelog' into 'develop' | not-applicable | Merge-only changelog branch. | No source backport needed. |
| `0c7fb520b` | 2021-12-29 | Ivan Tashkinov | Added index on [:target_id, :relationship_type] to :user_relationships (speeds up `Notification.exclude_blockers/_`). | implemented | Local migration `20211229075801_user_relationships_target_id_relationship_type_index.exs` creates the same `user_relationships` target and relationship-type index. | No further action. |
| `a7bdefc20` | 2021-12-29 | Ivan Tashkinov | `mix format` | not-applicable | Formatting-only follow-up to the user-relationships index branch. | No source backport needed. |
| `84420d943` | 2021-12-29 | lain | Merge branch 'chore/user-relationships-target-id-rel-type-index' into 'develop' | implemented | The branch payload is present locally via the user-relationships target/type index migration. | No further action. |
| `c52390a7d` | 2021-12-26 | Lain Soykaf | CI: Use own package as base | not-applicable | Upstream CI-only change; Unfathomably uses its own build and deployment tooling. | No source backport needed. |
| `ac3b50372` | 2021-12-26 | Lain Soykaf | CI: Fix the broken tasks. | not-applicable | Upstream CI-only change. | No source backport needed. |
| `e25af3f2d` | 2021-12-30 | lain | Merge branch 'more-efficient-ci' into 'develop' | not-applicable | Merge-only CI branch. | No source backport needed. |
| `2ae867842` | 2021-12-31 | Alex Gleason | StreamerTest: tag erratic test | not-applicable | Upstream test tag only; local streaming tests have since been expanded around websocket aggregate feeds. | No source backport needed. |
| `86e692aeb` | 2021-12-31 | Alex Gleason | Merge branch 'erratic-streamer-test' into 'develop' | not-applicable | Merge-only test metadata branch. | No source backport needed. |
| `91ea394cd` | 2022-01-01 | Sean King | Change concurrent_limiter to Hex PM version 0.1.1 | implemented | Local `mix.exs` and `mix.lock` use `concurrent_limiter` 0.1.1 from Hex. | No further action. |
| `c8026fe49` | 2022-01-01 | Alex Gleason | Merge branch 'change/concurrent-limiter-dep' into 'develop' | implemented | The dependency branch payload is present locally. | No further action. |
| `bf995a777` | 2022-01-01 | Sean King | Upgrade web_push_encryption to 0.3.1 | implemented | Local `mix.exs` and `mix.lock` use `web_push_encryption` 0.3.1. | No further action. |
| `a3094b64d` | 2022-01-02 | Alex Gleason | Merge branch 'change/web-push-encryption-dep' into 'develop' | implemented | The web-push dependency update is present locally. | No further action. |
| `e8b340aaa` | 2022-01-07 | Alex Gleason | Docs: fix various Pleroma API endpoints paths, fix MFA response | not-applicable | Upstream documentation-only commit for Pleroma docs; local API behavior and Unfathomably docs are tracked separately. | No source backport needed. |
| `2451d65bd` | 2022-01-07 | Alex Gleason | Merge branch 'api-docs-fixes' into 'develop' | not-applicable | Merge-only documentation branch. | No source backport needed. |
| `fd043b0ab` | 2022-01-10 | rinpatch | Escape unicode RTL overrides in rich media parser tests | not-applicable | Test-fixture source-hygiene change only; no runtime behavior to backport. | Keep public-source hygiene scans in release checks. |
| `753a9b3f3` | 2022-01-10 | Alex Gleason | Merge branch 'fix/rich-media-test-escape-unicrud' into 'develop' | not-applicable | Merge-only test-fixture hygiene branch. | No source backport needed. |
| `4f249b239` | 2022-01-10 | marcin mikolajczak | Merge remote-tracking branch 'origin/develop' into account-endorsements | not-applicable | Merge-only branch synchronization. | No source backport needed. |
| `0f90fd580` | 2022-01-12 | marcin mikolajczak | WIP account endorsements | implemented | Local BE implements account endorsements through the endorsement user relationship, Mastodon and Pleroma endorsement routes, account-view relationship metadata, and controller tests. | No further action. |
| `eedf551ee` | 2022-01-12 | marcin mikolajczak | Add more tests | implemented | Local user, CommonAPI, Mastodon account, and Pleroma account tests cover endorse and unendorse behavior. | No further action. |
| `84dcb55b0` | 2022-01-13 | Alex Gleason | Merge branch 'account-endorsements' into 'develop' | implemented | The account-endorsement feature branch is present locally. | No further action. |
| `a4436bcc3` | 2022-01-14 | Alex Gleason | Merge remote-tracking branch 'origin/stable' into mergeback | not-applicable | Merge-only upstream maintenance. | No source backport needed. |
| `8b5a65899` | 2022-01-14 | rinpatch | Merge branch 'mergeback' into 'develop' | not-applicable | Merge-only upstream maintenance. | No source backport needed. |
| `628435302` | 2022-01-14 | NEETzsche | Add blockers_visible to features list when it's enabled | implemented | Local instance view advertises `blockers_visible` when `:activitypub, :blockers_visible` is enabled, with notification and timeline tests for blocker visibility behavior. | No further action. |
| `71baa713b` | 2022-01-14 | Alex Gleason | Merge branch 'show_blockers_visible' into 'develop' | implemented | The feature advertisement branch payload is present locally. | No further action. |
| `d5eb44e8b` | 2022-01-15 | Alex Gleason | Upgrade Linkify to v0.5.2 | implemented | Local BE uses newer Linkify 0.5.3. | No further action. |
| `590a10af3` | 2020-12-24 | Mary Kate | Adds tests for breaking tag and mention links after text is converted from markdown to html | implemented | Local formatter tests cover markdown, mentions, hashtags, and linkification behavior under the newer Linkify dependency. | No further action. |
| `db90c9e3b` | 2022-01-15 | Alex Gleason | Merge remote-tracking branch 'mkfain/test-for-breaking-markdown' into linkify-0.5.2 | implemented | The test coverage is represented in local formatter/linkify tests. | No further action. |
| `31148c185` | 2022-01-15 | Alex Gleason | FormatterTest: fix nesting in expected output | not-applicable | Test expectation cleanup tied to the Linkify branch; local formatter tests already match current output. | No source backport needed. |
| `cd8f1aac4` | 2022-01-15 | Alex Gleason | CHANGELOG: hashtags markdown fix | not-applicable | Upstream changelog-only commit. | No source backport needed. |
| `39c5ebb1f` | 2022-01-15 | Alex Gleason | mix format | not-applicable | Formatting-only follow-up to the Linkify branch. | No source backport needed. |
| `ecdc81b37` | 2022-01-15 | Alex Gleason | Merge branch 'linkify-0.5.2' into 'develop' | implemented | Local BE is beyond this branch with Linkify 0.5.3 and formatter coverage. | No further action. |
| `790081540` | 2022-01-15 | Hakaba Hitoyo | Update cheatsheet.md. Add `Pleroma.Web.ActivityPub.MRF.KeywordPolicy`. | implemented | `Pleroma.Web.ActivityPub.MRF.KeywordPolicy` exists locally and has dedicated policy tests. | No further action. |
| `72d5e2911` | 2022-01-18 | Alex Gleason | Merge branch 'hakabahitoyo-develop-patch-44025' into 'develop' | implemented | The KeywordPolicy referenced by the documentation branch is present locally. | No further action. |
| `ac434f83c` | 2022-01-15 | Alex Gleason | unit-testing-erratic: allow failure | not-applicable | Upstream CI test-suite metadata only. | No source backport needed. |
| `69b089c89` | 2022-01-18 | Alex Gleason | Merge branch 'erratic-allow-failure' into 'develop' | not-applicable | Merge-only CI metadata branch. | No source backport needed. |
| `1dfb67f1e` | 2022-01-18 | Alex Gleason | Docs: PleromaAPI oauth_tokens endpoints | not-applicable | Upstream documentation-only commit; local OAuth-token behavior was reviewed separately during database cleanup work. | No source backport needed. |
| `70fbd1f09` | 2022-01-18 | Alex Gleason | Merge branch 'document-oauth-tokens' into 'develop' | not-applicable | Merge-only documentation branch. | No source backport needed. |
| `a02cfd7f5` | 2022-01-19 | rinpatch | Add ForceMentionsInContentPolicy | implemented | Local BE includes `Pleroma.Web.ActivityPub.MRF.ForceMentionsInContent` and tests for forcing mentions into content and edit history. | No further action. |
| `787a02c4b` | 2022-01-20 | rinpatch | Merge branch 'feat/force-mentions-mrf' into 'develop' | implemented | The ForceMentionsInContent MRF branch payload is present locally. | No further action. |
| `9faac1094` | 2022-01-19 | Tusooa Zhu | Add glitch-lily to clients.md | not-applicable | Upstream documentation-only clients list update. | No source backport needed. |
| `560bcd58a` | 2022-01-20 | Alex Gleason | Merge branch 'from/develop/tusooa/add-glitch-lily' into 'develop' | not-applicable | Merge-only documentation branch. | No source backport needed. |
| `88c21b928` | 2022-01-20 | marcin mikolajczak | Support private pinned posts from Mastodon | implemented | Local ActivityPub pinned-object fetching supports private pinned posts and has ActivityPub tests for remote featured collections. | No further action. |
| `00523bdf5` | 2022-01-20 | Alex Gleason | Test pinned private statuses in AccountController | implemented | Local Mastodon account controller tests include `view pinned private statuses`. | No further action. |
| `6ffe43af7` | 2022-01-20 | Alex Gleason | Merge branch 'private-pins' into 'develop' | implemented | Private pinned-post support and tests are present locally. | No further action. |
| `f5d4ef50b` | 2022-01-22 | Alex Gleason | FilterTest: tag erratic test | not-applicable | Upstream test tag only. | No source backport needed. |
| `78c6aeee1` | 2022-01-22 | Alex Gleason | Merge branch 'erratic-filter-test' into 'develop' | not-applicable | Merge-only test metadata branch. | No source backport needed. |
| `832828961` | 2022-01-22 | Finn Behrens | Add autocompelete values suggested by Apple | implemented | Local OAuth and remote-follow templates include the one-time-code, username, email, and password autocomplete hints; this pass added the missing OAuth authorization login hints. | Deployed with the current BE documentation/source update. |
| `263b42a73` | 2022-01-22 | Alex Gleason | Merge branch 'apple_autofill_suggestions' into 'develop' | implemented | The browser autocomplete hint branch payload is present locally. | No further action. |
| `7a015b1fe` | 2022-01-22 | NEETzsche | Make test less erratic by adding five second tolerance | not-applicable | Upstream test timing tolerance only. | No source backport needed. |
| `9983799cc` | 2022-01-22 | Alex Gleason | Merge branch 'less_erratic_expiration_test' into 'develop' | not-applicable | Merge-only test timing branch. | No source backport needed. |
| `1dba3bc4d` | 2022-01-23 | marcin mikolajczak | Preserve order of mentioned users | implemented | Local `User.get_ap_ids_by_nicknames/1` orders by `array_position(?, ?)` against the requested nickname list. | No further action. |
| `75c4fefb1` | 2022-01-23 | marcin mikolajczak | Add a test | implemented | Local `UserTest` asserts `get_ap_ids_by_nicknames/1` returns AP IDs in caller-specified order. | No further action. |
| `7b87cac6c` | 2022-01-23 | Alex Gleason | Merge branch 'preserve-mentions-order' into 'develop' | implemented | The mention-order fix and regression coverage are present locally. | No further action. |
| `53de3a9d4` | 2022-01-24 | Alex Gleason | Revert "Merge branch 'log-slow-queries' into 'develop'" | implemented | Local BE does not attach the reverted slow-query telemetry logger; the earlier slow-query rows are marked not applicable because this upstream revert is the final state. | No further action. |
| `19d557c87` | 2022-01-24 | Alex Gleason | Merge branch 'revert-6e27fc9c' into 'develop' | implemented | The final reverted slow-query state matches local BE. | No further action. |
| `b108b0565` | 2022-01-18 | marcin mikolajczak | Birth dates, birthday reminders API, allow instance admins to require minimum age | implemented | Local BE has `birthday` and `show_birthday`, birthday-required and birthday-min-age configuration, `/api/v1/pleroma/birthdays`, ActivityPub `vcard:bday`, and tests for registration and birthday reminders. | No further action. |
| `397f67fef` | 2022-01-18 | marcin mikolajczak | Format code, expose instance configuration related to birth dates | implemented | Local Mastodon instance view exposes `birthday_required` and `birthday_min_age`. | No further action. |
| `dfb280853` | 2022-01-18 | marcin mikolajczak | Birth dates: Add tests | implemented | Local tests cover birthday registration validation, update_credentials birthday fields, birthday visibility, and birthday reminders. | No further action. |
| `c180f9276` | 2022-01-19 | marcin mikolajczak | check if remote bday is valid | implemented | Local ActivityPub user fetch handles remote birthday data and tests Misskey birthday parsing. | No further action. |
| `74cf0f035` | 2022-01-19 | marcin mikolajczak | Update changelog | not-applicable | Upstream changelog-only birthday branch commit. | No source backport needed. |
| `66e8c6f90` | 2022-01-22 | Alex Gleason | Birthdays: birth_date --> birthday | implemented | Local schema, API, ActivityPub, and tests use the final `birthday` naming. | No further action. |
| `98ce239eb` | 2022-01-22 | Alex Gleason | Update description.exs | implemented | Local configuration descriptions expose the birthday-required and minimum-age settings. | No further action. |
| `aaa9314f4` | 2022-01-22 | Alex Gleason | Merge remote-tracking branch 'origin/develop' into birth-dates | not-applicable | Merge-only branch synchronization. | No source backport needed. |
| `0266bc3c9` | 2022-01-23 | marcin mikolajczak | Birthdays: hide_birthday -> show_birthday | implemented | Local BE uses the final `show_birthday` field and exposes it in account source data and ActivityPub rendering. | No further action. |
| `e3d394eef` | 2022-01-23 | marcin mikolajczak | Birthdays: Fix tests, add test for misskey | implemented | Local ActivityPub tests cover Misskey birthday import. | No further action. |
| `61bae9a40` | 2022-01-23 | marcin mikolajczak | Create index for `show_birthday` | implemented | Local migration `20220116183110_add_birthday_to_users.exs` creates the `users.show_birthday` index. | No further action. |
| `249fe88d1` | 2022-01-25 | marcin mikolajczak | Birthdays: users_birthday_month_day_index | implemented | Local migration `20220125104429_add_birthday_month_day_index_to_users.exs` creates the expression index for birthday month and day lookups. | No further action. |
| `dd7977bb6` | 2022-01-25 | Alex Gleason | Merge branch 'birth-dates' into 'develop' | implemented | The birthday feature branch is present locally. | No further action. |
| `c1ae35ff2` | 2022-01-25 | marcin mikolajczak | Fix show_birthday | implemented | Local account view only shows birthday to the owner or when `show_birthday` is true. | No further action. |
| `ab12a05a4` | 2022-01-25 | marcin mikolajczak | AccountView: Add test for show_birthday | implemented | Local account-view tests cover hidden and visible birthday rendering. | No further action. |
| `99e9c2c66` | 2022-01-25 | Alex Gleason | Merge branch 'birth-dates' into 'develop' | implemented | The final birthday visibility fixes are present locally. | No further action. |
| `1bbc701a3` | 2022-01-24 | Alex Gleason | ForceMentionsInContent: use `to` instead of `tag` | implemented | Local `ForceMentionsInContent` builds forced mentions from addressing data and reply context, matching the final policy direction. | No further action. |
| `d5644a52a` | 2022-01-24 | Alex Gleason | ForceMentionsInContent: wrap inline mentions with span tag | implemented | Local ForceMentionsInContent tests cover rendered inline mention output, and the scrubber permits the resulting span wrapping. | No further action. |
| `c5a20c80c` | 2022-01-24 | Alex Gleason | ForceMentionsInContent: simplify finding users | implemented | Local ForceMentionsInContent has the simplified user lookup flow and dedicated policy tests. | No further action. |
| `267184b70` | 2022-01-24 | Alex Gleason | ForceMentionsInContentTest: return mentions in a not terrible format | implemented | Local ForceMentionsInContent tests cover mention output in the current expected format. | No further action. |
| `65b4d2ce8` | 2022-01-25 | Alex Gleason | ForceMentionsInContent: fix order of mentions | implemented | Local ForceMentionsInContent tests cover ordered mention insertion. | No further action. |
| `0f4e0e667` | 2022-01-25 | Alex Gleason | Merge branch 'recipients-inline' into 'develop' | implemented | The ForceMentionsInContent recipient ordering branch is present locally. | No further action. |
| `0604b0dd0` | 2022-01-25 | Alex Gleason | ForceMentionsInContent: don't mention self | implemented | Local ForceMentionsInContent policy and tests cover avoiding self-mentions. | No further action. |
| `8951be771` | 2022-01-25 | Alex Gleason | Merge branch 'inline-mention-self' into 'develop' | implemented | The no-self-mention ForceMentions branch is present locally. | No further action. |
| `a4de79ced` | 2022-01-26 | bot | ForceBotUnlistedPolicy: fix to stop unlisting my posts >:( | implemented | Local `ForceBotUnlistedPolicy` exists and has tests covering which bot posts are unlisted or left alone. | No further action. |
| `2bab9dd17` | 2022-01-26 | Alex Gleason | Merge branch 'fix-bot-policy' into 'develop' | implemented | The ForceBotUnlistedPolicy fix is present locally. | No further action. |
| `27cb3d627` | 2022-01-26 | Alex Gleason | ForceMentionsInContent: don't apply it to top-level posts | implemented | Local ForceMentionsInContent applies to replies with `inReplyTo` and leaves top-level posts alone. | No further action. |
| `a146f6aca` | 2022-01-27 | Alex Gleason | Merge branch 'mentions-mrf-replies-only' into 'develop' | implemented | The replies-only ForceMentions behavior is present locally. | No further action. |
| `3bf257171` | 2022-01-27 | Alex Gleason | ForceMentionsInContent: improve display of Markdown posts | implemented | Local ForceMentionsInContent tests cover Markdown-style post output. | No further action. |
| `64944c164` | 2022-01-28 | Alex Gleason | Merge branch 'mention-mrf-md' into 'develop' | implemented | The Markdown display refinement is present locally. | No further action. |
| `f8f2a1775` | 2022-02-01 | marcin mikolajczak | Birthdays: Fix outgoing federation of birth dates | implemented | Local ActivityPub user rendering emits `vcard:bday` only when birthday sharing is enabled. | No further action. |
| `de99fd780` | 2022-02-01 | Alex Gleason | Merge branch 'birth-dates' into 'develop' | implemented | The final birthday federation fix is present locally. | No further action. |
| `61dfeca1c` | 2022-02-02 | Alex Gleason | Test that a Note from Roadhouse validates | implemented | Local article/note/page validator tests include the Roadhouse Note fixture. | No further action. |
| `5a4e3aa71` | 2022-02-02 | Alex Gleason | Test that a Create/Note from Roadhouse validates | implemented | Local create-generic validator tests include Roadhouse Create/Note validation. | No further action. |
| `2d7797630` | 2022-02-02 | Alex Gleason | Add tests for mismatched context in replies | implemented | Local create-generic validator and transmogrifier tests cover mismatched reply context repair. | No further action. |
| `bd81af731` | 2022-02-02 | Alex Gleason | Tag erratic test | not-applicable | Upstream erratic-test tag only; no production runtime behavior. | No code action. |
| `71c80204c` | 2022-02-02 | Alex Gleason | Merge branch 'roadhouse' into 'develop' | not-applicable | Merge-only row for upstream test tag churn. | No code action. |
| `d1cc9e4ea` | 2022-02-02 | Haelwenn (lanodan) Monnier | Fix tests matching on "warn" | not-applicable | Upstream test expectation cleanup only. | No code action. |
| `7c044a184` | 2022-02-02 | Alex Gleason | FilterControllerTest: tag erratic test | not-applicable | Upstream erratic-test tag only. | No code action. |
| `60deddb7e` | 2022-02-02 | Alex Gleason | Merge branch 'fix-tests-warn' into 'develop' | not-applicable | Merge-only row for upstream test expectation cleanup. | No code action. |
| `e473bcf7a` | 2022-02-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Max media attachment count | implemented | Local instance config exposes `max_media_attachments`, validates attachment count in ActivityDraft, and advertises the limit in instance views. | No recheck. |
| `fa8e2ffa3` | 2022-02-06 | Alex Gleason | Merge branch 'max_media_attachments' into 'develop' | implemented | Merge-only row for the max media attachment count feature. | No recheck. |
| `061cb749c` | 2022-02-21 | Sam Therapy | Add unicode 14 support and add a test with a unicode 14 emoji | implemented | Unicode emoji data includes the updated emoji test data, and emoji handling uses the local emoji data file. | No recheck. |
| `d91e9cee0` | 2022-02-21 | lain | Merge branch 'unicode-14.0-backend' into 'develop' | implemented | Merge-only row for Unicode 14 emoji data support. | No recheck. |
| `8ef1d8b56` | 2021-12-26 | Sean King | Revert "Merge branch 'notice-routes' into 'develop'" | superseded | Temporary upstream notice-route revert branch churn; local final router retains notice compatibility routes where needed. | No action. |
| `ffeae7ef2` | 2021-12-29 | Sean King | Fix merge conflict in CHANGELOG.md | not-applicable | Upstream changelog conflict resolution only. | No code action. |
| `dafcf896d` | 2021-12-30 | Sean King | Merge more stuff from upstream develop branch | superseded | Upstream branch-merge churn around notice routes; local final route behavior is represented directly by later rows. | No action. |
| `ee05abe05` | 2022-02-26 | HJ | Merge branch 'revert/notice-routes' into 'develop' | superseded | Temporary upstream revert branch merge; local final router state is reviewed against the final restored behavior. | No action. |
| `9c52a496f` | 2022-03-01 | feld | Revert "Merge branch 'revert/notice-routes' into 'develop'" | implemented | Notice compatibility routes are present in the fallback routing section for frontend/static compatibility. | No recheck. |
| `0b686c6e5` | 2022-03-01 | feld | Merge branch 'revert-ee05abe0' into 'develop' | implemented | Merge-only row for restored notice route compatibility. | No recheck. |
| `17aa3644b` | 2022-02-25 | Sean King | Copyright bump for 2022 | not-applicable | Upstream copyright-year bump only; Unfathomably carries its own public-facing metadata and notices. | No code action. |
| `ee32e36b0` | 2022-03-06 | Haelwenn | Merge branch 'copyright-bump-2022' into 'develop' | not-applicable | Merge-only row for upstream copyright-year bump. | No code action. |
| `6ba93c2cb` | 2022-02-22 | Ilja | Fix test get_user_apps/1 | not-applicable | OAuth app test fix only; no production runtime behavior. | No code action. |
| `4458db320` | 2022-03-06 | Haelwenn | Merge branch 'fix_test_get_user_apps' into 'develop' | not-applicable | Merge-only row for upstream OAuth app test fix. | No code action. |
| `56197192b` | 2022-02-25 | Haelwenn (lanodan) Monnier | mix: Check .git presence | implemented | Mix version generation checks both `git` availability and `.git` presence before running git commands. | No recheck. |
| `2db640632` | 2022-03-17 | Haelwenn | Merge branch 'bugfix/mix-dotgit' into 'develop' | implemented | Merge-only row for `.git`-safe Mix version generation. | No recheck. |
| `89667189b` | 2022-03-06 | Ilja | Delete report notifs when demoting from superuser | implemented | User updates track prior report-management privilege and destroy `pleroma:report` notifications after demotion. | No recheck. |
| `cdc5bbe83` | 2022-03-07 | Ilja | After code review | implemented | Code-review follow-up for report-notification cleanup is represented in the current concise helper path. | No recheck. |
| `b76340511` | 2022-03-20 | Haelwenn | Merge branch 'delete_report_notifs_when_demoting_from_superuser' into 'develop' | implemented | Merge-only row for deleting report notifications when a user loses report-management privileges. | No recheck. |
| `9b69ccb35` | 2022-03-06 | sleepycrow | Update Caddyfile to Caddy v2 | deferred | Caddy example update is useful documentation, but needs Unfathomably-specific adaptation rather than direct Pleroma import. | Revisit in documentation hardening. |
| `e63d49d23` | 2022-03-20 | Haelwenn | Merge branch 'caddyfile-v2' into 'develop' | deferred | Merge-only row for Caddy v2 example documentation. | Revisit in documentation hardening. |
| `0fd3695b9` | 2022-02-21 | Tusooa Zhu | Prefer userLanguage cookie over Accept-Language header in detecting locale | implemented | SetLocalePlug reads the `userLanguage` frontend cookie before falling back to Accept-Language and has tests for cookie priority/fallback. | No recheck. |
| `a86710743` | 2022-02-21 | Tusooa Zhu | Make remote follow pages translatable | implemented | Remote-follow and subscribe templates use static_pages Gettext strings through the Twitter API views. | No recheck. |
| `2fa1ca84e` | 2022-02-21 | Tusooa Zhu | Extract translatable text | implemented | Translatable static-page strings are extracted through the current Gettext/static_pages catalog path. | No recheck. |
| `9f4c5743e` | 2022-02-21 | Tusooa Zhu | Make lint happy | not-applicable | Upstream lint-only follow-up for static page translations. | No code action. |
| `1edbda39e` | 2022-02-28 | Tusooa Zhu | Make password reset pages translatable | implemented | Password reset templates use static_pages Gettext strings and the password view imports Gettext. | No recheck. |
| `0cc655771` | 2022-02-28 | Tusooa Zhu | Make tag feed translatable | implemented | Tag feed Atom/RSS templates use static_pages Gettext strings for descriptions. | No recheck. |
| `f63d9b783` | 2022-02-28 | Tusooa Zhu | Use proper lang attributes in htmls | implemented | HTML and email layouts set lang through `Pleroma.Web.Gettext.language_tag/0`. | No recheck. |
| `50a316cd6` | 2022-02-28 | Tusooa Zhu | Make oauth pages translatable | implemented | OAuth templates use static_pages Gettext strings and OAuth views import Gettext. | No recheck. |
| `cadca083e` | 2022-02-28 | Tusooa Zhu | Make mfa pages translatable | implemented | MFA templates use static_pages Gettext strings and MFA view imports Gettext. | No recheck. |
| `fdbf9b06e` | 2022-02-28 | Tusooa Zhu | Fix tests | not-applicable | Upstream translation test-only fix. | No code action. |
| `32e4aa42d` | 2022-03-01 | Tusooa Zhu | Make static fe translatable | implemented | StaticFE templates use Gettext/static_pages strings for user-facing labels. | No recheck. |
| `1deab33fb` | 2022-03-01 | Tusooa Zhu | Make mail and mailer translatable | implemented | Mailer subscription and digest templates use static_pages Gettext strings through mail views. | No recheck. |
| `8b0c2890f` | 2022-03-01 | Tusooa Zhu | Fix digest test | not-applicable | Upstream digest email test-only fix. | No code action. |
| `af82f09ce` | 2022-03-01 | Tusooa Zhu | Make all emails translatable | implemented | User email subjects and bodies use Gettext/static_pages strings throughout `Pleroma.Emails.UserEmail`. | No recheck. |
| `0149ea453` | 2022-03-01 | Tusooa Zhu | Send emails i18n'd using backend-stored user language | implemented | Users have a `language` field and UserEmail renders inside `Gettext.with_locale_or_default user.language`. | No recheck. |
| `396f036b1` | 2022-03-02 | Tusooa Zhu | Allow update_credentials to update User.language | implemented | Account update_credentials maps request `language` into normalized User.language updates. | No recheck. |
| `e644f8dea` | 2022-03-02 | Tusooa Zhu | Allow user to register with custom language | implemented | Registration accepts a custom language and normalizes it through the Gettext locale helpers. | No recheck. |
| `5e3888708` | 2022-03-02 | Tusooa Zhu | Document API addition | not-applicable | Upstream API-doc-only addition; local API docs/changelog are maintained separately for Unfathomably. | No code action. |
| `1a917cfee` | 2022-03-02 | Tusooa Zhu | Add changelog | not-applicable | Upstream changelog-only entry for language support. | No code action. |
| `8de573b04` | 2022-03-02 | Tusooa Zhu | Fallback to a variant if the language in general is not supported | implemented | Gettext/SetLocalePlug fallback helpers can fall back from a general language to supported variants. | No recheck. |
| `bc59da96c` | 2022-03-02 | Tusooa Zhu | Add test for fallbacking to a general language | implemented | Locale fallback behavior is represented by current SetLocalePlug/Gettext tests for supported variants. | No recheck. |
| `d3f3f30c6` | 2022-03-02 | Tusooa Zhu | Make lint happy | not-applicable | Upstream lint-only follow-up for locale fallback support. | No code action. |
| `7ea330b4f` | 2022-03-03 | Tusooa Zhu | Support multiple locales formally | implemented | Gettext supports multiple locales and SetLocalePlug assigns both the selected locale and fallback locale list. | No recheck. |
| `aca11fb70` | 2022-03-03 | Tusooa Zhu | Support multiple locales from userLanguage cookie | implemented | SetLocalePlug parses multiple locales from the `userLanguage` cookie before Accept-Language fallback. | No recheck. |
| `cd42e2bed` | 2022-03-03 | Tusooa Zhu | Lint | not-applicable | Upstream lint-only follow-up for multiple-locale support. | No code action. |
| `79ccb6b99` | 2022-03-06 | Tusooa Zhu | Support fallbacking to other languages | implemented | Gettext fallbacking to other languages is present through `ensure_fallbacks/1`, locale normalization, and multi-locale tests. | No recheck. |
| `d7c53da77` | 2022-03-20 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/translate-pages' into 'develop' | implemented | Translation-pages merge is covered by the local Gettext module, SetLocalePlug multi-locale handling, user language storage, translated email/static/OAuth/password/remote-follow templates, and feed language tags. | No recheck. |
| `5f37db330` | 2022-04-05 | Ilja | Fix eratic test for POST /api/pleroma/admin/reports/:id/notes | not-applicable | Upstream report-note erratic-test fix only changed controller test ordering/expectations; no runtime behavior to backport. | No code action. |
| `a5d7e98de` | 2022-04-05 | Haelwenn | Merge branch 'fix_eratic_test_for_report_notes' into 'develop' | not-applicable | Merge-only wrapper for the report-note test fix. | No code action. |
| `be08d9305` | 2022-04-17 | Tusooa Zhu | Fix incorrect fallback when English is set to first language | implemented | Local Gettext fallback handling already keeps English-first fallback behavior through normalize/fallback locale helpers and multi-locale support. | No recheck. |
| `8517bc18a` | 2022-04-18 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/fix-en-fallback' into 'develop' | implemented | Merge-only wrapper for the English-first fallback fix already covered by local Gettext fallback handling. | No recheck. |
| `c3b2b71ea` | 2022-05-06 | Ilja | update sweet_xml [Security] | superseded | Local dependencies already use sweet_xml 0.7.5, newer than the upstream security bump being audited. | No dependency action. |
| `e2d24eda5` | 2022-05-06 | Tusooa Zhu | Allow to skip cache in Cache plug | implemented | Cache plug honors conn.assigns[:skip_cache] before writing the response cache. | No recheck. |
| `57c030a0a` | 2022-05-06 | Tusooa Zhu | Skip cache when /objects or /activities is authenticated | implemented | ActivityPub object, replies, and activity rendering call maybe_skip_cache/2 when an authenticated user is present. | No recheck. |
| `f9943b206` | 2022-05-06 | Haelwenn (lanodan) Monnier | mix: Bump to 2.4.52 for 2.4.3 mergeback | not-applicable | Version bump for upstream 2.4.52/2.4.3 mergeback does not map to Unfathomably release metadata. | No code action. |
| `214ef7ff7` | 2022-05-06 | Haelwenn | Merge branch 'security/2.4.3-develop' into 'develop' | implemented | Security merge content is covered: authenticated ActivityPub reads skip cache and sweet_xml is already newer than the patched upstream dependency. | No recheck. |
| `a8093732b` | 2022-05-08 | Ilja | Also use actor_type to determine if an account is a bot in antiFollowbotPolicy | implemented | AntiFollowbotPolicy scores Service actor_type as bot-like in addition to nickname/display name scoring. | No recheck. |
| `4605efe27` | 2022-05-08 | Haelwenn | Merge branch 'improve_anti_followbot_policy' into 'develop' | implemented | Merge-only wrapper for the AntiFollowbot actor_type improvement already present locally. | No recheck. |
| `a74ce2d77` | 2022-05-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | StealEmojiPolicy: fix String rejected_shortcodes | implemented | StealEmojiPolicy distinguishes binary shortcode rejects from Regex patterns with shortcode_matches?/2. | No recheck. |
| `bdca5f5d6` | 2022-05-19 | lain | Merge branch 'fix/mrf-steal-emoji-regex' into 'develop' | implemented | Merge-only wrapper for the StealEmojiPolicy string rejected_shortcodes fix already present locally. | No recheck. |
| `7977dd6ac` | 2022-05-12 | lewdthewides | Instruct users to run 'git pull' as the pleroma user | superseded | Upstream source-install wording is superseded by Unfathomably deployment/promotion tooling and source-install documentation, which avoid running upgrades as the wrong user. | No code action. |
| `7466136ad` | 2022-05-22 | Haelwenn | Merge branch 'lewdthewides-develop-patch-48691' into 'develop' | superseded | Merge-only wrapper for updating docs; local Unfathomably upgrade docs supersede the Pleroma source-install wording. | No code action. |
| `5b19543f0` | 2022-06-21 | Ilja | Add new setting and Plug to allow for privilege settings for staff | implemented | Local config exposes admin_privileges and moderator_privileges and router pipelines use EnsurePrivilegedPlug for staff permission gates. | No recheck. |
| `9f6c36475` | 2022-06-21 | Ilja | Add privilege :user_deletion | implemented | Local modern privilege set includes :users_delete and routes protected by the corresponding privileged pipeline. | No recheck. |
| `8a9144ca8` | 2022-06-21 | Ilja | Add priviledges for :user_credentials | implemented | Local modern privilege set includes :users_manage_credentials for credential and password-reset administrative operations. | No recheck. |
| `b1ff5241c` | 2022-06-21 | Ilja | Add priviledges for :statuses_read | implemented | Upstream statuses_read privilege is superseded by local :messages_read naming and privileged routing for status/message read surfaces. | No recheck. |
| `5a65e2dac` | 2022-06-21 | Ilja | Remove privileged_staff | implemented | Local authorization uses explicit admin/moderator privilege lists and EnsurePrivilegedPlug rather than a privileged_staff shortcut. | No recheck. |
| `cb60cc4e0` | 2022-06-21 | Ilja | Add privileges for :user_tag | implemented | Local modern privilege set includes :users_manage_tags and related admin user-tag routing. | No recheck. |
| `e102d25d2` | 2022-06-21 | Ilja | Add privileges for :user_activation | implemented | Local modern privilege set includes :users_manage_activation_state and User.visible_for/2 exposes deactivated accounts only to privileged users. | No recheck. |
| `14e697a64` | 2022-06-21 | Ilja | Add privileges for :user_invite | implemented | Local modern privilege set includes :users_manage_invites and protected invite administration routes. | No recheck. |
| `3f26f1b30` | 2022-06-21 | Ilja | Add privileges for :report_handle | implemented | Local modern privilege set includes :reports_manage_reports, report notification creation uses all_users_with_privilege/1, and report access is routed through privileged pipelines. | No recheck. |
| `cbb26262a` | 2022-06-21 | Ilja | Add privileges for :user_read | implemented | Local modern privilege set includes :users_read and protected user read/search routes. | No recheck. |
| `4cb0dbb5d` | 2022-06-21 | Ilja | Mark relevant tests synchronous | not-applicable | Upstream test synchronization change only adjusted ExUnit async flags around mutable privilege config. | No code action. |
| `34a98990d` | 2022-06-21 | Ilja | last off :statuses_read | implemented | The final statuses_read cleanup is covered by local modern :messages_read privilege naming and route protection. | No recheck. |
| `0ee8f3325` | 2022-06-21 | Ilja | Add privilige :status_delete | implemented | Local modern privilege set includes :messages_delete and delete/status moderation routes use privileged authorization. | No recheck. |
| `ecd42a2ce` | 2022-06-21 | Ilja | Add privilige :emoji_management | implemented | Local modern privilege set includes :emoji_manage_emoji and emoji admin routes are privilege protected. | No recheck. |
| `c842e6267` | 2022-06-21 | Ilja | Add last priviliges | implemented | Local modern privilege set includes :instances_delete, :moderation_log_read, :announcements_manage_announcements, and :statistics_read. | No recheck. |
| `9da81f41c` | 2022-06-21 | Ilja | Fix warning during test user_test.exs | not-applicable | Upstream warning cleanup only changed tests. | No code action. |
| `7adfc2e0f` | 2022-06-21 | Ilja | Add Pleroma.User.privileged?/2 | implemented | Pleroma.User.privileged?/2 exists locally and checks role-specific configured privilege lists. | No recheck. |
| `7cf473c50` | 2022-06-21 | Ilja | delete statusses is now privileged by :status_delete | implemented | Status deletion authorization is covered by local privileged delete paths using modern privilege names. | No recheck. |
| `bb61cfee8` | 2022-06-21 | Ilja | Validator for deleting statusses is now done with priviledge instead of superuser | implemented | ActivityPub delete validation and CommonAPI deletion authorization use privileged checks rather than old superuser-only checks. | No recheck. |
| `edf0013ff` | 2022-06-21 | Ilja | User.visible_for/2 | implemented | User.visible_for/2 exists locally and accounts for privileged activation-state visibility. | No recheck. |
| `e45faddb3` | 2022-06-21 | Ilja | Revert "Delete report notifs when demoting from superuser" | superseded | Upstream reverted eager deletion of report notifications after privilege loss; local keeps a stricter cleanup path but also has privilege-based report routing and notification creation. | Keep local stricter cleanup unless a regression is observed. |
| `eab13fed3` | 2022-06-21 | Ilja | Hide pleroma:report for non-privileged users | implemented | Notification retrieval hides report notifications from non-privileged users through report privilege checks in the Mastodon notification path. | No recheck. |
| `a1c8aa472` | 2022-06-21 | Ilja | Remove function superuser? | implemented | Old superuser?/1 behavior is superseded by privileged?/2 and explicit privilege lists. | No recheck. |
| `34adea8d2` | 2022-06-21 | Ilja | Add Pleroma.User.all_users_with_privilege/1 | implemented | Pleroma.User.all_users_with_privilege/1 exists locally and builds an is_privileged query. | No recheck. |
| `e21ef5aef` | 2022-06-21 | Ilja | report notifications for privileged users | implemented | Report notifications are generated for users with :reports_manage_reports rather than all staff indiscriminately. | No recheck. |
| `143ea7b80` | 2022-06-21 | Ilja | Add deactivated status for privileged users | implemented | Account rendering exposes pleroma.deactivated only to users privileged for :users_manage_activation_state. | No recheck. |
| `211e561e2` | 2022-06-21 | Ilja | Show privileges to FE | implemented | Account rendering includes pleroma.privileges for the authenticated account owner using User.privileges/1. | No recheck. |
| `4e4eb8174` | 2022-06-21 | Ilja | Add nodes and privileges to nodeinfo | implemented | NodeInfo metadata exposes admin and moderator privilege lists under roles. | No recheck. |
| `37fdf148b` | 2022-07-01 | Ilja | Rename privilege tags | implemented | Local code uses the renamed modern privilege tags such as :users_read, :messages_read, :reports_manage_reports, and :emoji_manage_emoji. | No recheck. |
| `0d697bc15` | 2022-07-01 | Ilja | Add docs and CHANGELOG entries | implemented | Privilege documentation exists in local config description and cheatsheet material, with Unfathomably naming. | No recheck. |
| `c0e4b1b3e` | 2022-07-02 | Ilja | Fix typo's | implemented | EnsurePrivilegedPlug and privilege docs already use corrected wording and modern names. | No recheck. |
| `51f87ba30` | 2022-07-02 | Ilja | Change order of privilege tags to make more sense | implemented | Config and descriptions order privilege tags in the modern grouped order. | No recheck. |
| `15748fd30` | 2022-07-02 | Ilja | Add better explanation in the Cheatsheet about what each tag does | implemented | Privilege descriptions are documented in config/description.exs and the local cheatsheet. | No recheck. |
| `42d4bd3a5` | 2022-07-02 | Ilja | Rename pipelines and add forgotten tags | implemented | Router pipelines use renamed modern privilege pipelines and include the expected staff tags. | No recheck. |
| `6ef38c652` | 2022-07-05 | Ilja | Improve tests after code review | not-applicable | Upstream post-review cleanup only reduced duplicated tests around privilege queries. | No code action. |
| `a15877436` | 2022-05-31 | Pierre-Louis Bonicoli | hackney adapter helper & reverse proxy client: enable TLSv1.3 | implemented | Local Hackney adapter and reverse-proxy client no longer pin legacy TLS versions; newer Hackney dependency handles TLSv1.3-capable negotiation. | No recheck. |
| `6f23fc8e0` | 2022-05-31 | Pierre-Louis Bonicoli | Add tlsv1.3 to suggestions | superseded | Modern Hackney/OTP dependency state no longer carries the old TLS-version suggestion gap; no runtime pin blocks TLS 1.3. | No code backport needed. |
| `75f912c63` | 2022-06-06 | lain | Merge branch 'hackney_reenable_TLSv1.3' into 'develop' | superseded | Merge wrapper for the TLS 1.3 suggestion branch; covered by the current dependency/config state. | No code backport needed. |
| `d7af67012` | 2022-03-08 | Tusooa Zhu | Implement first pass of announcement admin api | implemented | Announcement model, admin controller/view/API spec, router routes, migration, and controller tests are present locally. | No recheck. |
| `c867d2325` | 2022-03-08 | Tusooa Zhu | Fill properties of announcements from Mastodon API spec | implemented | Announcement JSON includes Mastodon-compatible properties through `Announcement.render_json/2` and the schema/view path. | No recheck. |
| `5169ad8f1` | 2022-03-08 | Tusooa Zhu | Implement announcement read relationships | implemented | Announcement read relationships are implemented with mark_read/mark_unread helpers and Mastodon dismiss/read rendering. | No recheck. |
| `aa1fff279` | 2022-03-08 | Tusooa Zhu | Implement GET /api/v1/announcements/:id | superseded | Upstream briefly added GET `/api/v1/announcements/:id`, but the later final Mastodon-compatible route removes it; local Mastodon routes expose index and dismiss only. | No action. |
| `2b39b36e4` | 2022-03-08 | Tusooa Zhu | Implement POST /api/v1/announcements/:id/dismiss | implemented | Mastodon `POST /api/v1/announcements/:id/dismiss` marks announcements read for the authenticated user. | No recheck. |
| `009817c9e` | 2022-03-08 | Tusooa Zhu | Correct docstring for AnnouncementController.show | implemented | Controller docstring/final endpoint shape matches the local Mastodon announcement controller. | No recheck. |
| `fcf3c9057` | 2022-03-08 | Tusooa Zhu | Implement visibility filtering for announcements | implemented | Announcement visibility filtering uses starts_at/ends_at windows in `Announcement.list_all_visible_when/1` and Mastodon API lists only visible announcements. | No recheck. |
| `cf8334dbc` | 2022-03-08 | Tusooa Zhu | Add starts_at, ends_at and all_day parameters | implemented | Admin create/update accepts `starts_at`, `ends_at`, and `all_day`; rendering exposes those fields. | No recheck. |
| `d569694ae` | 2022-03-08 | Tusooa Zhu | Show only visible announcements in MastodonAPI | implemented | Mastodon announcement index calls `Announcement.list_all_visible/0` rather than listing all admin announcements. | No recheck. |
| `881179ec7` | 2022-03-08 | Tusooa Zhu | Remove GET /api/v1/announcements/:id | implemented | Local Mastodon routes do not expose GET `/api/v1/announcements/:id`, matching upstream's final removal. | No recheck. |
| `11a1996bf` | 2022-03-08 | Tusooa Zhu | Implement update announcement admin api | implemented | Admin announcement update is implemented with PATCH `/api/v1/pleroma/admin/announcements/:id` and tests. | No recheck. |
| `eb1a29640` | 2022-03-08 | Tusooa Zhu | Add pagination to AdminAPI.AnnouncementController.index | implemented | Admin announcement index uses limit/offset pagination and has pagination tests. | No recheck. |
| `0e0a1758f` | 2022-03-08 | Tusooa Zhu | Add doc for Admin Announcement APIs | implemented | Admin announcement API documentation exists in `docs/development/API/admin_api.md` with list/show/create/update/delete routes. | No recheck. |
| `ebcda5265` | 2022-03-08 | Tusooa Zhu | Format announcements into html | implemented | Announcements store rendered HTML and return rendered `content` while preserving raw content under `pleroma.raw_content`. | No recheck. |
| `0c78ab4a8` | 2022-03-18 | Tusooa Zhu | Use utc_datetime in db schema | implemented | Announcement schema fields and timestamps use utc_datetime in lib/pleroma/announcement.ex. | No code backport needed. |
| `7d1dae3be` | 2022-04-02 | Tusooa Zhu | Restrict mastodon api announcements to logged-in users only | implemented | Mastodon announcement routes are behind authenticated API routing and announcement read-state handling expects the authenticated user path. | No code backport needed. |
| `6b937d147` | 2022-07-03 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/server-announcements' into 'develop' | implemented | Server-announcement model, routes, API rendering, and privilege-gated admin routes are present locally. | No code backport needed. |
| `4ea9886fa` | 2022-03-17 | Haelwenn (lanodan) Monnier | EctoType: Add MIME validator | implemented | Pleroma.EctoType.ActivityPub.ObjectValidators.MIME exists and validates media types through the shared MIME regex with an octet-stream fallback. | No code backport needed. |
| `030183b35` | 2022-03-17 | Haelwenn (lanodan) Monnier | AttachmentValidator: Use custom ecto type and regex for "mediaType" | implemented | Attachment validation uses the custom MIME validator for attachment mediaType fields. | No code backport needed. |
| `83338c25a` | 2022-03-17 | Haelwenn (lanodan) Monnier | Transmogrifier: Use validating regex for "mediaType" | implemented | Transmogrifier validates incoming mediaType values before preserving them on attachments. | No code backport needed. |
| `a15b45a58` | 2022-07-03 | Haelwenn | Merge branch 'bugfix/mime-validation-no-list' into 'develop' | implemented | MIME validation branch is represented by the local MIME type, attachment validator, and transmogrifier checks. | No code backport needed. |
| `cd316d726` | 2022-07-01 | Ilja | Use EXIF data of image to prefill image description | implemented | Exiftool.ReadDescription reads EXIF/IPTC description data when uploads do not provide an explicit description. | No code backport needed. |
| `551721e41` | 2022-07-01 | Ilja | Rename the new module | implemented | The EXIF description filter exists under Pleroma.Upload.Filter.Exiftool.ReadDescription. | No code backport needed. |
| `8303af84c` | 2022-07-01 | Ilja | Rename the Exiftool module | implemented | Exiftool filtering is split into Exiftool.StripLocation and Exiftool.ReadDescription modules. | No code backport needed. |
| `d0d48a9e8` | 2022-07-01 | Ilja | Add deprecation warnings | implemented | Application requirement checks reference the renamed Exiftool filters, and the old single-module path is not used by runtime config. | No code backport needed. |
| `cc5686bbd` | 2022-07-01 | Ilja | Migration for exiftool filter | implemented | Migration 20220220135625_upload_filter_exiftool_to_exiftool_strip_location.exs is present for the old Exiftool filter name. | No code backport needed. |
| `75ea76682` | 2022-07-01 | Ilja | Migration failed when no value for Pleroma.Upload was set | implemented | The Exiftool filter migration is present locally and is the branch's compatibility path for existing or absent upload filter settings. | No code backport needed. |
| `81afaee37` | 2022-07-01 | Ilja | Better way of getting keys | implemented | The local Exiftool filter migration uses the current ConfigDB helper path rather than hard-coded stale key handling. | No code backport needed. |
| `7d234d097` | 2022-07-01 | Ilja | Add option to docs about instance gen | superseded | Instance-generation documentation has since been replaced by Unfathomably source-install and upgrade docs. | No code backport needed. |
| `4a9ed319b` | 2022-07-01 | Ilja | Change test pictures | not-applicable | Upstream test image fixture change only. | No code backport needed. |
| `8c761942b` | 2022-07-01 | Ilja | update moduledoc | implemented | The EXIF description filter has module documentation in the local Exiftool.ReadDescription module. | No code backport needed. |
| `56227ef7b` | 2022-07-01 | Ilja | Descriptions from exif data with only whitespeces are considered empty | implemented | Exiftool.ReadDescription trims extracted text and treats empty/whitespace descriptions as no description. | No code backport needed. |
| `de37583c4` | 2022-07-03 | Haelwenn | Merge branch 'image_description_from_exif_data' into 'develop' | implemented | Image-description-from-EXIF merge is covered by the local Exiftool.ReadDescription implementation and migration. | No code backport needed. |
| `aa51fd068` | 2022-05-06 | Pete | Add index hotspots | implemented | Migration 20220506175506_add_index_hotspots.exs adds the upstream users, following_relationships, and notifications indexes. | No code backport needed. |
| `eefa981e0` | 2022-07-03 | Haelwenn | Merge branch 'indexing-hotspots' into 'develop' | implemented | Index-hotspots merge is covered by the local AddIndexHotspots migration. | No code backport needed. |
| `c3a0944ce` | 2022-07-02 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | mix: update eblurhash to 1.2.2 | superseded | The old eblurhash dependency path is no longer the active local media-analysis path; current blurhash handling supersedes it. | No code backport needed. |
| `c50ade26b` | 2022-07-03 | Haelwenn | Merge branch 'fix/eblurhash-binaries' into 'develop' | superseded | Merge wrapper for the old eblurhash update; superseded by the current blurhash implementation. | No code backport needed. |
| `b096fbba1` | 2022-06-02 | Tusooa Zhu | Fix long report notes giving errors on creation | implemented | Migration 20220602052233_change_report_notes_content_to_text.exs and long-content report-note coverage are present. | No code backport needed. |
| `29f4ab640` | 2022-07-04 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/report-too-long' into 'develop' | implemented | Report-note long-content branch is covered by the local text migration and report-note tests. | No code backport needed. |
| `f88ed1df7` | 2022-07-05 | Ilja | Merge branch 'develop' of https://git.pleroma.social/pleroma/pleroma into fine_grained_moderation_privileges | not-applicable | Merge from develop into upstream privilege feature branch; no standalone runtime behavior to backport. | No code backport needed. |
| `2efc0ffcf` | 2022-07-10 | Tusooa Zhu | Pass remote follow avatar into media proxy | implemented | RemoteFollowView.avatar_url/1 pipes remote-follow avatars through MediaProxy.url/1 and templates use that helper. | No code backport needed. |
| `420da14b6` | 2022-07-10 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/2830-remote-fo-mp' into 'develop' | implemented | Remote-follow media-proxy merge is covered by the local RemoteFollowView helper. | No code backport needed. |
| `0d4aceb9b` | 2022-07-05 | Sean King | Make checking blacklisted domains and restricted nicknames case-insenstive | implemented | Restricted-nickname and blacklisted-domain validation compare downcased values/domains. | No code backport needed. |
| `6e7b91963` | 2022-07-06 | Sean King | Make validation functions for restricted nicknames and blacklisted domains; do restricted nickname validation in LDAP account registration | implemented | Reusable restricted nickname/domain validation helpers exist, and LDAP registration calls validate_not_restricted_nickname/2. | No code backport needed. |
| `3cf6c2b7e` | 2022-07-09 | Sean King | Use is_binary instead of is_bitstring for restricted nicknames tests | not-applicable | Test assertion cleanup only. | No code backport needed. |
| `8bb2e52d2` | 2022-07-10 | Tusooa Zhu | Make lint happy | not-applicable | Lint-only cleanup with no runtime behavior. | No code backport needed. |
| `311fda32f` | 2022-07-11 | tusooa | Merge branch 'fix/case-sensitivity-restricted-nicknames-blacklisted-domains' into 'develop' | implemented | Case-insensitive restricted nickname and blacklisted domain branch is covered by local validation helpers. | No code backport needed. |
| `fbf9eced1` | 2022-03-29 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add short_description field | implemented | short_description exists in config/description and instance rendering exposes it through the Mastodon instance API. | No code backport needed. |
| `eb2a1652b` | 2022-07-13 | Tusooa Zhu | Add tests for short_description | implemented | The short_description behavior is present in local instance rendering; upstream row only added tests around that behavior. | No code backport needed. |
| `fdc71f605` | 2022-07-13 | tusooa | Merge branch 'short-description' into 'develop' | implemented | Short-description branch is represented by local config and instance API rendering. | No code backport needed. |
| `659960722` | 2022-04-07 | Tusooa Zhu | Translate static_pages.po (Simplified Chinese) | implemented | Simplified Chinese static_pages.po and related zh_Hans gettext catalogs are present locally. | No code backport needed. |
| `3fb917169` | 2022-07-13 | tusooa | Merge branch 'from/upstream-develop/tusooa/zh-translation' into 'develop' | implemented | zh_Hans translation merge is covered by the local zh_Hans gettext catalog files. | No code backport needed. |
| `44d14e8a9` | 2022-07-14 | Ilja | Merge branch 'develop' of https://git.pleroma.social/pleroma/pleroma into fine_grained_moderation_privileges | implemented | Merge brought multiple already-covered items: short_description, media-proxied remote follow avatars, restricted nickname checks, and zh_Hans catalogs, all present locally. | No code backport needed. |
| `c045a4990` | 2022-07-14 | Ilja | Add privilege for announcements | implemented | announcements_manage_announcements privilege is present and admin announcement routes are privilege-gated. | No code backport needed. |
| `275c60208` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `92da9c4a4` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `2baf3084a` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `ad730c213` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `02947bafe` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `02b4b4da4` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `d622fe8d4` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `db789acf1` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `d24d74b1a` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `97e8c8a10` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `ce0a6737e` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `f9fc3a153` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `1a67a2036` | 2022-07-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply ilja's suggestion(s) to 1 file(s) | not-applicable | Cheatsheet wording suggestion only. | No code backport needed. |
| `b53cf7d4b` | 2022-08-07 | Ilja | Change default moderator privileges to better match what we previously had | implemented | Local moderator/admin privilege defaults and User.privileged?/2 use the modern privilege-list model, preserving moderator route access under configured privileges. | No code backport needed. |
| `2d7ea263a` | 2022-09-24 | Ilja | Add extra routes to :users_manage_credentials privilege | implemented | Admin router uses users_manage_credentials for credential-management routes in the local fine-grained privilege system. | No code backport needed. |
| `0af77b20c` | 2021-12-28 | Tusooa Zhu | Implement moving account | implemented | UtilController.move_account/2 exists and calls ActivityPub.move/2 after password and cooldown checks. | No code backport needed. |
| `df90b3e66` | 2021-12-28 | Tusooa Zhu | Document move_account API | implemented | Move-account API documentation is covered by local API spec and Unfathomably API docs rather than the old upstream markdown-only form. | No code backport needed. |
| `3092558bc` | 2021-12-28 | Tusooa Zhu | Add changelog | not-applicable | Historical upstream changelog-only row. | No code backport needed. |
| `60081a881` | 2021-12-28 | Tusooa Zhu | Add User.add_alias/2 and User.alias_users/1 | implemented | User.alias_users/1 and User.add_alias/2 are present and manage also_known_as entries. | No code backport needed. |
| `c1aa3c98a` | 2021-12-28 | Tusooa Zhu | Add get and add aliases endpoints | implemented | Alias list/add endpoints exist in UtilController and are exposed by router/API spec. | No code backport needed. |
| `54d7b4354` | 2021-12-28 | Tusooa Zhu | Add deleting alias endpoint | implemented | delete_alias endpoint and User.delete_alias/2 behavior are present locally. | No code backport needed. |
| `1d8abf251` | 2021-12-28 | Tusooa Zhu | Document aliases endpoints | implemented | Alias endpoint documentation is covered by local API spec and Unfathomably API docs rather than the old upstream markdown-only form. | No code backport needed. |
| `e41eee5ed` | 2021-12-28 | Tusooa Zhu | Make Move activity federate properly | implemented | ActivityPub.move/2 emits and federates Move activities, validates also_known_as, and updates last_move_at. | No code backport needed. |
| `4f44fd32e` | 2021-12-28 | Tusooa Zhu | Federate unfollow activity in move_following properly | implemented | FollowingRelationship.move_following/2 uses CommonAPI.unfollow/2 after following the target, so unfollow activity federation uses the normal CommonAPI path. | No code backport needed. |
| `a677c621e` | 2021-12-28 | Tusooa Zhu | Make move_following worker follow then unfollow | implemented | FollowingRelationship.move_following/2 follows the target before unfollowing the origin for eligible local followers. | No code backport needed. |
| `eb383ef8d` | 2021-12-28 | Tusooa Zhu | Make move_account endpoint process non-existent users properly | implemented | move_account resolves remote targets through find_or_fetch_user_by_nickname/1 and returns clear target-not-found errors. | No code backport needed. |
| `3fd13b70e` | 2021-12-28 | Tusooa Zhu | Test that the target account is re-fetched in move_account | implemented | The move-account path fetches nonlocal targets before ActivityPub.move/2, covering the upstream re-fetch behavior. | No code backport needed. |
| `9a27cb4f9` | 2021-12-28 | Tusooa Zhu | Deal with target not found error in add_alias | implemented | add_alias handles missing target accounts with a 404 Target account does not exist response. | No code backport needed. |
| `8ddea16b0` | 2022-07-13 | Ilja | DOCS: Add some small piece about setting up a Gitlab-runner | not-applicable | GitLab-runner documentation only and not relevant to Unfathomably deployment tooling. | No code backport needed. |
| `eb4b7f6ef` | 2022-07-17 | tusooa | Merge branch 'docs__setting_up_a_gitlab_runner' into 'develop' | not-applicable | Merge wrapper for GitLab-runner documentation only. | No code backport needed. |
| `31ff467ef` | 2022-03-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Use `types` for filtering notifications | implemented | Notification API accepts types alongside include_types/exclude_types, and the controller defaults types from include_types for compatibility. | No code backport needed. |
| `8aba7c08d` | 2022-07-17 | tusooa | Merge branch 'notification_types' into 'develop' | implemented | Notification types filter merge is covered by local NotificationController and API spec support for types. | No code backport needed. |
| `b2a0718e8` | 2022-07-13 | Tusooa Zhu | Extract config descriptions for translation | implemented | Pleroma.Docs.Translator and Translator.Compiler extract config descriptions for gettext translation. | No code backport needed. |
| `36f6d92d9` | 2022-07-13 | Tusooa Zhu | Add tests for translator compiler | implemented | Translator compiler behavior is present locally; upstream row was test coverage for that compiler. | No code backport needed. |
| `20588517f` | 2022-07-13 | Tusooa Zhu | Make admin api use translated config descriptions | implemented | Admin config API has translation plumbing through the local docs translator/config rendering path. | No code backport needed. |
| `747386888` | 2022-07-13 | Tusooa Zhu | Fix compile error | implemented | Translator module includes the required gettext dependency path and compiles in the local tree. | No code backport needed. |
| `074a94e90` | 2022-07-13 | Tusooa Zhu | Extract translatable strings | implemented | Config-description gettext extraction artifacts and translator compiler support are present locally. | No code backport needed. |
| `1d7e8d6e0` | 2022-07-14 | Tusooa Zhu | Pass in msgctxt for config translation strings | implemented | Translator.Compiler builds msgctxt values with msgctxt_for/2 for config labels/descriptions. | No code backport needed. |
| `bb4860e22` | 2022-07-17 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/config-translatable' into 'develop' | implemented | Config-description translation branch is covered by local translator modules and gettext catalogs. | No code backport needed. |
| `08c8814ef` | 2022-07-11 | Haelwenn (lanodan) Monnier | CI: Run postgres services in alpine | not-applicable | GitLab CI service image change only. | No code backport needed. |
| `702a41ce2` | 2022-07-11 | Haelwenn (lanodan) Monnier | CI: Run lint and cycles in alpine | not-applicable | GitLab CI lint/cycle image change only. | No code backport needed. |
| `e574408b3` | 2022-07-11 | Haelwenn (lanodan) Monnier | CI: Run stages when .gitlab-ci.yml changes | not-applicable | GitLab CI rule change only. | No code backport needed. |
| `6e158bba2` | 2022-07-12 | Haelwenn (lanodan) Monnier | CI: template for change policies based on build stage | not-applicable | GitLab CI template cleanup only. | No code backport needed. |
| `12d888e04` | 2022-07-12 | Haelwenn (lanodan) Monnier | CI: cycles: Use current stable elixir image | not-applicable | GitLab CI image version change only. | No code backport needed. |
| `3193f18cf` | 2022-07-17 | Haelwenn | Merge branch 'shrink-ci' into 'develop' | not-applicable | Merge wrapper for GitLab CI shrinkage only. | No code backport needed. |
| `65a5c713e` | 2022-07-20 | Haelwenn (lanodan) Monnier | CI: Remove cache on cycles | not-applicable | GitLab CI cycle-cache tweak only. | No code backport needed. |
| `fff7571e0` | 2022-07-20 | Haelwenn | Merge branch 'fix-cycles' into 'develop' | not-applicable | Merge wrapper for GitLab CI cycle-cache tweak only. | No code backport needed. |
| `64e16e6a4` | 2022-07-16 | Sean King | Document way to do notice compatibility routes with Nginx reverse-proxy instead | deferred | Upstream replaced notice compatibility routes with nginx rewrite documentation; Unfathomably should review this carefully because frontend fallback and legacy compatibility routing have been deliberately hardened locally. | Review later as a behavior tradeoff, not a blind backport. |
| `2c7eed122` | 2022-07-17 | Sean King | Don't accept forward slash character for nicknames | deferred | Local app-level nickname regexes exclude forward slash, but this upstream row only changes nginx notice-compatibility rewrites and belongs with the deferred notice-route tradeoff. | Review with the notice-route/nginx compatibility decision. |
| `3da1b2548` | 2022-07-18 | Sean King | Actually fix with forward slashes being restricted inside nickname | deferred | Local app-level nickname validation already rejects slash, but the upstream nginx compatibility-route detail is tied to deferred notice-route handling. | Review with the notice-route/nginx compatibility decision. |
| `1f18ab36b` | 2022-07-20 | Haelwenn | Merge branch 'resolve/notice-compatibility-routes-nginx' into 'develop' | deferred | Merge wrapper for the notice-compatibility nginx rewrite/removal branch; frontend fallback and legacy route behavior are deliberately different locally. | Review later as a compatibility tradeoff. |
| `11f9f2ef2` | 2022-06-28 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | EmojiReactValidator: fix emoji qualification | superseded | Early EmojiReact qualification fix was later reverted/reworked upstream; local tree has the later qualification path and unqualified emoji tests. | No code backport needed. |
| `8c78fef56` | 2022-07-04 | Haelwenn | EmojiReactValidator: apply lanodan's suggestions | superseded | Suggestion commit for the early EmojiReact qualification branch; superseded by the later proper emoji qualification implementation. | No code backport needed. |
| `454f892f3` | 2022-07-21 | Haelwenn | Merge branch 'fix/emoji-react-qualification' into 'develop' | superseded | Merge wrapper for an EmojiReact qualification branch that was later reverted and replaced upstream. | No code backport needed. |
| `fb268c437` | 2022-07-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Allow to unset birthday | implemented | Account update accepts empty birthday and local tests assert updating birthday to empty clears it to nil. | No code backport needed. |
| `4350a205a` | 2022-07-21 | Tusooa Zhu | Merge remote-tracking branch 'upstream/develop' into HEAD | implemented | Birthday-fix branch merge is covered by local account update handling and tests for clearing birthday. | No code backport needed. |
| `c589b8445` | 2022-07-21 | tusooa | Merge branch 'birthday_fix' into 'develop' | implemented | Birthday-fix merge is covered by local account update handling and tests for clearing birthday. | No code backport needed. |
| `be9890090` | 2022-07-22 | Haelwenn (lanodan) Monnier | ArticleNotePageValidator: Fix when attachments are a Map (ie. owncast) | implemented | ArticleNotePageValidator.fix_attachments/1 handles a map attachment by wrapping it into a list, covering Owncast-style objects. | No code backport needed. |
| `09e0304b9` | 2022-07-22 | FloatingGhost | Add test for broken owncast federation | implemented | Owncast attachment behavior is covered by local validator handling and broader Owncast source/federation tests. | No code backport needed. |
| `eba166657` | 2022-07-22 | Haelwenn (lanodan) Monnier | AttachmentValidator: fix_media_type/1 fallback to application/octet-stream | implemented | AttachmentValidator.fix_media_type/1 falls back to application/octet-stream when mediaType is absent. | No code backport needed. |
| `3b2bac7a0` | 2022-07-22 | Haelwenn | Merge branch 'fix-owncast' into 'develop' | implemented | Owncast attachment merge is covered by map attachment normalization and attachment media-type fallback. | No code backport needed. |
| `ffe845934` | 2022-07-22 | tusooa | Added translation using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalogs are present locally. | No code backport needed. |
| `cc40640f5` | 2022-07-22 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `99ad60257` | 2022-07-22 | Haelwenn | Added translation using Weblate (French) | implemented | French gettext catalogs are present locally. | No code backport needed. |
| `37ea9e014` | 2022-07-22 | Haelwenn | Added translation using Weblate (French) | implemented | French gettext catalogs are present locally. | No code backport needed. |
| `6da0b5064` | 2022-07-22 | Haelwenn | Translated using Weblate (French) | implemented | French gettext catalog updates are present locally. | No code backport needed. |
| `21bd16822` | 2022-07-22 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `77ebde450` | 2022-07-22 | Haelwenn | Translated using Weblate (French) | implemented | French gettext catalog updates are present locally. | No code backport needed. |
| `bc488824f` | 2022-07-22 | Haelwenn | Added translation using Weblate (French) | implemented | French gettext catalogs are present locally. | No code backport needed. |
| `8c3684ee8` | 2022-07-22 | Haelwenn | Added translation using Weblate (French) | implemented | French gettext catalogs are present locally. | No code backport needed. |
| `8b55661ae` | 2022-07-22 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `54cf23f2f` | 2022-07-22 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `9399fd4ab` | 2022-07-22 | Haelwenn | Translated using Weblate (French) | implemented | French gettext catalog updates are present locally. | No code backport needed. |
| `0b2243f17` | 2022-07-22 | Haelwenn | Translated using Weblate (French) | implemented | French gettext catalog updates are present locally. | No code backport needed. |
| `48bd45ace` | 2022-07-22 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `aff4d5df1` | 2022-07-22 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `5ca95a4f1` | 2022-07-22 | Yating Zhan | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `ca8341a96` | 2022-07-22 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `13e41ab8b` | 2022-07-22 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `2fffca8ef` | 2022-07-22 | Yating Zhan | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `a543161ba` | 2022-07-22 | Yating Zhan | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `0ad115ddf` | 2022-07-22 | Yating Zhan | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `1b091c795` | 2022-07-22 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `4217ac407` | 2022-07-22 | Yating Zhan | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `c057ec687` | 2022-07-22 | Haelwenn | Translated using Weblate (French) | implemented | French gettext catalog updates are present locally. | No code backport needed. |
| `e077da27f` | 2022-07-22 | Haelwenn | Merge branch 'weblate' into 'develop' | implemented | Weblate merge is covered by local fr and zh_Hans gettext catalogs. | No code backport needed. |
| `cfb21d011` | 2022-07-22 | Haelwenn | Revert "Merge branch 'fix/emoji-react-qualification' into 'develop'" | superseded | Revert of the early EmojiReact qualification branch; local tree contains the later proper qualification implementation instead. | No code backport needed. |
| `21e587ff1` | 2022-07-22 | Haelwenn | Merge branch 'revert-454f892f' into 'develop' | superseded | Merge wrapper for reverting the earlier EmojiReact branch; superseded by the later proper qualification implementation. | No code backport needed. |
| `b0f83aea2` | 2022-06-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Store mutes expiration date | implemented | UserRelationship stores expires_at as utc_datetime and User.mute/3 schedules expiring mutes. | No code backport needed. |
| `0b16ce79f` | 2022-07-08 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add test for rendering mute expiration date | implemented | Account view tests cover rendering mute expiration dates. | No code backport needed. |
| `597f56b4c` | 2022-07-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Use :utc_datetime | implemented | Mute expiration storage uses utc_datetime in UserRelationship and related rendering paths. | No code backport needed. |
| `301ce5bc6` | 2022-07-23 | tusooa | Merge branch 'mute-expiration' into 'develop' | implemented | Mute-expiration merge is covered by UserRelationship.expires_at, User.mute/3 duration handling, and account-view tests. | No code backport needed. |
| `388bbc497` | 2022-07-24 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | EmojiReactValidator: fix emoji qualification | implemented | EmojiReactValidator normalizes emoji qualification and tests cover incoming unqualified emoji reactions. | No code backport needed. |
| `d39f803bd` | 2022-07-24 | tusooa | Merge branch 'fix/emoji-react-qualification' into 'develop' | implemented | EmojiReact qualification merge is covered by local validator normalization and tests. | No code backport needed. |
| `5153eba3a` | 2022-07-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add authorized_fetch_mode to description.exs | implemented | authorized_fetch_mode is present in config.exs and config/description.exs, with HTTP signature plug tests. | No code backport needed. |
| `36d79468e` | 2022-07-26 | tusooa | Merge branch 'authorized-fetch' into 'develop' | implemented | authorized_fetch description merge is covered by local config description and HTTP signature behavior. | No code backport needed. |
| `4bdd8e349` | 2022-07-26 | Tusooa Zhu | Extract translatable strings | implemented | Gettext extraction support is present through the docs translator/compiler and gettext artifacts. | No code backport needed. |
| `18d6a58c7` | 2022-07-28 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/gettext-extract' into 'develop' | implemented | Gettext extraction merge is covered by local translator compiler and extracted gettext catalogs. | No code backport needed. |
| `c1874bc8f` | 2022-07-12 | Tusooa Zhu | Make mutes and blocks behave the same as other lists | implemented | Mutes and blocks use Pagination.fetch_paginated/2 and add_link_headers/2, with since_id/max_id/limit tests for both lists. | No code backport needed. |
| `0f9f3d289` | 2022-07-28 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/2384-pagination' into 'develop' | implemented | Mutes/blocks pagination merge is covered by local AccountController and tests. | No code backport needed. |
| `01d396585` | 2022-07-25 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Emoji: implement full-qualifier using combinations | implemented | Proper emoji qualification support is present through EmojiReactValidator normalization and emoji combination handling. | No code backport needed. |
| `fb3f6e197` | 2022-07-25 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | EmojiReactValidator: use new qualification method | implemented | EmojiReactValidator uses the newer emoji qualification normalization path. | No code backport needed. |
| `b99f5d618` | 2022-07-26 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Emoji: split qualification variation into a module | implemented | Emoji qualification combination support is present locally with the current validator path. | No code backport needed. |
| `7167de592` | 2022-07-27 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Emoji: apply recommended tail call changes | implemented | Tail-call/recommended cleanup for emoji qualification is represented by the current local implementation. | No code backport needed. |
| `0814d0e0c` | 2022-07-28 | Haelwenn | Merge branch 'fix/proper-emoji-qualification' into 'develop' | implemented | Proper emoji qualification merge is covered by validator normalization and unqualified emoji reaction tests. | No code backport needed. |
| `5d3d6a58f` | 2022-07-31 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Use `duration` param for mute expiration duration | implemented | Mute requests accept duration and fall back to expires_in for compatibility. | No code backport needed. |
| `b5266097a` | 2022-07-31 | Haelwenn | Merge branch 'mutes' into 'develop' | implemented | Mute duration merge is covered by User.mute/3, AccountController.mute/2, and duration/expires_in tests. | No code backport needed. |
| `c80096522` | 2022-07-31 | tusooa | Merge branch 'develop' into 'from/develop/tusooa/emit-move' | implemented | Merge into the move-account branch is covered by the local ActivityPub.move/2 and move_following implementation. | No code backport needed. |
| `5ef2dc317` | 2022-07-31 | Haelwenn | Change test case wording | not-applicable | Test wording change only. | No code backport needed. |
| `7de21ec99` | 2022-07-31 | Haelwenn | Merge branch 'from/develop/tusooa/emit-move' into 'develop' | implemented | Move-account branch merge is covered by local ActivityPub.move/2, BackgroundWorker move_following, and FollowingRelationship.move_following/2. | No code backport needed. |
| `cc533e695` | 2022-07-31 | tusooa | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `99d4823ab` | 2022-07-31 | Yating Zhan | Translated using Weblate (Chinese (Simplified)) | implemented | zh_Hans gettext catalog updates are present locally. | No code backport needed. |
| `f8540b0a9` | 2022-08-02 | Haelwenn | Merge branch 'weblate' into 'develop' | implemented | Weblate merge is covered by local zh_Hans gettext catalogs. | No code backport needed. |
| `221cb3fb8` | 2022-05-07 | Tusooa Zhu | Allow users to create backups without providing email address | implemented | Backups can be created without enabled mail or a user email, and backup worker skips email delivery when no email is available. | No code backport needed. |
| `7299795eb` | 2022-08-02 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/backup-without-email' into 'develop' | implemented | Backup-without-email merge is covered by local Backup.create/1 and backup worker tests for nil/empty email. | No code backport needed. |
| `c48be59f5` | 2022-05-06 | Tusooa Zhu | Show local-only statuses in public timeline for authenticated users | implemented | Authenticated users can see local-only public timeline/status content, while anonymous and remote AP access are restricted. | No code backport needed. |
| `38af42968` | 2022-05-06 | Tusooa Zhu | Test that anonymous users cannot see local-only posts | implemented | Tests cover anonymous users not seeing local-only posts. | No code backport needed. |
| `826deb737` | 2022-05-06 | Tusooa Zhu | Make local-only statuses searchable | implemented | Database search tests cover local-only search for authenticated users and exclusion for anonymous users. | No code backport needed. |
| `466568ae3` | 2022-05-06 | Tusooa Zhu | Lint | not-applicable | Lint-only cleanup. | No code backport needed. |
| `fe933b9bf` | 2022-05-06 | Tusooa Zhu | Prevent remote access of local-only posts via /objects | implemented | ActivityPub object/activity controller tests cover denying remote access to local-only objects and activities. | No code backport needed. |
| `38444aa92` | 2022-05-09 | Tusooa Zhu | Allow authenticated users to access local-only posts in MastoAPI | implemented | Mastodon API controllers expose local-only posts to authenticated users and deny anonymous users. | No code backport needed. |
| `6e5ef7f2e` | 2022-05-09 | Tusooa Zhu | Test local-only in ap c2s outbox | implemented | ActivityPub C2S/outbox local-only behavior is covered by local ActivityPub controller/visibility tests. | No code backport needed. |
| `f1722a9f4` | 2022-05-09 | Tusooa Zhu | Make lint happy | not-applicable | Lint-only cleanup. | No code backport needed. |
| `b2ba307f4` | 2022-08-02 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/2871-fix-local-public' into 'develop' | implemented | Local-only branch is covered by local timeline, search, status, object, and thread-visibility tests. | No code backport needed. |
| `cbdc13b76` | 2022-08-10 | Mark Felder | Fix Varnish 7 support by ensuring Media Preview Proxy fetches headers with a capitalized HEAD verb | implemented | MediaProxyController uses a capitalized "HEAD" request when probing media previews for Varnish compatibility. | No code backport needed. |
| `243ed7d60` | 2022-08-10 | Mark Felder | Update the recommended VCL configuration | implemented | Recommended VCL/config side is represented by local installation assets; runtime media preview code uses the Varnish-compatible HEAD verb. | No code backport needed. |
| `73b4d0d9a` | 2022-08-10 | Mark Felder | Fix the mocks to use uppercase as well | implemented | Media proxy tests expect capitalized "HEAD" requests. | No code backport needed. |
| `514caed57` | 2022-08-11 | feld | Merge branch 'fix-varnish7-support' into 'develop' | implemented | Varnish 7 support merge is covered by local MediaProxyController HEAD behavior and tests. | No code backport needed. |
| `f2a9285ff` | 2022-08-03 | floatingghost | bugfix/follow-state (#104) | implemented | Follow-state repair task and follow/unfollow state tests are present locally. | No code backport needed. |
| `6ce3f76b5` | 2022-08-12 | Haelwenn | Merge branch 'from/upstream-develop/floatingghost/follow-state' into 'develop' | implemented | Follow-state merge is covered by the local fix_follow_state mix task and follow-state tests. | No code backport needed. |
| `8371fd8ca` | 2022-07-16 | Tusooa Zhu | Implement settings api | deferred | Dedicated upstream Pleroma settings API is not present as a separate controller, although local account update/verify_credentials supports pleroma_settings_store. | Decide whether to add the old dedicated settings endpoint for client compatibility. |
| `8113dd31e` | 2022-07-16 | Tusooa Zhu | Add api docs for settings endpoint | deferred | API docs for the dedicated settings endpoint are tied to the missing/deferred controller endpoint. | Decide with the dedicated settings endpoint. |
| `93f12c0d0` | 2022-08-12 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/sync-settings' into 'develop' | deferred | Settings API merge remains a compatibility candidate; current local behavior persists frontend settings through account credentials instead. | Decide whether to add compatibility routes. |
| `28626eafc` | 2022-07-14 | floatingghost | Allow higher amount of restarts for Pleroma.Repo during testing | not-applicable | Test-only Repo restart tolerance for flaky CI. | No code backport needed. |
| `837d4dc87` | 2022-08-12 | Haelwenn | Merge branch 'fix_flaky_tests_where_we_sometimes_loose_db_connections' into 'develop' | not-applicable | Merge wrapper for test-only Repo restart tolerance. | No code backport needed. |
| `a0166e92f` | 2022-08-06 | Tusooa Zhu | Treat MRF rejects as success in Oban worker | implemented | ReceiverWorker cancels MRF rejections instead of retrying and tests assert MRF reject cancellation. | No code backport needed. |
| `88e0e6acd` | 2022-08-06 | Tusooa Zhu | Fix FederatorTest | not-applicable | Federator test adjustment only. | No code backport needed. |
| `d487e0160` | 2022-08-08 | Tusooa Zhu | Treat containment failure as cancel in ReceiverWorker | implemented | ReceiverWorker treats origin containment failures as cancel, with federator tests covering containment cancellation. | No code backport needed. |
| `06f9324af` | 2022-08-12 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/2912-receiver-reject-mrf' into 'develop' | implemented | Merge wrapper for the ReceiverWorker MRF rejection branch; local ReceiverWorker cancellation behavior and tests are already present. | No code backport needed. |
| `80c32ae00` | 2022-08-12 | Mark Felder | Document the changes for Varnish 7.0+ compatibility and RFC compliance | implemented | Varnish 7/RFC compatibility documentation and media-proxy HEAD behavior are reflected in the local installation VCL and media proxy handling. | No code backport needed. |
| `6ccab516a` | 2022-08-19 | feld | Merge branch 'varnish-fix-changelog' into 'develop' | implemented | Merge wrapper for Varnish compatibility documentation; local install docs/config already carry the relevant behavior. | No code backport needed. |
| `5d900a5cd` | 2022-08-05 | Tusooa Zhu | Use latest alpine version for docker image | not-applicable | Docker base-image bump only; Unfathomably source installs and deployment promotion do not depend on upstream Alpine image metadata. | No code backport needed. |
| `a022b9d73` | 2022-08-21 | tusooa | Merge branch 'from/upstream-develop/tusooa/alpine-bump' into 'develop' | not-applicable | Merge wrapper for Docker Alpine image metadata only. | No code backport needed. |
| `cc0f32c25` | 2022-08-19 | Sean King | Add glitch-lily as an installable frontend | not-applicable | Installable glitch-lily frontend metadata is not used by the Unfathomably BE/FE split distribution. | No code backport needed. |
| `38d9ec41b` | 2022-08-24 | tusooa | Merge branch 'add/glitch-lily-fe' into 'develop' | not-applicable | Merge wrapper for installable glitch-lily frontend metadata. | No code backport needed. |
| `439c1baf2` | 2022-08-24 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | OAuthPlug: use user cache instead of joining | implemented | OAuthPlug and OAuth token handling use User.get_cached_by_id/1 for token users instead of joining users on every request. | No code backport needed. |
| `85c1e1ff4` | 2022-08-24 | tusooa | Merge branch 'fix/oauth-token-user-caching' into 'develop' | implemented | Merge wrapper for OAuth token user caching; local OAuthPlug evidence confirms the optimization is present. | No code backport needed. |
| `47e3a72b6` | 2022-08-24 | Ilja | fix flaky test_user_relationship_test.exs:81 | not-applicable | Upstream flaky-test adjustment only. | No code backport needed. |
| `59109f8f7` | 2022-08-24 | tusooa | Merge branch 'fix_flaky_test_user_relationship_test.exs_81' into 'develop' | not-applicable | Merge wrapper for flaky UserRelationship test adjustment only. | No code backport needed. |
| `5b2e3a303` | 2022-08-24 | Ilja | fix flaky test filter_controller_test.exs:200 | not-applicable | Upstream flaky FilterController test adjustment only. | No code backport needed. |
| `8ec985eea` | 2022-08-24 | tusooa | Merge branch 'fix_flaky_filter_controller_test.exs_200' into 'develop' | not-applicable | Merge wrapper for flaky FilterController test adjustment only. | No code backport needed. |
| `dc72a523c` | 2022-08-25 | Ilja | fix flaky participation_test.exs | not-applicable | Upstream flaky Participation test adjustment only. | No code backport needed. |
| `6f10f93d6` | 2022-08-25 | tusooa | Merge branch 'fix_erratic_participation_test' into 'develop' | not-applicable | Merge wrapper for flaky Participation test adjustment only. | No code backport needed. |
| `9a6280cdb` | 2022-07-20 | Ilja | Fix warnings ":logger is used by the current application but the current application does not depend on :logger" | implemented | mix.exs includes :logger in extra_applications, avoiding the logger application warning. | No code backport needed. |
| `ba31af021` | 2022-07-20 | Ilja | Fix flaky/erratic tests in Pleroma.Config.TransferTaskTest | not-applicable | Upstream Config.TransferTask test stabilization only. | No code backport needed. |
| `6811237ff` | 2022-08-25 | tusooa | Merge branch 'fix_flaky_transfer_task_test.exs' into 'develop' | not-applicable | Merge wrapper for Config.TransferTask test stabilization only. | No code backport needed. |
| `26080b4b5` | 2022-07-09 | Ilja | Fix rate_limiter_test.exs test "it restricts based on config values" | not-applicable | Upstream RateLimiter test stabilization only. | No code backport needed. |
| `84a573877` | 2022-08-25 | tusooa | Merge branch 'fix_erratic_tests' into 'develop' | not-applicable | Merge wrapper for upstream erratic-test fixes. | No code backport needed. |
| `c59a0bd12` | 2022-08-20 | Tusooa Zhu | Add margin to forms and make inputs fill whole width | superseded | The old binary static.css form-margin tweak is superseded by Unfathomably FE/static shell handling and backend themed static rendering rather than carried as a direct instance/static.css copy. | No code backport needed. |
| `780fb4514` | 2022-08-27 | tusooa | Merge branch 'from/upstream-develop/tusooa/static-page-styles' into 'develop' | superseded | Merge wrapper for the superseded static-page style tweak. | No code backport needed. |
| `0cee3c6e9` | 2022-08-20 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | emoji-test: update to latest 15.0 draft | implemented | lib/pleroma/emoji-test.txt is present at Emoji 15.0 and the emoji parser consumes fully-qualified entries from that file. | No code backport needed. |
| `a546e6f04` | 2022-08-27 | tusooa | Merge branch 'feature/emoji-15-support' into 'develop' | implemented | Merge wrapper for Emoji 15 support; local emoji-test data is already at 15.0. | No code backport needed. |
| `d67d19134` | 2022-08-24 | Sean King | Fix fedi-fe build URL | not-applicable | Fedi-fe build URL metadata is not part of the Unfathomably FE/BE split distribution workflow. | No code backport needed. |
| `497cd5d5d` | 2022-08-27 | tusooa | Merge branch 'fix/fedi-fe-build-url' into 'develop' | not-applicable | Merge wrapper for fedi-fe build URL metadata. | No code backport needed. |
| `d0c1997d4` | 2022-03-19 | Sean King | Rewrite integration-test websocket client with Mint.WebSocket | superseded | Upstream later reverted the Mint.WebSocket integration-test rewrite in b439e91f5/0a05ebf78, so there is no surviving behavior to backport from this branch. | No code backport needed. |
| `4194559ea` | 2022-03-20 | Sean King | Fix lint errors | superseded | Lint cleanup for the subsequently reverted Mint.WebSocket test rewrite. | No code backport needed. |
| `01239456a` | 2022-09-02 | Haelwenn | Merge branch 'rewrite/integration-test-websocket-client' into 'develop' | superseded | Merge wrapper for the subsequently reverted Mint.WebSocket integration-test rewrite. | No code backport needed. |
| `e94937847` | 2022-09-02 | Fristi | Added translation using Weblate (Dutch) | implemented | Dutch static_pages gettext catalog exists locally under priv/gettext/nl/LC_MESSAGES/static_pages.po. | No code backport needed. |
| `a6195c712` | 2022-09-02 | Fristi | Added translation using Weblate (Dutch) | implemented | Dutch posix_errors gettext catalog exists locally under priv/gettext/nl/LC_MESSAGES/posix_errors.po. | No code backport needed. |
| `425fbce7b` | 2022-09-02 | Fristi | Translated using Weblate (Dutch) | implemented | Dutch errors gettext catalog exists locally under priv/gettext/nl/LC_MESSAGES/errors.po. | No code backport needed. |
| `9af5da666` | 2022-09-02 | Fristi | Translated using Weblate (Dutch) | implemented | Dutch static_pages Weblate updates are represented by the local static_pages.po catalog. | No code backport needed. |
| `0d8c6b048` | 2022-09-02 | Fristi | Translated using Weblate (Dutch) | implemented | Dutch posix_errors Weblate updates are represented by the local posix_errors.po catalog. | No code backport needed. |
| `e22a77224` | 2022-09-02 | Haelwenn | Merge branch 'weblate' into 'develop' | implemented | Merge wrapper for Dutch Weblate catalogs; local nl errors, posix_errors, and static_pages catalogs are present. | No code backport needed. |
| `b439e91f5` | 2022-09-02 | Haelwenn | Revert "Merge branch 'rewrite/integration-test-websocket-client' into 'develop'" | implemented | Revert of the Mint.WebSocket integration-test rewrite is reflected by treating the reverted branch as non-actionable. | No code backport needed. |
| `0a05ebf78` | 2022-09-02 | Haelwenn | Merge branch 'revert-01239456' into 'develop' | implemented | Merge wrapper for reverting the Mint.WebSocket integration-test rewrite. | No code backport needed. |
| `270162878` | 2022-08-20 | Tusooa Zhu | Add remote interaction ui for posts | implemented | Remote interaction UI for posts is present through UtilController, status_interact.html.eex, and controller tests. | No code backport needed. |
| `a243a217a` | 2022-08-20 | Tusooa Zhu | Fix form item name in status_interact.html | implemented | The status interaction form uses the expected status parameter names in the local status_interact template and tests. | No code backport needed. |
| `779457d9a` | 2022-08-20 | Tusooa Zhu | Add GET endpoints for remote subscription forms | implemented | GET /main/ostatus routes to show_subscribe_form/2 and is covered by UtilController tests. | No code backport needed. |
| `b7c75db0f` | 2022-08-20 | Tusooa Zhu | Lint | not-applicable | Lint-only cleanup for remote interaction branch. | No code backport needed. |
| `1218adacc` | 2022-08-20 | Tusooa Zhu | Display status link in remote interaction form | implemented | The remote interaction form displays a linked status label in the translatable status_interact template. | No code backport needed. |
| `ec0e912c5` | 2022-08-20 | Tusooa Zhu | Add changelog | not-applicable | Changelog-only commit for upstream remote interaction branch. | No code backport needed. |
| `4ec9eeb3f` | 2022-08-20 | Tusooa Zhu | Make remote interaction page translatable | implemented | Remote interaction templates use static_pages gettext calls, so the page is translatable. | No code backport needed. |
| `c59ee1f17` | 2022-08-20 | Tusooa Zhu | Expose availability of GET /main/ostatus via instance | implemented | Instance feature metadata includes pleroma:get:main/ostatus, advertising GET /main/ostatus availability. | No code backport needed. |
| `07ef72f49` | 2022-09-03 | Haelwenn | Merge branch 'from/develop/tusooa/2807-remote-xact-post' into 'develop' | implemented | Merge wrapper for the remote-interaction UI branch; local routes, templates, feature metadata, and tests are present. | No code backport needed. |
| `547def67a` | 2022-05-29 | Tusooa Zhu | Allow Updates by every actor on the same origin | implemented | Update validation accepts same-origin actors, with local UpdateValidator and update-handling tests present. | No code backport needed. |
| `0f6a5eb9a` | 2022-05-29 | Tusooa Zhu | Handle Note and Question Updates | implemented | Note and Question Update handling is present through Object.Updater, validators, transmogrifier handling, and side-effect tests. | No code backport needed. |
| `5e8aac0e0` | 2022-05-29 | Tusooa Zhu | Record edit history for Note and Question Updates | implemented | formerRepresentations edit history is recorded for Note and Question updates and covered by Object.Updater/ObjectFetcher tests. | No code backport needed. |
| `8acfe95f3` | 2022-05-29 | Tusooa Zhu | Allow updating polls | implemented | Poll Question updates are supported and covered by update-handling tests. | No code backport needed. |
| `c004eb0fa` | 2022-05-29 | Tusooa Zhu | Implement mastodon api for showing edit history | implemented | Mastodon-compatible status history endpoint GET /api/v1/statuses/:id/history is routed to StatusController.show_history. | No code backport needed. |
| `393b50884` | 2022-05-30 | Tusooa Zhu | Implement viewing source | implemented | Status source endpoint GET /api/v1/statuses/:id/source and StatusView source rendering are present and tested. | No code backport needed. |
| `b613a9ec6` | 2022-05-31 | Tusooa Zhu | Implement mastodon api for editing status | implemented | Mastodon-compatible status editing is present through StatusController.update and CommonAPI.update. | No code backport needed. |
| `410e177b2` | 2022-06-01 | Tusooa Zhu | Strip internal fields in formerRepresentation | implemented | Object.Updater strips and normalizes formerRepresentation/internal fields before rendering history. | No code backport needed. |
| `fa31ae50e` | 2022-06-01 | Tusooa Zhu | Inject history when object is refetched | implemented | Object refetch/update logic injects or preserves history when remote objects change. | No code backport needed. |
| `8bac8147d` | 2022-06-03 | Tusooa Zhu | Stream out edits | implemented | Status edit updates are streamed and tested through notification/stream update paths. | No code backport needed. |
| `fdaa86408` | 2022-06-03 | Tusooa Zhu | Test that own edits are streamed | not-applicable | Test-only coverage commit for own edit streaming. | No code backport needed. |
| `3249ac1f1` | 2022-06-03 | Tusooa Zhu | Show edited_at in MastodonAPI/show | implemented | Mastodon StatusView renders edited_at and tests assert edited_at behavior. | No code backport needed. |
| `72ac94061` | 2022-06-03 | Tusooa Zhu | Fix SideEffectsTest | not-applicable | SideEffects test adjustment only. | No code backport needed. |
| `fe2d4778e` | 2022-06-04 | Tusooa Zhu | Expose content type of status sources | implemented | Status source rendering exposes content type/source information through StatusView source handling. | No code backport needed. |
| `97eabb204` | 2022-06-04 | Tusooa Zhu | Fix CommonAPITest | not-applicable | CommonAPI test adjustment only. | No code backport needed. |
| `06a399801` | 2022-06-05 | Tusooa Zhu | Create Update notifications | implemented | Update notifications are supported: notification type update exists, tests create update notifications, and Mastodon NotificationView renders them. | No code backport needed. |
| `532f6ae3e` | 2022-06-05 | Tusooa Zhu | Return update notification in mastodon api | implemented | Mastodon notification rendering returns update notification payloads for status edits. | No code backport needed. |
| `d2d3532e5` | 2022-06-05 | Tusooa Zhu | Lint | not-applicable | Lint-only cleanup in the status edit branch. | No code backport needed. |
| `237b220d7` | 2022-06-08 | Tusooa Zhu | Add object id to uploaded attachments | implemented | Upload.store assigns generated ActivityPub object IDs to uploaded attachments. | No code backport needed. |
| `aafd7a687` | 2022-06-08 | Tusooa Zhu | Return the corresponding object id in attachment view | implemented | Attachment rendering returns stable IDs derived from attachment object IDs when available. | No code backport needed. |
| `c3593639a` | 2022-06-09 | Tusooa Zhu | Fix incorrectly cached content after editing | implemented | Edited status cache invalidation/update behavior is handled by Object.Updater and tested around edited status rendering. | No code backport needed. |
| `27f3d802f` | 2022-06-11 | Tusooa Zhu | Expose history and source apis to anon users | implemented | History and source endpoints are exposed for anonymous users when the status is visible. | No code backport needed. |
| `7451f0e81` | 2022-06-11 | Tusooa Zhu | Send the correct update in streamer | implemented | Streamer update handling sends the correct Update activity; update notification and stream tests cover this path. | No code backport needed. |
| `95b392232` | 2022-06-11 | Tusooa Zhu | Workaround with_index does not support function in Elixir 1.9 | superseded | Old Elixir 1.9 with_index workaround is superseded by the current supported toolchain and local implementation. | No code backport needed. |
| `44613db85` | 2022-06-11 | Tusooa Zhu | Show original status at the first of history | implemented | Status history rendering includes the original status first, with StatusView/Object.Updater history tests present. | No code backport needed. |
| `06da000c5` | 2022-06-21 | Tusooa Zhu | Add editing to features | implemented | Instance feature metadata advertises editing support. | No code backport needed. |
| `01321c88b` | 2022-06-24 | Tusooa Zhu | Convert incoming Updated object into Pleroma format | implemented | Incoming Updated objects are converted into the local Pleroma object-update format through transmogrifier/object validator handling. | No code backport needed. |
| `ee0738319` | 2022-06-24 | Tusooa Zhu | Use meta[:object_data] in SideEffects for Update | implemented | SideEffects for Update uses object_data metadata as part of the unified update path. | No code backport needed. |
| `e0d6da4e7` | 2022-06-24 | Tusooa Zhu | Fix CommonAPITest | not-applicable | CommonAPI test adjustment only. | No code backport needed. |
| `99a6f5031` | 2022-06-25 | Tusooa Zhu | Unify the logic of updating objects | implemented | Object update logic is centralized in Pleroma.Object.Updater. | No code backport needed. |
| `40953a8f5` | 2022-06-25 | Tusooa Zhu | Reuse formerRepresentations from remote if possible | implemented | Remote formerRepresentations are reused when valid during object fetch/update. | No code backport needed. |
| `e98579b1d` | 2022-06-25 | Tusooa Zhu | Verify that formerRepresentation provided in Update is used | not-applicable | Test-only verification for remote formerRepresentation reuse. | No code backport needed. |
| `9c6dae942` | 2022-06-25 | Tusooa Zhu | Fix local updates causing emojis to be lost | implemented | Local updates preserve emoji metadata through Object.Updater and update-handling tests. | No code backport needed. |
| `5321fd001` | 2022-06-25 | Tusooa Zhu | Do not put meta[:object_data] for local Updates | implemented | Local Updates avoid storing meta[:object_data] in the outgoing path where it is not needed. | No code backport needed. |
| `014096aee` | 2022-06-25 | Tusooa Zhu | Make outbound transmogrifier aware of edit history | implemented | Outbound transmogrifier is aware of edit history/formerRepresentations. | No code backport needed. |
| `4edc867b8` | 2022-07-03 | Tusooa Zhu | Merge branch 'develop' into 'from/upstream-develop/tusooa/edits' | not-applicable | Merge-only synchronization of the status-edit branch with develop. | No code backport needed. |
| `4367489a3` | 2022-07-03 | Tusooa Zhu | Pass history items through ObjectValidator for updatable object types | implemented | History items pass through ObjectValidator for updatable object types. | No code backport needed. |
| `5ce118d97` | 2022-07-03 | Tusooa Zhu | Validate object data for incoming Update activities | implemented | Incoming Update activity object data is validated for updatable object types. | No code backport needed. |
| `f84ed44ce` | 2022-07-06 | Tusooa Zhu | Fix cannot get full history on object fetch | implemented | Full history retrieval on object fetch is covered by ObjectFetcher formerRepresentations tests. | No code backport needed. |
| `069554e92` | 2022-07-07 | Tusooa Zhu | Guard against outdated Updates | implemented | Outdated Updates are guarded against in update handling. | No code backport needed. |
| `11a6e8842` | 2022-07-07 | Tusooa Zhu | Test that Question updates are viable | not-applicable | Test-only verification that Question updates remain viable. | No code backport needed. |
| `04ded94a5` | 2022-07-09 | Tusooa Zhu | Fix remote emoji in subject disappearing after edits | implemented | Remote emoji in edited subjects/history is preserved by update handling tests. | No code backport needed. |
| `eba9b0760` | 2022-07-23 | Tusooa Zhu | Make MRF Keyword history-aware | implemented | MRF Keyword policy is history-aware and tests cover formerRepresentations filtering. | No code backport needed. |
| `cd19537f3` | 2022-07-23 | Tusooa Zhu | Make EnsureRePrepended history-aware | implemented | MRF EnsureRePrepended is history-aware and tests cover formerRepresentations summary handling. | No code backport needed. |
| `0a337063e` | 2022-07-23 | Tusooa Zhu | Make ForceMentionsInContent history-aware | implemented | MRF ForceMentionsInContent processes formerRepresentations, with history-aware tests present. | No code backport needed. |
| `dce7e4292` | 2022-07-23 | Tusooa Zhu | Make MediaProxyWarmingPolicy history-aware | implemented | MRF MediaProxyWarmingPolicy preloads media from formerRepresentations and tests cover Update/history paths. | No code backport needed. |
| `fc7ce5f93` | 2022-07-23 | Tusooa Zhu | Make NoPlaceholderTextPolicy history-aware | implemented | MRF NoPlaceholderTextPolicy scrubs formerRepresentations and tests cover the history path. | No code backport needed. |
| `46a5c0685` | 2022-07-23 | Tusooa Zhu | Make NormalizeMarkup history-aware | implemented | MRF NormalizeMarkup scrubs formerRepresentations and tests cover normalized history items. | No code backport needed. |
| `82c8fc1ed` | 2022-07-23 | Tusooa Zhu | Make NoEmptyPolicy work with Update | implemented | NoEmptyPolicy treats Update as an eligible activity type and tests cover empty Update rejection. | No code backport needed. |
| `d877d2a4e` | 2022-07-24 | Tusooa Zhu | Make HashtagPolicy history-aware | implemented | MRF HashtagPolicy is history-aware and tests cover formerRepresentations sensitivity/tag handling. | No code backport needed. |
| `997f08b35` | 2022-07-24 | Tusooa Zhu | Make AntiLinkSpamPolicy history-aware | implemented | MRF AntiLinkSpamPolicy examines formerRepresentations and tests cover history-aware rejection/acceptance. | No code backport needed. |
| `a4fa286d2` | 2022-08-02 | Tusooa Zhu | Use actor_types() to determine whether the Update is for user | implemented | Update handling uses Pleroma.Constants.actor_types() to distinguish actor updates from object updates. | No code backport needed. |
| `e40c221c3` | 2022-09-03 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/edits' into 'develop' | implemented | Merge wrapper for the status-edit/history-aware MRF branch; local implementation is present across validators, MRF policies, streams, and APIs. | No code backport needed. |
| `06678fb4a` | 2022-08-20 | Tusooa Zhu | Add function to calculate associated object id | implemented | associated_object_id(data) SQL function exists with Activity tests for object IDs in strings, maps, lists, bad maps, and missing data. | No code backport needed. |
| `3885ee182` | 2022-08-20 | Tusooa Zhu | Switch to associated_object_id index | implemented | Activities queries and migrations use associated_object_id(data) indexes for object/activity joins. | No code backport needed. |
| `4e7ed563c` | 2022-08-20 | Tusooa Zhu | Lint | not-applicable | Lint-only cleanup for associated_object_id branch. | No code backport needed. |
| `f047088a9` | 2022-08-20 | Tusooa Zhu | Update thread visibility function | implemented | thread_visibility was rewritten to use associated_object_id(data) in the local migration path. | No code backport needed. |
| `299255b9b` | 2022-09-03 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/assoc-object-id' into 'develop' | implemented | Merge wrapper for associated_object_id/thread_visibility branch; local migrations and queries are present. | No code backport needed. |
| `e606b9ab3` | 2022-05-18 | duponin | add missing extra application to start the SSH BBS | deferred | Upstream SSH BBS startup dependency is not carried locally; Unfathomably currently ships web/API/FE surfaces rather than the terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `39c47073a` | 2022-05-18 | duponin | fix Ctrl-c catch on SSH BBS | deferred | SSH BBS Ctrl-C behavior belongs to the uncarried terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `5086d6d5e` | 2022-05-19 | duponin | add thread show in BBS frontend | deferred | SSH BBS thread display belongs to the uncarried terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `b128e1d6c` | 2022-05-19 | duponin | decode HTML to be human readable in BBS | deferred | SSH BBS HTML decoding belongs to the uncarried terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `33ced2c2e` | 2022-05-21 | duponin | BBS: put a new line for each HTML break in an activity | deferred | SSH BBS HTML break formatting belongs to the uncarried terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `c04c7f9e4` | 2022-05-21 | duponin | BBS: show notifactions | deferred | SSH BBS notification display belongs to the uncarried terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `e3e8ff06f` | 2022-05-21 | duponin | BBS: mark notification as read | deferred | SSH BBS notification read-state behavior belongs to the uncarried terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `a4659d993` | 2022-05-21 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Apply HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne suggestions | deferred | Suggestion commit in the uncarried SSH BBS frontend series. | Revisit only if SSH BBS becomes a release target. |
| `fffd9059d` | 2022-05-22 | duponin | BBS: add post favourite feature | deferred | SSH BBS favourite action belongs to the uncarried terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `5951d637a` | 2022-05-22 | duponin | BBS: show post ID when posted | deferred | SSH BBS post-ID display belongs to the uncarried terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `5ca1ac041` | 2022-05-22 | duponin | BBS: add repeat functionality | deferred | SSH BBS repeat action belongs to the uncarried terminal BBS frontend. | Revisit only if SSH BBS becomes a release target. |
| `257601d67` | 2022-09-03 | Haelwenn | Merge branch 'ssh-bbs-improvements' into 'develop' | deferred | Merge wrapper for the uncarried SSH BBS frontend improvements. | Revisit only if SSH BBS becomes a release target. |
| `4477c6baf` | 2022-09-03 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Metadata/Utils: use summary as description if set | implemented | Metadata.Utils uses object summary as the description when present, with Twitter card tests covering summary-as-description. | No code backport needed. |
| `71839cb89` | 2022-09-03 | tusooa | Merge branch 'changes/embed-metadata' into 'develop' | implemented | Merge wrapper for embed metadata summary handling; local Metadata.Utils behavior is present. | No code backport needed. |
| `3afa1903e` | 2022-08-27 | Tusooa Zhu | Do not stream out Create of ChatMessage | implemented | ChatMessage Create activities are not streamed through the generic object creation path; ChatMessages use the dedicated chat stream path. | No code backport needed. |
| `f9b86c3c2` | 2022-08-27 | Tusooa Zhu | Make local-only posts stream in local timeline | implemented | Local-only posts are included in authenticated local timeline handling and covered by timeline/status/search tests. | No code backport needed. |
| `ffd379456` | 2022-08-31 | Tusooa Zhu | Do not stream out Announces to public timelines | implemented | Activity IR visibility_tags excludes Announce activities from public timeline fanout. | No code backport needed. |
| `20a0dd651` | 2022-08-31 | Tusooa Zhu | Exclude Announce instead of restricting to Create in visibility_tags | implemented | Activity IR excludes Announce for visibility tags rather than narrowing all streaming to Create-only. | No code backport needed. |
| `c32e28e1b` | 2022-09-01 | Tusooa Zhu | Fix SideEffectsTest | not-applicable | SideEffects test adjustment only. | No code backport needed. |
| `d19696cf6` | 2022-09-02 | Tusooa Zhu | Lint | not-applicable | Lint-only cleanup for streaming branch. | No code backport needed. |
| `c63cf954d` | 2022-09-03 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/streaming-fix' into 'develop' | implemented | Merge wrapper for streaming fixes; local Activity IR and SideEffects paths contain the behavior. | No code backport needed. |
| `f3e061c96` | 2022-08-09 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Object: remove context_id field | implemented | Object schema no longer depends on a stored context_id field, while legacy context_id is stripped as an internal field. | No code backport needed. |
| `7f71e3d0f` | 2022-08-09 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | CommonFields: remove context_id | implemented | Common object fields no longer persist context_id as schema data; context is handled directly from ActivityPub object data. | No code backport needed. |
| `a9111bcaf` | 2022-08-09 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | StatusView: clear MSB on calculated conversation_id | implemented | StatusView calculates deprecated pleroma.conversation_id from CRC32(context) and clears the high bit to avoid signed-client overflow. | No code backport needed. |
| `def0f5dc2` | 2022-08-10 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | StatusView: implement pleroma.context field | implemented | Status rendering exposes the ActivityPub context through the pleroma metadata path while retaining the deprecated conversation_id shim. | No code backport needed. |
| `c559c240d` | 2022-08-10 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Migrations: delete context objects | implemented | DataMigrationDeleteContextObjects migration exists to remove old context objects. | No code backport needed. |
| `3b6784b1d` | 2022-08-10 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | CreateGenericValidator: fix reply context fixing | implemented | CreateGenericValidator/CommonFixes context repair tests are present for predictable reply context handling. | No code backport needed. |
| `bb02ee99f` | 2022-08-15 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | CommonFixes: more predictable context generation | implemented | CommonFixes.fix_activity_context/2 has regression coverage for predictable context repair. | No code backport needed. |
| `88c1c76d3` | 2022-08-15 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Migrations: delete contexts with BaseMigrator | implemented | Context-object cleanup is implemented through BaseMigrator-backed DataMigrationDeleteContextObjects migration. | No code backport needed. |
| `20347898e` | 2022-09-04 | tusooa | Merge branch 'fix/federation-context-issues' into 'develop' | implemented | Merge wrapper for federation context fixes; local context migrations, StatusView behavior, and CommonFixes tests are present. | No code backport needed. |
| `f41d970a5` | 2022-08-16 | FloatingGhost | fix resolution of GTS user keys | implemented | HTTP signature key resolution supports GoToSocial-style key documents and multi-key actor shapes in the local signature path. | No code backport needed. |
| `61254111e` | 2022-08-18 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | HttpSignaturePlug: accept standard (request-target) | implemented | Incoming HTTP signatures accept the standard (request-target) pseudo-header and tests cover request-target handling. | No code backport needed. |
| `4661b5672` | 2022-08-19 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | ArticleNotePageValidator: fix replies fixing | implemented | ArticleNotePageValidator handles replies collection normalization and GoToSocial-style replies shapes. | No code backport needed. |
| `f8afba95b` | 2022-09-05 | tusooa | Merge branch 'fix/gts-federation' into 'develop' | implemented | Merge wrapper for GoToSocial federation fixes; local signature and replies handling are present. | No code backport needed. |
| `21ab7369c` | 2022-09-02 | Haelwenn (lanodan) Monnier | Bump minimum Elixir version to 1.10 | superseded | Minimum Elixir 1.10 bump is superseded by Unfathomably's current ~> 1.20 requirement. | No code backport needed. |
| `80a2528fd` | 2022-09-03 | Haelwenn (lanodan) Monnier | ci-base: Document building and pushing a new image | not-applicable | CI base image documentation only. | No code backport needed. |
| `f7c207310` | 2022-09-05 | tusooa | Merge branch 'bump/min-elixir-1.10' into 'develop' | superseded | Merge wrapper for minimum Elixir 1.10 bump; local requirement is newer. | No code backport needed. |
| `cd237d22f` | 2022-09-05 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | User: generate private keys on user creation | implemented | User registration changesets generate RSA private keys on local user creation and tests assert keys are set. | No code backport needed. |
| `cfb1bc967` | 2022-09-05 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | Migrations: generate unset user keys | implemented | GenerateUnsetUserKeys migration backfills missing local user keys with generated RSA PEM material. | No code backport needed. |
| `346c130dd` | 2022-09-05 | Haelwenn | Merge branch 'fix/user-private-key-generation' into 'develop' | implemented | Merge wrapper for user private-key generation/backfill; local user changesets and migration are present. | No code backport needed. |
| `a7f01ffc1` | 2022-08-09 | Tusooa Zhu | Make backups require its own scope | implemented | Backup controller requires the dedicated read:backups OAuth scope for backup index/create actions. | No code backport needed. |
| `738ca484f` | 2022-08-09 | Tusooa Zhu | Update api spec to reflect OAuth scope change | implemented | Pleroma backup OpenAPI operations advertise read:backups security requirements. | No code backport needed. |
| `e06f2b9f5` | 2022-08-09 | Tusooa Zhu | Add changelog | not-applicable | Changelog-only commit for backup OAuth scope change. | No code backport needed. |
| `9874b4c98` | 2022-09-05 | tusooa | Merge branch 'develop' into 'from/upstream-develop/tusooa/2892-backup-scope' | implemented | Merge synchronization for backup scope branch; local backup scope enforcement remains present. | No code backport needed. |
| `b8d6cb584` | 2022-09-05 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/2892-backup-scope' into 'develop' | implemented | Merge wrapper for backup scope branch; local controller and OpenAPI scope handling are present. | No code backport needed. |
| `c6bc52391` | 2022-09-05 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Clarify `birthday_min_age` config description | implemented | birthday_min_age is documented in config description and exposed through instance configuration. | No code backport needed. |
| `c0b265b40` | 2022-09-06 | tusooa | Merge branch 'birthday-config-description' into 'develop' | implemented | Merge wrapper for birthday_min_age config-description clarification. | No code backport needed. |
| `3d32c92b3` | 2022-09-06 | weblate-extractor | Extract translatable strings | not-applicable | Weblate extraction commit only. | No code backport needed. |
| `453a66f8c` | 2022-09-06 | Haelwenn | Merge branch 'weblate-extract' into 'develop' | not-applicable | Merge wrapper for Weblate extraction only. | No code backport needed. |
| `0b19625bf` | 2022-09-11 | HÃƒÆ’Ã‚Â©lÃƒÆ’Ã‚Â¨ne | ObjectView: do not fetch an object for its ID | implemented | ObjectView renders Object or Activity structs directly and has no binary-ID render path that fetches during rendering. | No code backport needed. |
| `ac427de85` | 2022-09-11 | tusooa | Merge branch 'fix/undo-boosts' into 'develop' | implemented | Merge wrapper for ObjectView undo/boost fetch fix; local ObjectView behavior avoids ID fetches. | No code backport needed. |
| `6bdf451ce` | 2022-09-11 | FloatingGhost | Use set of pregenerated RSA keys | implemented | Test factory uses a set of pregenerated RSA key fixtures instead of generating keys for every user factory invocation. | No code backport needed. |
| `90d4b7d60` | 2022-09-12 | tusooa | Merge branch 'fix/user-factory-speed' into 'develop' | implemented | Merge wrapper for test user-factory RSA key speedup. | No code backport needed. |
| `6754d1f27` | 2022-03-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | POST /api/v1/accounts/:id/remove_from_followers | implemented | POST /api/v1/accounts/:id/remove_from_followers is routed, documented, and handled by AccountController.remove_from_followers. | No code backport needed. |
| `ffe081bf4` | 2022-03-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Use reject_follow_request | implemented | remove_from_followers uses CommonAPI.reject_follow_request to remove follower relationships cleanly. | No code backport needed. |
| `9022d855c` | 2022-07-13 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Check refute User.following? | not-applicable | Test-only assertion that the removed follower no longer follows. | No code backport needed. |
| `ea60c4e70` | 2022-09-14 | Tusooa Zhu | Fix wrong relationship direction | implemented | remove_from_followers relationship direction is correct: the current user is followed and the target account is the follower being rejected. | No code backport needed. |
| `1a7107f4a` | 2022-09-16 | tusooa | Merge branch 'remove_from_followers' into 'develop' | implemented | Merge wrapper for remove_from_followers; local route, controller, OpenAPI operation, and tests are present. | No code backport needed. |
| `6d148b663` | 2022-09-03 | Tusooa Zhu | Use Websockex to replace websocket_client | implemented | websockex is the local websocket test client dependency, replacing websocket_client in test tooling. | No code backport needed. |
| `ac95b8b4f` | 2022-09-18 | tusooa | Merge branch 'websocketex' into 'develop' | implemented | Merge wrapper for Websockex migration; local dependency is websockex. | No code backport needed. |
| `2f301bbb8` | 2022-09-03 | Haelwenn (lanodan) Monnier | timeline_controller_test: Fix test name for elixir 1.14 | not-applicable | Elixir 1.14 test-name fix only. | No code backport needed. |
| `93ed6da4a` | 2022-09-03 | Haelwenn (lanodan) Monnier | mix: Switch prometheus_ex to fix/elixir-1.14 branch | superseded | Old prometheus_ex branch pin is superseded by the local PromEx metrics integration and current dependency stack. | No code backport needed. |
| `e124776d1` | 2022-09-03 | Haelwenn (lanodan) Monnier | Elixir 1.14 formatting | not-applicable | Elixir 1.14 formatting-only commit. | No code backport needed. |
| `24af2e1c5` | 2022-09-03 | Haelwenn (lanodan) Monnier | script_test: Fix %ErlangError for Elixir 1.14 | not-applicable | script_test Elixir 1.14 adjustment only. | No code backport needed. |
| `ec80a1e40` | 2022-09-03 | Haelwenn (lanodan) Monnier | Bump minimum Elixir version to 1.10 | superseded | Minimum Elixir 1.10 bump is superseded by Unfathomably's current ~> 1.20 requirement. | No code backport needed. |
| `5d7d62339` | 2022-09-27 | Haelwenn | Merge branch 'bugfix/elixir-1.14' into 'develop' | superseded | Merge wrapper for Elixir 1.14 compatibility branch; local toolchain/dependency work is newer. | No code backport needed. |
| `467b6cad6` | 2022-09-17 | Tusooa Zhu | Reduce incoming and outgoing federation queue sizes to 5 | implemented | Default Oban federator_incoming and federator_outgoing queue concurrency now matches upstream's 5, with config descriptions updated. | No further action. |
| `757a21554` | 2022-09-27 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/2169-queue-limit' into 'develop' | implemented | Merge wrapper for the federation queue limit branch, now represented by the lowered local federation queue defaults. | No further action. |
| `e66c02b77` | 2022-09-20 | Tusooa Zhu | Make instance document controller test sync | not-applicable | Synchronous test adjustment for instance document controller only. | No code backport needed. |
| `d43d02bf4` | 2022-09-27 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/fix-static-tests' into 'develop' | not-applicable | Merge wrapper for static test synchronization only. | No code backport needed. |
| `7f63b4c31` | 2022-09-16 | a1batross | User: search: exclude deactivated users from user search | implemented | User search filters active users and tests exclude deactivated users from search results. | No code backport needed. |
| `3f1c31b7c` | 2022-09-27 | Haelwenn | Merge branch 'fix/exclude-deactivated-in-search' into 'develop' | implemented | Merge wrapper for excluding deactivated users from search. | No code backport needed. |
| `dd82fd234` | 2022-10-08 | Tusooa Zhu | Merge branch 'release/2.4.4' into mergeback/2.4.4 | implemented | Release 2.4.4 mergeback content is covered by the surrounding queue, streaming, Websockex, and edit-history rows already audited. | No code backport needed. |
| `8042e0ebe` | 2022-10-09 | tusooa | Merge branch 'mergeback/2.4.4' into 'develop' | implemented | Develop merge wrapper for 2.4.4 mergeback, covered by neighboring reviewed rows. | No code backport needed. |
| `1ac9bd0b4` | 2022-10-11 | weblate-extractor | Extract translatable strings | not-applicable | Weblate extraction only. | No code backport needed. |
| `c83028262` | 2022-10-11 | tusooa | Merge branch 'weblate-extract' into 'develop' | not-applicable | Merge wrapper for Weblate extraction only. | No code backport needed. |
| `16b06160a` | 2022-10-14 | Haelwenn (lanodan) Monnier | CommonAPI: generate ModerationLog for all admin/moderator deletes | implemented | CommonAPI inserts moderation logs for deletes, and admin status delete tests assert log entries. | No code backport needed. |
| `705ba6d61` | 2022-10-15 | Haelwenn | Merge branch 'security/PleromaAPI-delete' into 'develop' | implemented | Merge wrapper for CommonAPI delete moderation logging. | No code backport needed. |
| `1958f23fe` | 2022-09-30 | Mark Felder | Fix deprecation warning for Gun timeout | implemented | Gun configuration uses connect_timeout and recv_timeout terminology and current descriptions, avoiding the old timeout deprecation path. | No code backport needed. |
| `7a519b6a6` | 2022-10-24 | feld | Merge branch 'fix-deprecation-text' into 'develop' | implemented | Merge wrapper for Gun timeout deprecation wording. | No code backport needed. |
| `1b238a4fa` | 2022-10-01 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Push.Impl: support edits | implemented | Web push implementation includes Update activity support and formats status edit push notifications. | No code backport needed. |
| `9fbf01f7a` | 2022-10-27 | tusooa | Merge branch 'push-updates' into 'develop' | implemented | Merge wrapper for edit push notification support. | No code backport needed. |
| `50923f543` | 2022-09-08 | Tusooa Zhu | Fix User.get_or_fetch/1 with usernames starting with http | implemented | User.get_or_fetch treats http and https strings as ActivityPub IDs, and tests cover HTTP-style user lookup and search. | No code backport needed. |
| `da0ef154a` | 2022-10-30 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/2930-get-or-fetch' into 'develop' | implemented | Merge wrapper for http-prefixed get_or_fetch handling. | No code backport needed. |
| `4121bca89` | 2022-11-03 | Alexander Strizhakov | expanding WebFinger | implemented | Expanded WebFinger support is present with configurable domain handling, XML and JSON rendering, LRDD template fetches, and subdomain fixtures/tests. | No code backport needed. |
| `30ded8876` | 2022-11-03 | Alexander Strizhakov | docs & changelog | implemented | Docs and changelog for expanded WebFinger are represented by local WebFinger config and documentation context. | No code backport needed. |
| `5a9ea98ba` | 2022-11-03 | Alexander Strizhakov | XML WebFinger user representation correct domain | implemented | XML WebFinger rendering uses the configured WebFinger domain rather than assuming the endpoint host. | No code backport needed. |
| `a57c02559` | 2022-11-03 | Alexander Strizhakov | docs update | not-applicable | Documentation-only update for WebFinger expansion. | No code backport needed. |
| `8407e26b0` | 2022-11-03 | Alexander Strizhakov | rebase fix | implemented | Rebase fix for WebFinger expansion, with local WebFinger code containing the resulting behavior. | No code backport needed. |
| `127e7b8ff` | 2022-11-03 | Haelwenn | Merge branch 'feature/1469-webfinger-expanding' into 'develop' | implemented | Merge wrapper for expanded WebFinger support. | No code backport needed. |
| `f2e4b425e` | 2022-11-03 | tusooa | Document some caveats of webfinger domain setting | implemented | WebFinger domain caveats are covered by local configurable-domain handling and related docs/tests. | No code backport needed. |
| `9f708037d` | 2022-11-03 | feld | Merge branch 'tusooa/caveats-webfinger' into 'develop' | implemented | Merge wrapper for WebFinger caveat documentation. | No code backport needed. |
| `be411ad3b` | 2022-09-03 | Haelwenn (lanodan) Monnier | Test coverage: Switch to covertool to get cobertura output | implemented | Test coverage is configured for covertool with Cobertura output in GitLab CI. | No code backport needed. |
| `8d704d384` | 2022-11-06 | tusooa | Merge branch 'ci-coverage' into 'develop' | implemented | Merge wrapper for covertool and Cobertura coverage configuration. | No code backport needed. |
| `648e01202` | 2022-11-07 | Haelwenn (lanodan) Monnier | ObjectAgePolicy: Make strip_followers behavior for followers-only explicit | implemented | ObjectAgePolicy description and cheatsheet now explicitly document that strip_followers degrades followers-only posts to a direct activity. | No further action. |
| `481f50bcf` | 2022-11-07 | tusooa | Merge branch 'docs/object_age-strip_followers' into 'develop' | implemented | Merge wrapper for ObjectAgePolicy strip_followers behavior documentation. | No code backport needed. |
| `eb7067693` | 2022-11-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update links to Soapbox | superseded | Old Soapbox link updates are superseded by Unfathomably FE and BE branding and documentation links. | No code backport needed. |
| `39a96876e` | 2022-11-11 | lain | Merge branch 'soapbox-ref' into 'develop' | superseded | Merge wrapper for old Soapbox link update, superseded by Unfathomably branding. | No code backport needed. |
| `36519bdbe` | 2022-11-11 | IvaÃƒÅ’Ã‚Ân Raskovsky | allow custom db port | implemented | DB_PORT is honored in test, benchmark, and docker database configuration. | No code backport needed. |
| `e7c40c250` | 2022-11-11 | lain | fix envvar | implemented | DB_PORT environment-variable fix is present in local database configuration. | No code backport needed. |
| `ceb07772d` | 2022-11-11 | feld | Merge branch 'custom-db-port' into 'develop' | implemented | Merge wrapper for custom database port support. | No code backport needed. |
| `6b87b3f2e` | 2022-11-11 | Mark Felder | Remove Quack logging backend | implemented | Quack logging backend dependency and active config suggestions have been removed from current source. | No further action. |
| `8a3b45039` | 2022-11-11 | Mark Felder | Add migration to remove Quack from ConfigDB | implemented | DeprecateQuack migration removes Quack.Logger from ConfigDB backends. | No code backport needed. |
| `7d0175dc3` | 2022-11-11 | Mark Felder | Document removal of Quack | implemented | Quack removal is reflected in current docs and config descriptions without advertising Quack.Logger as a supported backend. | No further action. |
| `572751bec` | 2022-11-11 | Mark Felder | Clean up stale entries in mix.lock | implemented | mix.lock no longer carries Quack dependency entries. | No code backport needed. |
| `7c8618dc9` | 2022-11-12 | Haelwenn | Merge branch 'no-ducks' into 'develop' | implemented | Merge wrapper for Quack removal branch. | No code backport needed. |
| `6f047cc30` | 2022-11-09 | tusooa | Do not strip reported statuses when configured not to | implemented | report_strip_status config gates stripping reported statuses when reports are closed or resolved. | No code backport needed. |
| `717c5901f` | 2022-11-09 | tusooa | Render a generated reported activity properly | implemented | Admin report rendering uses Report.extract_report_info so generated and reported activity data renders safely. | No code backport needed. |
| `799136438` | 2022-11-11 | tusooa | Lint | not-applicable | Lint-only cleanup for report stripping branch. | No code backport needed. |
| `c2cfe0c69` | 2022-11-12 | Haelwenn | Clarify config description | implemented | Config description documents report_strip_status behavior. | No code backport needed. |
| `e3e68b937` | 2022-11-12 | tusooa | Update config cheatsheet | implemented | Cheatsheet and config documentation include report_strip_status behavior. | No code backport needed. |
| `1b0e47b79` | 2022-11-12 | tusooa | Merge branch 'from/upstream-develop/tusooa/no-strip-report' into 'develop' | implemented | Merge wrapper for no-strip-report branch. | No code backport needed. |
| `14871fecd` | 2022-11-12 | tusooa | Lint | not-applicable | Lint-only merge cleanup. | No code backport needed. |
| `f38cb4cca` | 2022-11-12 | tusooa | Merge branch 'from/upstream-develop/tusooa/no-strip-report' into 'develop' | implemented | Second merge wrapper for no-strip-report branch, with behavior already present. | No code backport needed. |
| `8be7f87e1` | 2022-11-11 | Mark Felder | Define sane Oban Worker timeouts | implemented | Core Oban workers define explicit timeout callbacks, with Unfathomably retaining long timeouts only where required for backup, archive, or import work. | No code backport needed. |
| `a977e1ef9` | 2022-11-12 | Mark Felder | Document Oban workers getting timeouts defined | implemented | Changelog and docs for Oban worker timeouts are reflected in current worker timeout callbacks and changelog history. | No code backport needed. |
| `3d1828f43` | 2022-11-12 | feld | Merge branch 'oban-timeouts' into 'develop' | implemented | Merge wrapper for Oban worker timeout definitions. | No code backport needed. |
| `3979eaf14` | 2022-11-12 | Dmytro Poltavchenko | Added translation using Weblate (Ukrainian) | implemented | Ukrainian gettext catalog files exist locally for config_descriptions, default, and errors. | No code backport needed. |
| `1c97a86b8` | 2022-11-12 | Dmytro Poltavchenko | Added translation using Weblate (Ukrainian) | implemented | Ukrainian gettext catalog files exist locally for config_descriptions, default, and errors. | No code backport needed. |
| `451c415fc` | 2022-11-12 | Dmytro Poltavchenko | Translated using Weblate (Ukrainian) | implemented | Ukrainian gettext updates are present locally. | No code backport needed. |
| `e86ca8a43` | 2022-11-13 | Haelwenn | Merge branch 'weblate' into 'develop' | implemented | Merge wrapper for Ukrainian Weblate catalogs. | No code backport needed. |
| `bdedc41cb` | 2022-11-04 | Thomas Citharel | Fix typo in CSP Report-To header name | implemented | HTTP security plug uses the current report-to header spelling and tests cover report-to and report-uri CSP headers. | No code backport needed. |
| `a2db64b12` | 2022-11-13 | Haelwenn | Merge branch 'fix-typo-in-csp-report-to-header-name' into 'develop' | implemented | Merge wrapper for CSP report-to spelling fix. | No code backport needed. |
| `b2713357b` | 2022-11-13 | Haelwenn (lanodan) Monnier | Object.Fetcher: Set reachable on successful fetch | implemented | ObjectFetcher marks instances reachable on successful remote object fetches. | No code backport needed. |
| `76ed0da09` | 2022-11-14 | lain | Merge branch 'bugfix/reset-unreachable-on-fetch' into 'develop' | implemented | Merge wrapper for setting reachable on successful fetch. | No code backport needed. |
| `47b9847ed` | 2022-11-13 | Mark Felder | Deletes do not generate notifications of any kind, so skip trying | implemented | Delete activities no longer generate notifications because delete handling skips notification creation. | No code backport needed. |
| `2e0089dd5` | 2022-11-13 | Mark Felder | Alter priority of Delete activities to be lowest | implemented | Incoming and outgoing Delete federation jobs use lower priority than ordinary federation work. | No code backport needed. |
| `0e1356ef9` | 2022-11-14 | lain | Merge branch 'akkoma/delete-improvements' into 'develop' | implemented | Merge wrapper for delete federation priority and notification improvements. | No code backport needed. |
| `db76ea578` | 2022-11-17 | Henry Jameson | try to fix ruffle on chrome | implemented | CSP script-src includes wasm-unsafe-eval for Ruffle and Chrome compatibility. | No code backport needed. |
| `79bd363a6` | 2022-11-17 | HJ | Update lib/pleroma/web/plugs/http_security_plug.ex | implemented | HTTP security plug keeps the wasm-unsafe-eval CSP update. | No code backport needed. |
| `a31d3589e` | 2022-11-17 | HJ | Update http_security_plug.ex | implemented | Follow-up HTTP security plug update is reflected in local CSP handling. | No code backport needed. |
| `cddcafee7` | 2022-11-17 | Mark Felder | Document inclusion of wasm-unsafe-eval | implemented | Changelog and docs for wasm-unsafe-eval are reflected in current CSP and changelog history. | No code backport needed. |
| `bb63f72c1` | 2022-11-17 | feld | Merge branch 'flash-support-csp' into 'develop' | implemented | Merge wrapper for flash and Ruffle CSP support. | No code backport needed. |
| `c7a0df800` | 2022-11-18 | Mark Felder | Remove Quack from docs and cheatsheet | implemented | Active docs and config descriptions no longer advertise Quack.Logger as a supported logging backend. | No further action. |
| `f40ccce7e` | 2022-11-18 | feld | Merge branch 'quack-docs' into 'develop' | implemented | Merge wrapper for Quack docs removal. | No code backport needed. |
| `4d321be05` | 2022-11-12 | FloatingGhost | Extract deactivated users query to a join | implemented | Activity queries restrict deactivated actors through a join on users.is_active instead of loading users separately. | No code backport needed. |
| `749445dd5` | 2022-11-12 | Mark Felder | Fix reports which do not have a user | implemented | ActivityPub report fetching preserves Flag activities from the deactivated-user restriction path so reports without an ordinary user still render. | No code backport needed. |
| `edaf0a05f` | 2022-11-12 | Mark Felder | Add same optimized join for excluding invisible users | implemented | ActivityPub queries exclude invisible actors through an optimized join on users.invisible. | No code backport needed. |
| `39b24cdce` | 2022-11-12 | Mark Felder | Document query performance improvement | implemented | Query performance documentation is represented by the optimized deactivated and invisible actor joins in the local implementation. | No code backport needed. |
| `a9d991d31` | 2022-11-14 | feld | Merge branch 'develop' into 'akoma/deactivated-users' | implemented | Merge synchronization for deactivated and invisible user query improvements. | No code backport needed. |
| `7f0b3161e` | 2022-11-20 | Haelwenn | Merge branch 'akoma/deactivated-users' into 'develop' | implemented | Merge wrapper for deactivated and invisible user query improvements. | No code backport needed. |
| `f531099d2` | 2022-11-27 | Jeremy Huffman | Skip two unicode/kanji tests that can't pass on Mac. | not-applicable | Mac-only Unicode and Kanji test skip. | No code backport needed. |
| `3b289a164` | 2022-11-27 | Haelwenn | Merge branch 'skip-kanji-mac' into 'develop' | not-applicable | Merge wrapper for Mac-only test skip. | No code backport needed. |
| `8f3e75053` | 2022-11-27 | Haelwenn (lanodan) Monnier | scrubbers: Scrub img class attribute | implemented | Default and TwitterText scrubbers only allow img class emoji and tests cover image class scrubbing. | No code backport needed. |
| `f6d55e1e7` | 2022-11-27 | Haelwenn (lanodan) Monnier | Mergeback of release 2.4.5 | implemented | Release 2.4.5 mergeback content is covered by neighboring reviewed rows. | No code backport needed. |
| `36789986c` | 2022-11-27 | Haelwenn | Merge branch 'mergeback/2.4.5' into 'develop' | implemented | Develop merge wrapper for 2.4.5 mergeback content. | No code backport needed. |
| `0f88c2bca` | 2022-11-28 | ave | Change follow_operation schema to use type BooleanLike | implemented | Account follow OpenAPI schema uses BooleanLike for boolean-like request fields. | No code backport needed. |
| `3394394e0` | 2022-11-28 | Haelwenn | Merge branch 'develop' into 'develop' | implemented | Merge-only wrapper for already-reviewed follow schema work. | No code backport needed. |
| `d6cd447cf` | 2022-11-27 | Haelwenn (lanodan) Monnier | CHANGELOG.md: Fix date for 2.4.5 | not-applicable | Historical changelog date fix for an old upstream release. | No code backport needed. |
| `20790c1dd` | 2022-11-28 | Haelwenn | Merge branch 'mergeback/2.4.5' into 'develop' | not-applicable | Mergeback wrapper for old 2.4.5 release metadata. | No code backport needed. |
| `3e8f49be6` | 2022-12-01 | Xnuk Shuman | Added translation using Weblate (Korean) | implemented | Korean gettext catalog exists locally. | No code backport needed. |
| `eb7f4bc51` | 2022-12-05 | Haelwenn | Merge branch 'weblate' into 'develop' | implemented | Merge wrapper for Korean Weblate catalog work. | No code backport needed. |
| `b6e96f63b` | 2022-12-06 | Haelwenn (lanodan) Monnier | CI: Tag amd64 releases for amd64 runners | superseded | Old GitLab amd64 runner tagging is superseded by the current Unfathomably release and deployment pipeline. | No code backport needed. |
| `f60cb0f77` | 2022-12-05 | Haelwenn | Merge branch 'ci/amd64-build-tags' into 'develop' | superseded | Merge wrapper for old upstream GitLab runner tagging, superseded by current release tooling. | No code backport needed. |
| `8afad1e46` | 2022-12-06 | jrabbit | reccomend tagged releases  over pulling stable | implemented | Source update documentation recommends checking out tagged releases instead of blindly pulling stable. | No code backport needed. |
| `633a76b5b` | 2022-12-06 | lain | Merge branch 'jrabbit-develop-patch-67125' into 'develop' | implemented | Merge wrapper for tagged-release update documentation. | No code backport needed. |
| `1eb3ce956` | 2022-11-28 | Haelwenn (lanodan) Monnier | Add Gitlab ReleaseÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ into Release MR template | implemented | Release merge request template includes release-tag checklist coverage. | No code backport needed. |
| `1036acb6a` | 2022-12-06 | tusooa | Merge branch 'release-template' into 'develop' | implemented | Merge wrapper for release-template documentation. | No code backport needed. |
| `a69e9ae2e` | 2022-11-19 | tusooa | Flag an Object, not an Activity | implemented | Report Flag data stores reported objects rather than Create activities, with common API tests covering object AP IDs. | No code backport needed. |
| `0e0c316c7` | 2022-11-20 | tusooa | Fix report api | implemented | Report API helper extracts report objects and admin report tests cover generated report rendering. | No code backport needed. |
| `9d99e76a3` | 2022-11-20 | tusooa | Fix unit tests | implemented | Unit-test follow-up for report object semantics is represented in current report and common API tests. | No code backport needed. |
| `afe4bb230` | 2022-11-20 | tusooa | Fix UtilsTest | implemented | Utils tests cover Flag object generation for current report semantics. | No code backport needed. |
| `da0c68434` | 2022-12-08 | tusooa | Add tests for flagging non-Create activities | implemented | Utils tests cover flagging non-Create activities. | No code backport needed. |
| `204fd6faa` | 2022-12-09 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/report-fake' into 'develop' | implemented | Merge wrapper for report object semantics and tests. | No code backport needed. |
| `62c27e016` | 2022-12-14 | tusooa | Fix failure when registering a user with no email when approval required | implemented | User registration handles approval-required accounts without email and has regression coverage. | No code backport needed. |
| `c0cfc454b` | 2022-12-15 | lain | Merge branch 'from/upstream-develop/tusooa/register-approval' into 'develop' | implemented | Merge wrapper for no-email approval-required registration fix. | No code backport needed. |
| `7c64f705f` | 2022-11-03 | Mark Felder | Update to Phoenix 1.6 and chase dependencies | superseded | Phoenix and related dependencies have advanced well beyond the old Phoenix 1.6 update branch. | No code backport needed. |
| `e9c3be262` | 2022-11-13 | Mark Felder | Bump credo | superseded | Credo has advanced beyond the old bump and current mix aliases use stricter Credo checks. | No code backport needed. |
| `2186e9b62` | 2022-11-13 | Mark Felder | Tell newer Credo it's OK to exit 0 on single with clauses and piping into anonymous functions for now | superseded | Old Credo single-clause workaround is superseded by the current strict Credo configuration and warning cleanup. | No code backport needed. |
| `63d00f812` | 2022-12-15 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into update-deps | superseded | Merge wrapper for old dependency update branch, superseded by current dependency train. | No code backport needed. |
| `9838790a7` | 2022-12-15 | Lain Soykaf | AttachmentValidator: Actually require url | implemented | AttachmentValidator requires the embedded url collection through cast_embed required true, and URL entries require href and mediaType. | No code backport needed. |
| `4a32b584e` | 2022-12-15 | Lain Soykaf | StatusView: Fix warning | implemented | StatusView warning cleanup is already represented in the current warning-cleaned status view code. | No code backport needed. |
| `bb27e4134` | 2022-12-15 | Lain Soykaf | AudioVideoValidator: Fix embedded attachment requirements | implemented | AudioImageVideoValidator requires embedded attachments through cast_embed required true while validation keeps upstream field requirements. | No code backport needed. |
| `301eb86b3` | 2022-12-16 | lain | Merge branch 'update-deps' into 'develop' | implemented | Merge wrapper for dependency and validator fixes. | No code backport needed. |
| `452595bae` | 2022-12-11 | duponin | Uploading an avatar media exceeding max size returns a 413 | implemented | Oversized avatar uploads return HTTP 413 with schema coverage and update-credentials tests. | No code backport needed. |
| `987674235` | 2022-12-11 | duponin | Return 413 when an actor's banner or background exceeds the size limit | implemented | Oversized banner and background uploads return HTTP 413 with update-credentials tests. | No code backport needed. |
| `a3985aac9` | 2022-12-16 | tusooa | Merge branch 'fix-2856' into 'develop' | implemented | Merge wrapper for media upload 413 behavior. | No code backport needed. |
| `cfca9544e` | 2022-12-16 | weblate-extractor | Extract translatable strings | not-applicable | Gettext extraction only. | No code backport needed. |
| `59eaab3e7` | 2022-12-16 | tusooa | Merge branch 'weblate-extract' into 'develop' | not-applicable | Merge wrapper for gettext extraction only. | No code backport needed. |
| `8e6f2624a` | 2022-12-16 | Lain Soykaf | CI: Fix image for amd64-musl | superseded | Old amd64-musl CI image fix is superseded by the current Unfathomably build and Docker scripts. | No code backport needed. |
| `8db82932a` | 2022-12-16 | lain | Merge branch 'fix-amd64-musl' into 'develop' | superseded | Merge wrapper for old amd64-musl CI image fix. | No code backport needed. |
| `60df2d8a9` | 2022-12-18 | Sean King | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into fine_grained_moderation_privileges | implemented | Fine-grained moderation privileges are present through User.privileged and configured admin and moderator privilege sets. | No code backport needed. |
| `c58eb873d` | 2022-12-18 | Sean King | Fix CommonAPI delete function to use User.privileged? instead of User.superuser? | implemented | CommonAPI delete uses User.privileged for message deletion rather than admin-only superuser checks. | No code backport needed. |
| `3f0783c0a` | 2022-12-19 | faried nawaz | fix atom and rss feeds for users and tags | implemented | RSS and Atom feed templates and FeedView include the upstream feed generation fixes. | No code backport needed. |
| `f3253c0c6` | 2022-12-19 | Mark Felder | Implement RFC2822 timestamp formatting | implemented | FeedView implements RFC2822 timestamp formatting and RSS templates use it. | No code backport needed. |
| `8d500977a` | 2022-12-19 | faried nawaz | fix: feed item title was escaped twice | implemented | Feed title rendering avoids the old double-escape path through current FeedView preparation. | No code backport needed. |
| `3f63caee2` | 2022-12-19 | faried nawaz | fix: add xmlns:thr for in-reply-to refs | implemented | User and tag feed templates include xmlns:thr and in-reply-to references. | No code backport needed. |
| `f597b1b3e` | 2022-12-19 | faried nawaz | remove ap_id test -- the element makes the feed break | not-applicable | Old feed test expectation cleanup only. | No code backport needed. |
| `0f67eab38` | 2022-12-19 | faried nawaz | remove pub_date() -- use to_rfc2822 instead | implemented | Feed templates and tests use FeedView.to_rfc2822 instead of the old pub_date helper. | No code backport needed. |
| `c49316fae` | 2022-12-19 | faried nawaz | modify user feed controller test to expect summary for title | implemented | User feed controller tests cover summary-derived title behavior. | No code backport needed. |
| `96cfc9575` | 2022-12-19 | faried nawaz | document rss/atom fix in changelog | implemented | RSS and Atom feed fixes are represented by current feed code and changelog history. | No code backport needed. |
| `fce299848` | 2022-12-19 | faried nawaz | use to_rfc2822 instead of pub_date in tests, too | implemented | Feed tests use to_rfc2822 for RSS date expectations. | No code backport needed. |
| `72d4d1b39` | 2022-12-19 | Mark Felder | Fix TwitterCard meta tags | implemented | TwitterCard metadata provider emits current twitter meta tags and has provider tests. | No code backport needed. |
| `1946b49eb` | 2022-12-19 | feld | Merge branch 'fix-twittercard-tags' into 'develop' | implemented | Merge wrapper for TwitterCard metadata fixes. | No code backport needed. |
| `3dfa009ec` | 2022-12-19 | lain | Merge branch 'develop' into 'fix/2980-rss-feed-generation' | implemented | Merge synchronization for RSS feed generation branch. | No code backport needed. |
| `3311e0efe` | 2022-12-20 | lain | Merge branch 'fix/2980-rss-feed-generation' into 'develop' | implemented | Merge wrapper for RSS feed generation fixes. | No code backport needed. |
| `1d9501275` | 2022-12-19 | Sean King | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into fine_grained_moderation_privileges | implemented | Merge synchronization for fine-grained moderation privileges. | No code backport needed. |
| `dc7efcd08` | 2022-12-15 | tusooa | Make TagPolicy Update-aware | implemented | TagPolicy handles Update activities for attachment removal and sensitivity filtering, with tests. | No code backport needed. |
| `255402809` | 2022-12-15 | tusooa | Make SimplePolicy Update-aware | implemented | SimplePolicy handles Update activities for attachment and media policy filtering, with tests. | No code backport needed. |
| `c6dff687c` | 2022-12-20 | lain | Merge branch 'from/upstream/develop/tusooa/mrf-updates' into 'develop' | implemented | Merge wrapper for MRF Update-aware policy fixes. | No code backport needed. |
| `7b56690af` | 2022-01-22 | Finn Behrens | add nixos to supported distros | implemented | NixOS installation documentation exists locally. | No code backport needed. |
| `7aa17cd65` | 2022-12-20 | lain | Merge branch 'doc_readme_nixos' into 'develop' | implemented | Merge wrapper for NixOS supported distro documentation. | No code backport needed. |
| `d5d4c7c11` | 2022-12-19 | Sean King | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into fine_grained_moderation_privileges | implemented | Merge synchronization for fine-grained moderation branch. | No code backport needed. |
| `a24b2bc38` | 2021-01-06 | lain | Resilience Test: Add tests for killing likes. | implemented | Resilience tests cover behavior after deleting like activities. | No code backport needed. |
| `07bf36142` | 2021-01-06 | lain | Resilience Test: Add notification check for killing likes. | implemented | Resilience tests cover notification behavior after deleting like activities. | No code backport needed. |
| `0840ce567` | 2022-12-20 | lain | Merge branch 'deletion-resilience' into 'develop' | implemented | Merge wrapper for deletion-resilience test coverage. | No code backport needed. |
| `e07fb6e7d` | 2022-12-19 | Sean King | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into fine_grained_moderation_privileges | implemented | Merge synchronization for fine-grained moderation branch. | No code backport needed. |
| `b3d250a70` | 2022-12-20 | weblate-extractor | Extract translatable strings | not-applicable | Gettext extraction only. | No code backport needed. |
| `5910d58cf` | 2022-12-20 | lain | Merge branch 'weblate-extract' into 'develop' | not-applicable | Merge wrapper for gettext extraction only. | No code backport needed. |
| `3bb78ac15` | 2022-12-21 | Sean King | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into fine_grained_moderation_privileges | implemented | Merge synchronization for fine-grained moderation branch. | No code backport needed. |
| `351b5a9df` | 2022-12-21 | Sean King | Use crazy hack to finally get pleroma:report notifications not visible after revoking privileges | implemented | Notification listing filters pleroma report notifications by current report-management privilege. | No code backport needed. |
| `90681c720` | 2022-12-21 | Sean King | Make lint happy | not-applicable | Lint-only follow-up for fine-grained moderation branch. | No code backport needed. |
| `718ff64c3` | 2022-12-23 | Haelwenn | Merge branch 'fine_grained_moderation_privileges' into 'develop' | implemented | Merge wrapper for fine-grained moderation privileges. | No code backport needed. |
| `cf1d91c71` | 2022-12-21 | Haelwenn (lanodan) Monnier | Update AdminFE bundle to version 2.5.0 | superseded | AdminFE bundle bump is superseded by Unfathomably FE and current embedded frontend handling. | No code backport needed. |
| `99ff91584` | 2022-12-23 | Haelwenn | Merge branch 'adminfe-2.5.0' into 'develop' | superseded | Merge wrapper for old AdminFE bundle bump. | No code backport needed. |
| `2c5bc9cff` | 2022-12-23 | Haelwenn (lanodan) Monnier | Update PleromaFE bundle to 2.5.0 | superseded | PleromaFE bundle bump is superseded by Unfathomably FE. | No code backport needed. |
| `6bce88b9e` | 2022-12-23 | Haelwenn | Merge branch 'pleromafe-2.5.0' into 'develop' | superseded | Merge wrapper for old PleromaFE bundle bump. | No code backport needed. |
| `7d68d64d6` | 2022-12-23 | Haelwenn (lanodan) Monnier | Merge back 2.4.5 | not-applicable | Historical 2.4.5 mergeback metadata. | No code backport needed. |
| `3fbd42061` | 2022-12-23 | Haelwenn (lanodan) Monnier | Revert "Delete report notifs when demoting from superuser" | implemented | Report notifications are retained when report privileges are lost, relying on current privilege filtering instead of database deletion. | No further action. |
| `5ce7db455` | 2022-12-23 | Haelwenn (lanodan) Monnier | Git merge is not my favorite tool | not-applicable | Merge conflict cleanup for old release branch. | No code backport needed. |
| `ee7694fa9` | 2022-12-23 | Haelwenn (lanodan) Monnier | CHANGELOG: Set 2.5.0 | not-applicable | Historical upstream changelog version marker. | No code backport needed. |
| `91c22637d` | 2022-12-23 | Haelwenn (lanodan) Monnier | mix: Release 2.5.0 | not-applicable | Historical upstream release version marker. | No code backport needed. |
| `f76c1d4f7` | 2022-12-23 | Haelwenn | Merge branch 'release/2.5.0' into 'stable' | not-applicable | Historical stable release merge. | No code backport needed. |
| `6126f203d` | 2022-12-23 | Haelwenn (lanodan) Monnier | mix: version 2.5.50 | not-applicable | Historical upstream develop version marker. | No code backport needed. |
| `b367f2225` | 2022-12-23 | Haelwenn | Merge branch 'mergeback/2.5.0' into 'develop' | not-applicable | Historical mergeback after 2.5.0 release. | No code backport needed. |
| `64eef1eae` | 2022-12-24 | weblate-extractor | Extract translatable strings | not-applicable | Gettext extraction only. | No code backport needed. |
| `2bc691113` | 2022-12-24 | Haelwenn | Merge branch 'weblate-extract' into 'develop' | not-applicable | Merge wrapper for gettext extraction only. | No code backport needed. |
| `10886eeaa` | 2023-01-01 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Bump copyright year | superseded | Copyright-year bump was later reverted upstream and legacy Pleroma headers remain intentionally preserved in many files. | No code backport needed. |
| `0fe3f749e` | 2023-01-02 | Haelwenn | Merge branch 'copyright-bump' into 'develop' | superseded | Merge wrapper for copyright bump later reverted upstream. | No code backport needed. |
| `e853cfe7c` | 2023-01-02 | lain | Revert "Merge branch 'copyright-bump' into 'develop'" | not-applicable | Upstream reverted the copyright bump. | No code backport needed. |
| `a0cdc4cf9` | 2023-01-02 | lain | Merge branch 'revert-0fe3f749' into 'develop' | not-applicable | Merge wrapper for copyright-bump revert. | No code backport needed. |
| `72b3ec35f` | 2023-01-03 | Lain Soykaf | Fix warnings in tests, treat warnings as errors in CI. | implemented | Project compilation supports warnings-as-errors and strict warning-oriented aliases, with warning cleanup already backported broadly. | No code backport needed. |
| `b3a1cfaa7` | 2023-01-03 | Lain Soykaf | Tests: Capture logs to clean up the test output. | implemented | Noisy tests use capture_log tags and helpers where appropriate. | No code backport needed. |
| `2eec3f820` | 2023-01-03 | Lain Soykaf | B TestHelper: Remove warnings-as-errors | superseded | Old removal of warnings-as-errors is superseded by Unfathomably's stricter release-engineering stance. | No code backport needed. |
| `4b66f2b7f` | 2022-12-28 | tusooa | Bump earmark to 1.4.22 | superseded | Earmark parser is newer than the old 1.4.22 bump through current dependency resolution. | No code backport needed. |
| `51b451325` | 2023-01-03 | lain | Merge branch 'tusooa/earmark' into 'develop' | superseded | Merge wrapper for old Earmark bump, superseded by current dependency train. | No code backport needed. |
| `5b4962165` | 2023-01-05 | Dmytro Poltavchenko | Added SVG to formats not compatible with exiftool | implemented | Exiftool StripLocation skips image/svg content types as incompatible with exiftool. | No code backport needed. |
| `fe00fbfd5` | 2023-01-05 | Lain Soykaf | B StripLocation: Add test, work for all svgs. | implemented | StripLocation tests cover webp, heic, svg, and svg+xml as no-op formats. | No code backport needed. |
| `2a244b391` | 2023-01-05 | lain | Merge branch '2768-strip-location' into 'develop' | implemented | Merge wrapper for StripLocation SVG handling. | No code backport needed. |
| `e412363ff` | 2023-02-09 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into test-warnings | superseded | Merge synchronization for old test-warnings branch, superseded by current warning-cleaned tree. | No code backport needed. |
| `8583b3721` | 2023-02-09 | Lain Soykaf | B TestHelper, CI: Work with older elixir version. | superseded | Old CI compatibility with older Elixir is superseded by the current supported Elixir and release pipeline. | No code backport needed. |
| `16276c8f8` | 2023-02-09 | lain | Merge branch 'test-warnings' into 'develop' | superseded | Merge wrapper for old test-warnings branch. | No code backport needed. |
| `7467b2473` | 2023-01-18 | tusooa | Fix block_from_stranger setting | implemented | Notification settings use block_from_strangers consistently, with tests covering stranger notification blocking. | No code backport needed. |
| `4d3c2fb21` | 2023-02-09 | lain | Merge branch 'tusooa/notif-setting' into 'develop' | implemented | Merge wrapper for block_from_strangers notification setting fix. | No code backport needed. |
| `bea43aba3` | 2022-12-29 | Mark Felder | Fix rel="me" | implemented | RelMe parsing and profile-field rel-me verification are present in current user and metadata code. | No code backport needed. |
| `39e4b788a` | 2022-12-30 | Mark Felder | Remove unwanted code specific to MIX_ENV=test | implemented | RelMe behavior no longer depends on MIX_ENV test-specific code in the current implementation. | No code backport needed. |
| `50abb54d1` | 2023-02-09 | lain | Merge branch 'fix-relme' into 'develop' | implemented | Merge wrapper for RelMe fixes. | No code backport needed. |
| `bc7ec4317` | 2023-01-26 | tusooa | Allow customizing instance languages | implemented | Instance languages are configurable and rendered through instance API responses. | No code backport needed. |
| `724bf7c64` | 2023-02-09 | lain | Merge branch 'tusooa/3055-instance-languages' into 'develop' | implemented | Merge wrapper for configurable instance languages. | No code backport needed. |
| `1cf20184f` | 2023-01-18 | tusooa | Use versioned image from hexpm | superseded | Old Docker image pinning to a versioned HexPM image is superseded by current Unfathomably build scripts and Dockerfile. | No code backport needed. |
| `a7079057a` | 2023-02-09 | lain | Merge branch 'tusooa/docker-hexpm' into 'develop' | superseded | Merge wrapper for old Docker HexPM image pinning. | No code backport needed. |
| `bddcb3ed6` | 2023-01-15 | tusooa | Add names to additionalProperties | implemented | OpenAPI schemas use explicit named additionalProperties in property maps such as fields_attributes. | No code backport needed. |
| `3b4b84b74` | 2023-01-15 | tusooa | Force spec for every operation to have a listed tag | implemented | OpenAPI operations have explicit tags and CastAndValidate enforces operation IDs. | No code backport needed. |
| `5af9ce4a0` | 2023-01-15 | tusooa | Fix type of admin_account.is_confirmed | implemented | Admin and account API tests cover is_confirmed as a boolean field. | No code backport needed. |
| `97f947dea` | 2023-01-15 | tusooa | Fix tests | not-applicable | Test follow-up for OpenAPI schema corrections. | No code backport needed. |
| `755279e25` | 2023-02-09 | lain | Merge branch 'tusooa/api-spec-property-map' into 'develop' | implemented | Merge wrapper for OpenAPI property-map corrections. | No code backport needed. |
| `08132002d` | 2023-02-03 | tusooa | Fix inproper content being cached in report content | implemented | Report fake activities use unique fake IDs so deleted reported statuses render cached content correctly. | No code backport needed. |
| `00b39dea5` | 2023-02-09 | lain | Merge branch 'tusooa/3059-report-fake-create-render' into 'develop' | implemented | Merge wrapper for report fake activity content rendering fix. | No code backport needed. |
| `55a8aa978` | 2023-02-08 | Alexander Tumin | Require related object for notifications to filter on content | implemented | Notification content filtering allows related objects without content and has regression coverage. | No code backport needed. |
| `7abb248ce` | 2023-02-09 | lain | Merge branch 'notification-content-filtering-noobj' into 'develop' | implemented | Merge wrapper for notification filtering related-object fix. | No code backport needed. |
| `686fef59d` | 2023-01-06 | tusooa | Test that zwnj is treated as word char in hashtags | implemented | CommonAPI tests cover zero-width non-joiner as a hashtag word character. | No code backport needed. |
| `09ed8f4f8` | 2023-01-06 | tusooa | Test double dot link | implemented | CommonAPI tests cover double-dot links under the current Linkify dependency. | No code backport needed. |
| `a2766f310` | 2023-01-06 | tusooa | Bump linkify | implemented | Linkify is at 0.5.3, covering the old Linkify bump. | No code backport needed. |
| `7138910f3` | 2023-02-09 | lain | Update mix.exs | superseded | Old mix.exs dependency adjustment is superseded by the current dependency train. | No code backport needed. |
| `d0b781ab6` | 2023-02-09 | lain | Merge branch 'from/upstream-develop/tusooa/2974-zwnj' into 'develop' | implemented | Merge wrapper for Linkify zero-width and double-dot fixes. | No code backport needed. |
| `bf346cf07` | 2023-02-09 | Sean King | Bump crypt to v1.0.1 | superseded | Crypt dependency bump is superseded by later removal of crypt support and current password stack. | No code backport needed. |
| `a5509de38` | 2023-02-13 | lain | Merge branch 'upgrade/crypt' into 'develop' | superseded | Merge wrapper for old crypt dependency bump. | No code backport needed. |
| `024bb27fc` | 2023-02-11 | tusooa | Ignores in exiftool read descriptions | implemented | Exiftool ReadDescription ignores unreadable or invalid description data and keeps safe nil fallbacks. | No code backport needed. |
| `19933a06b` | 2023-02-13 | lain | Merge branch 'tusooa/exiftool' into 'develop' | implemented | Merge wrapper for Exiftool read-description hardening. | No code backport needed. |
| `274b3a0d2` | 2023-02-18 | weblate-extractor | Extract translatable strings | not-applicable | Gettext extraction only. | No code backport needed. |
| `8a0162cd9` | 2023-02-19 | tusooa | Merge branch 'weblate-extract' into 'develop' | not-applicable | Merge wrapper for gettext extraction only. | No code backport needed. |
| `259905a89` | 2023-02-20 | tusooa | Bump earmark to 1.4.22 | superseded | Earmark parser is newer than the old 1.4.22 bump through current dependency resolution. | No code backport needed. |
| `e8fca8882` | 2023-02-20 | Dmytro Poltavchenko | Added SVG to formats not compatible with exiftool | implemented | Stable-branch copy of SVG Exiftool incompatibility handling is present locally. | No code backport needed. |
| `d5125e6ce` | 2023-02-20 | Lain Soykaf | B StripLocation: Add test, work for all svgs. | implemented | Stable-branch StripLocation tests for SVG and other incompatible formats are present locally. | No code backport needed. |
| `3ab340481` | 2023-02-20 | tusooa | Fix block_from_stranger setting | implemented | Stable-branch block_from_strangers setting fix is present locally. | No code backport needed. |
| `88ce0e8b2` | 2023-02-20 | Mark Felder | Fix rel="me" | implemented | Stable-branch RelMe fix is present in current RelMe parsing and profile-field verification. | No code backport needed. |
| `1b82fd95d` | 2023-02-20 | Mark Felder | Remove unwanted code specific to MIX_ENV=test | implemented | Stable-branch removal of MIX_ENV test-specific RelMe code is reflected in the current implementation. | No code backport needed. |
| `1c225bfd6` | 2023-02-20 | tusooa | Allow customizing instance languages | implemented | Stable-branch configurable instance languages are present locally. | No code backport needed. |
| `772d99c58` | 2023-02-20 | tusooa | Use versioned image from hexpm | superseded | Stable-branch Docker image pinning is superseded by current Unfathomably build tooling. | No code backport needed. |
| `8e8a0f005` | 2023-02-20 | tusooa | Fix inproper content being cached in report content | implemented | Stable-branch report fake activity content rendering fix is present locally. | No code backport needed. |
| `c3a070356` | 2023-02-20 | Alexander Tumin | Require related object for notifications to filter on content | implemented | Stable-branch notification filtering fix for contentless related objects is present locally. | No code backport needed. |
| `0e89a9ad1` | 2023-02-20 | tusooa | Test that zwnj is treated as word char in hashtags | implemented | Stable-branch zero-width non-joiner hashtag test is present locally. | No code backport needed. |
| `f2ed05191` | 2023-02-20 | tusooa | Test double dot link | implemented | Stable-branch double-dot link test is present locally. | No code backport needed. |
| `002159fc1` | 2023-02-20 | tusooa | Bump linkify | implemented | Stable-branch Linkify bump is superseded by Linkify 0.5.3. | No code backport needed. |
| `bb9ed51da` | 2023-02-20 | lain | Update mix.exs | superseded | Stable-branch mix.exs dependency adjustment is superseded by current dependencies. | No code backport needed. |
| `c69ae5f7c` | 2023-02-20 | Sean King | Bump crypt to v1.0.1 | superseded | Stable-branch crypt bump is superseded by later crypt removal and current bcrypt to pbkdf2 migration handling. | No code backport needed. |
| `410d50afe` | 2023-02-20 | tusooa | Ignores in exiftool read descriptions | implemented | Stable-branch Exiftool read-description hardening is present locally. | No code backport needed. |
| `db06e445f` | 2023-02-20 | tusooa | Compose changelog for 2.5.1 | not-applicable | Historical upstream 2.5.1 changelog composition. | No code backport needed. |
| `75b76a066` | 2023-02-20 | tusooa | Bump version in mix project to 2.5.1 | not-applicable | Historical upstream 2.5.1 version bump. | No code backport needed. |
| `5d34fe186` | 2023-02-20 | tusooa | Bundle frontend | superseded | Old bundled frontend artifact is superseded by Unfathomably FE and current embedded static deployment. | No code backport needed. |
| `e4925f813` | 2023-03-01 | tusooa | Sanitize filenames when uploading | implemented | ActivityPub upload normalizes Plug.Upload filenames with Path.basename and media and profile upload tests cover nested filename rejection. | No code backport needed. |
| `938e238ea` | 2023-03-01 | tusooa | Add the security fix to the changelog | implemented | Security changelog entry for upload filename sanitization is represented by current upload hardening history and audit documentation. | No code backport needed. |
| `fd46f83d2` | 2023-03-02 | tusooa | Merge branch 'release/2.5.1' into 'stable' | not-applicable | Historical upstream stable release merge. | No code backport needed. |
| `f33401f54` | 2023-03-01 | tusooa | Merge remote-tracking branch 'upstream/stable' into mergeback/2.5.1 | not-applicable | Historical 2.5.1 mergeback synchronization. | No code backport needed. |
| `714bf0cb2` | 2023-03-02 | tusooa | Merge branch 'mergeback/2.5.1' into 'develop' | not-applicable | Historical 2.5.1 mergeback wrapper. | No code backport needed. |
| `1babd0798` | 2023-03-01 | tusooa | Stop oban from retrying if validating errors occur when processing incoming data | implemented | ReceiverWorker cancels terminal validation errors and only retries recoverable missing-reference validation failures. | No code backport needed. |
| `bec4e5ac3` | 2023-03-01 | tusooa | Fix FederatorTest | implemented | Federator and ReceiverWorker tests cover cancellation of already-present and validation-style incoming failures. | No code backport needed. |
| `a0ec66ce7` | 2023-03-01 | tusooa | Make clear the test names | implemented | ReceiverWorker tests use clear names for malformed, duplicate, missing-reference, and terminal incoming job behavior. | No code backport needed. |
| `c00a19f37` | 2023-03-05 | Haelwenn | Merge branch 'tusooa/oban-common-pipeline' into 'develop' | implemented | Merge wrapper for Oban common-pipeline validation handling. | No code backport needed. |
| `8241eff05` | 2023-03-06 | faried nawaz | remove static_fe pipeline for /users/:nickname/feed | implemented | User feed routes are outside the static-fe pipeline, preventing static-fe feed redirects from producing 500s. | No code backport needed. |
| `0a042979b` | 2023-03-06 | Haelwenn | Merge branch 'fix/static-fe-feed-500' into 'develop' | implemented | Merge wrapper for static-fe feed route fix. | No code backport needed. |
| `f33e89765` | 2023-03-06 | faried nawaz | fix tag feeds: remote activities might not have a summary field | implemented | FeedView handles remote activities without summary fields by using empty-string fallbacks. | No code backport needed. |
| `d3f22d24f` | 2023-03-06 | faried nawaz | feed eex templates: use published field from @data, not @activity.data | implemented | Feed templates use the prepared data published field instead of raw activity data. | No code backport needed. |
| `117a53b88` | 2023-03-06 | faried nawaz | format feed_view.ex | not-applicable | Formatting-only follow-up for feed_view. | No code backport needed. |
| `86ee4b72f` | 2023-03-06 | faried nawaz | modify Utils.scrub_html_and_truncate to take omission parameter | implemented | Metadata scrub_html_and_truncate accepts an omission option used by feed title rendering. | No code backport needed. |
| `141146d1f` | 2023-03-06 | faried nawaz | use scrub_html_and_truncate instead of scrub_html for feed item title | implemented | Feed item titles use scrub_html_and_truncate with omission handling instead of raw scrub_html. | No code backport needed. |
| `7b42ec563` | 2023-03-06 | faried nawaz | oops, remove unused import | not-applicable | Unused import cleanup only. | No code backport needed. |
| `5cc23dc38` | 2023-03-06 | Haelwenn | Merge branch 'fix/tag-feed-crashes' into 'develop' | implemented | Merge wrapper for tag feed crash fixes. | No code backport needed. |
| `d83f16fe4` | 2023-02-28 | tusooa | Allow with_relationships param for blocks | implemented | Blocks endpoint supports with_relationships and has controller coverage. | No code backport needed. |
| `f5c6e4473` | 2023-03-09 | Haelwenn | Merge branch 'tusooa/block-rel' into 'develop' | implemented | Merge wrapper for with_relationships on blocks. | No code backport needed. |
| `5716654d1` | 2023-03-05 | Haelwenn (lanodan) Monnier | Remove crypt(3) support | implemented | crypt3 support is absent from the current password stack, while bcrypt migration and pbkdf2 verification remain supported. | No code backport needed. |
| `d18441e9c` | 2023-03-12 | tusooa | Indicate in changelog that removal of crypt is breaking | not-applicable | Historical changelog note for crypt removal. | No code backport needed. |
| `9145fd04f` | 2023-03-12 | tusooa | Merge branch 'remove-crypt' into 'develop' | implemented | Merge wrapper for crypt3 support removal. | No code backport needed. |
| `d5d764878` | 2023-02-18 | kPherox | feat: build rel me tags with profile fields | implemented | RelMe tags are built from profile fields and verified via user profile-field logic. | No code backport needed. |
| `83c741580` | 2023-03-15 | kPherox | fix: append field values to bio before parsing | implemented | RelMe profile-field handling appends field values to bio-derived profile URLs before parsing. | No code backport needed. |
| `c3600b610` | 2023-03-16 | Haelwenn | Merge branch 'feat/fields-rel-me-tag' into 'develop' | implemented | Merge wrapper for profile-field RelMe tag support. | No code backport needed. |
| `787e30c5f` | 2023-03-02 | floatingghost | Allow reacting with remote emoji when they exist on the post (#200) | implemented | Emoji reaction controller and tests support reacting with remote custom emoji present on the post. | No code backport needed. |
| `4b85d1c61` | 2023-03-02 | Alexander Tumin | Allow custom emoji reactions: Fix tests, mixed custom and unicode reactions | implemented | Custom emoji reaction tests cover mixed custom and unicode reactions. | No code backport needed. |
| `8d3b29aab` | 2023-03-02 | Alexander Tumin | Allow custom emoji reactions: add test for mixed emoji react, fix credo errors | implemented | Custom emoji reaction tests cover mixed reaction handling under current Credo-clean code. | No code backport needed. |
| `2c2ea16b5` | 2023-03-12 | Alexander Tumin | Allow custom emoji reactions: Add pleroma_custom_emoji_reactions feature, review changes | implemented | Instance features advertise pleroma_custom_emoji_reactions and reaction rendering supports custom emoji URLs. | No code backport needed. |
| `353538d16` | 2023-03-16 | Haelwenn | Merge branch 'pleroma-akkoma-emoji-port' into 'develop' | implemented | Merge wrapper for custom emoji reaction support. | No code backport needed. |
| `8e072baed` | 2023-03-05 | Haelwenn (lanodan) Monnier | docs: Be more explicit about the level of compatibility of OTP releases | implemented | OTP release documentation includes compatibility caveats for release flavor and distro support. | No code backport needed. |
| `bf9db7842` | 2023-03-16 | tusooa | Merge branch 'docs-otp-support' into 'develop' | implemented | Merge wrapper for OTP compatibility documentation. | No code backport needed. |
| `f463b7570` | 2023-03-23 | anemone | Set background worker timeout to 15 minutes | implemented | BackgroundWorker timeout is 900 seconds, matching the 15 minute upstream timeout. | No code backport needed. |
| `9c53d1fe1` | 2023-03-25 | Haelwenn | Merge branch 'background-timeout' into 'develop' | implemented | Merge wrapper for background worker timeout. | No code backport needed. |
| `ea07ec51e` | 2023-03-09 | Haelwenn (lanodan) Monnier | Add support for Image objects | implemented | ActivityPub ObjectValidator supports Image objects through AudioImageVideoValidator and constants include Image. | No code backport needed. |
| `6d0cc8fa2` | 2023-03-25 | Haelwenn | Merge branch 'features/image-object' into 'develop' | implemented | Merge wrapper for Image object support. | No code backport needed. |
| `c5d946bc9` | 2023-03-26 | tusooa | Fix emoji reactions for legacy 2-tuple formats | implemented | Emoji reaction controller normalizes legacy two-tuple reaction formats and tests cover legacy shapes. | No code backport needed. |
| `4f7c11b28` | 2023-03-27 | Haelwenn | Merge branch 'tusooa/3073-react-legacy' into 'develop' | implemented | Merge wrapper for legacy emoji reaction tuple handling. | No code backport needed. |
| `81e1d6d9d` | 2023-04-02 | AkiraFukushima | Add Fedistar as a desktop client in docs | superseded | Desktop client documentation updates are not relevant to Unfathomably runtime behavior. | No code backport needed. |
| `17f1b8d13` | 2023-04-02 | AkiraFukushima | Remove Roma from docs | superseded | Legacy Roma documentation removal is not relevant to Unfathomably runtime behavior. | No code backport needed. |
| `e5f36f9f8` | 2023-04-02 | AkiraFukushima | Update contact information for Whalebird and Fedistar | superseded | Whalebird and Fedistar contact documentation is not relevant to Unfathomably runtime behavior. | No code backport needed. |
| `78a6f5629` | 2023-04-01 | tusooa | Merge branch 'doc/add-fedistar' into 'develop' | superseded | Merge wrapper for desktop-client documentation updates. | No code backport needed. |
| `50d3209ce` | 2022-08-28 | Tusooa Zhu | Check for changelog in ci | superseded | Old GitLab changelog-check CI is superseded by the current Unfathomably release workflow and explicit changelog maintenance. | No code backport needed. |
| `27a8f6a8d` | 2022-08-28 | Tusooa Zhu | Prevent duplicate pipelines | superseded | Old duplicate-pipeline GitLab CI rule is superseded by current CI and deployment workflow. | No code backport needed. |
| `d3871fa36` | 2022-08-28 | Tusooa Zhu | Allow to explicitly skip changelog | superseded | Old changelog-skip CI flag is superseded by current release workflow. | No code backport needed. |
| `a26fb6ab4` | 2022-08-28 | Tusooa Zhu | Display error info | superseded | Old GitLab changelog-check script error display is superseded by the current release workflow. | No code backport needed. |
| `f8566e91a` | 2022-08-28 | Tusooa Zhu | Fix {} not working with alpine sh | superseded | Old Alpine shell fix for the upstream changelog-check script is superseded by the current workflow. | No code backport needed. |
| `6aa9b023f` | 2022-08-28 | Tusooa Zhu | Use dedicated script | superseded | Old dedicated changelog script is superseded by current Unfathomably release workflow. | No code backport needed. |
| `89a40b867` | 2023-04-04 | Haelwenn | Allow more than 1 changelog entry | superseded | Old changelog-check script support for multiple entries is superseded by current changelog maintenance. | No code backport needed. |
| `686c3e03b` | 2023-04-04 | tusooa | Fix counting | superseded | Old changelog-counting CI fix is superseded by current workflow. | No code backport needed. |
| `b7a831ca5` | 2023-04-05 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/require-changelog' into 'develop' | superseded | Merge wrapper for old changelog CI branch. | No code backport needed. |
| `ce16ff7ae` | 2023-04-04 | Haelwenn (lanodan) Monnier | mix: Update all dependencies | superseded | Dependency train has moved beyond this 2023 mix deps update. | No code backport needed. |
| `cf1ba77b9` | 2023-04-13 | Haelwenn | Merge branch '2023-04-mix-deps-update' into 'develop' | superseded | Merge wrapper for old dependency update branch. | No code backport needed. |
| `10930f750` | 2023-03-25 | tusooa | Dedupe poll options | implemented | Poll options are deduped with Enum.uniq before validation and Question construction. | No recheck. |
| `67d1897c6` | 2023-03-26 | tusooa | Fix existing tests | implemented | Poll dedupe test adjustments are represented by current status and common API tests. | No recheck. |
| `3867b52ae` | 2023-04-13 | Haelwenn | Merge branch 'tusooa/3027-dedupe-poll' into 'develop' | implemented | Merge wrapper for poll option dedupe. | No recheck. |
| `7997ba0ab` | 2023-04-12 | tusooa | Build images with kaniko | superseded | Kaniko CI image-building work is superseded by current Unfathomably Docker and build scripts. | No code backport needed. |
| `b37a90caa` | 2023-04-12 | tusooa | Combine images of different platforms into one | superseded | Multi-platform image combination for old GitLab CI is superseded by current build tooling. | No code backport needed. |
| `23bca0c4b` | 2023-04-12 | tusooa | Skip changelog entry | not-applicable | Changelog skip marker for old CI branch. | No code backport needed. |
| `66d23713e` | 2023-04-24 | tusooa | Do not use nested levels for arch | superseded | Old Docker image arch layout fix is superseded by current Docker and build tooling. | No code backport needed. |
| `2736c3f29` | 2023-04-24 | tusooa | Use --custom-platform to replace the deprecated one | superseded | Old Kaniko custom-platform flag update is superseded by current build tooling. | No code backport needed. |
| `c5ffdd060` | 2023-04-24 | tusooa | Use self-built elixir image for arm | superseded | Old self-built Elixir image for ARM CI is superseded by current toolchain and deployment scripts. | No code backport needed. |
| `6bd0df135` | 2023-04-25 | Haelwenn | Merge branch 'tusooa/kaniko' into 'develop' | superseded | Merge wrapper for old Kaniko CI work. | No code backport needed. |
| `9c7b03640` | 2023-04-25 | tusooa | Add ELIXIR_IMG arg to latest | superseded | Old ELIXIR_IMG Docker arg for latest image is superseded by current Docker and build tooling. | No code backport needed. |
| `47e95fe9f` | 2023-04-25 | tusooa | Add changelog for 3876 | not-applicable | Historical changelog entry for old Kaniko issue. | No code backport needed. |
| `3b2d7cc67` | 2023-04-26 | Haelwenn | Merge branch 'tusooa/kaniko' into 'develop' | superseded | Merge wrapper for old Kaniko CI work. | No code backport needed. |
| `a94691720` | 2023-04-26 | tusooa | Work around docker login needing daemon | superseded | Old Docker login workaround is superseded by current deployment workflow. | No code backport needed. |
| `1a50db36d` | 2023-04-26 | tusooa | Skip changelog entry for 3877 | not-applicable | Historical changelog skip marker. | No code backport needed. |
| `18913c4cd` | 2023-04-26 | Haelwenn | Merge branch 'tusooa/combine-login' into 'develop' | superseded | Merge wrapper for old Docker login workaround. | No code backport needed. |
| `0231a0931` | 2023-04-23 | duponin | Remove SSH/BBS feature from core | implemented | SSH/BBS core modules and dependency are absent; cheatsheet keeps the upstream external-client note. | No recheck. |
| `b2dc9ad9d` | 2023-04-23 | duponin | fix test after removing esshd/SSH feature | implemented | Tests no longer rely on the removed esshd SSH feature. | No recheck. |
| `af38c6104` | 2023-04-23 | duponin | add changelog entry for BBS/SSH feature remove | implemented | BBS/SSH removal note remains in documentation without shipping the removed core feature. | No recheck. |
| `d97425d49` | 2023-04-26 | lain | Merge branch 'duponin/remove-ssh' into 'develop' | implemented | Merge wrapper for SSH/BBS feature removal. | No recheck. |
| `d5e834594` | 2023-04-26 | tusooa | Do not use needs: in pipeline yaml | superseded | Old GitLab needs removal is superseded by current CI and release workflow. | No code backport needed. |
| `286b9bb66` | 2023-04-26 | Haelwenn | Merge branch 'tusooa/no-more-needs' into 'develop' | superseded | Merge wrapper for old GitLab needs cleanup. | No code backport needed. |
| `8f0f58e28` | 2023-04-18 | Haelwenn (lanodan) Monnier | UploadedMedia: Add missing disposition_type to Content-Disposition | implemented | UploadedMedia emits explicit inline Content-Disposition for named uploads. | No recheck. |
| `2148ef5e2` | 2023-04-18 | Haelwenn (lanodan) Monnier | UploadedMedia: Increase readability via ~s sigil | implemented | UploadedMedia Content-Disposition remains readable and explicit. | No recheck. |
| `ddf57596b` | 2023-04-26 | tusooa | Merge branch 'bugfix/content-disposition' into 'develop' | implemented | Merge wrapper for Content-Disposition fix. | No recheck. |
| `d3b27d45a` | 2023-03-29 | Ekaterina Vaartis | List installed frontend refs in admin API | implemented | Admin frontend API lists installed frontend refs. | No recheck. |
| `3037d2780` | 2023-03-30 | Ekaterina Vaartis | Also list frontends that are not in the config file | implemented | Admin frontend listing includes installed frontends not present in config. | No recheck. |
| `6a63dced4` | 2023-03-30 | Ekaterina Vaartis | Fix tests for frontend installation | implemented | Frontend installation and listing tests cover installed_refs behavior. | No recheck. |
| `248f914e6` | 2023-04-27 | tusooa | Merge branch 'list-installed-frontends' into 'develop' | implemented | Merge wrapper for installed frontend listing. | No recheck. |
| `163e82bab` | 2023-05-09 | tusooa | Allow lang attribute | implemented | Default scrubber allows lang attributes on safe tags. | No recheck. |
| `143676f58` | 2023-05-17 | Haelwenn | Merge branch 'tusooa/allow-lang' into 'develop' | implemented | Merge wrapper for lang attribute scrubber allowance. | No recheck. |
| `50e237759` | 2023-04-22 | tusooa | Use git diff to search for changelog entry | superseded | Old changelog-check script implementation detail is superseded by current workflow. | No code backport needed. |
| `e13b33176` | 2023-04-22 | tusooa | Fetch upstream in the repo | superseded | Old changelog-check upstream fetch behavior is superseded by this dedicated audit process. | No code backport needed. |
| `c1aa83069` | 2023-04-22 | tusooa | Skip changelog | not-applicable | Historical changelog skip marker. | No code backport needed. |
| `30bc37c3c` | 2023-04-22 | tusooa | Explain changelog.d in merge request templates | superseded | Old changelog.d MR-template documentation is superseded by current changelog workflow. | No code backport needed. |
| `ae8f359f2` | 2023-04-22 | tusooa | Skip changelog check for automated MRs | superseded | Old automated-MR changelog check exception is superseded by current workflow. | No code backport needed. |
| `99f157e28` | 2023-05-02 | tusooa | Fix MR pipelines not having build and test jobs | superseded | Old GitLab MR pipeline job fix is superseded by current CI and deployment workflow. | No code backport needed. |
| `6a3fd8e01` | 2023-05-02 | tusooa | Do not count for renames when diffing | superseded | Old changelog diff rename-counting fix is superseded by current workflow. | No code backport needed. |
| `b8b15cec9` | 2023-05-17 | Haelwenn | Merge branch 'tusooa/changelog-improve' into 'develop' | superseded | Merge wrapper for old changelog CI improvements. | No code backport needed. |
| `be5c5118c` | 2023-05-09 | tusooa | Make sure object refetching follows update rules | implemented | Object refetching goes through Object.Updater update-rule checks before replacing cached objects. | No recheck. |
| `e170fc40d` | 2023-05-09 | tusooa | Fix build warning | not-applicable | Build warning cleanup for object refetch branch. | No code backport needed. |
| `66327b56e` | 2023-05-17 | Haelwenn | Merge branch 'tusooa/rework-refetch' into 'develop' | implemented | Merge wrapper for object refetch update-rule branch. | No recheck. |
| `85bdbb102` | 2023-05-02 | tusooa | Add extraction process for oauth scopes | implemented | OAuth scope extraction compiler and translator are present. | No recheck. |
| `530284e1b` | 2023-05-02 | tusooa | Add extracted pot | implemented | OAuth scope gettext template support is present through the scope compiler. | No recheck. |
| `6d0ebccdb` | 2023-05-02 | tusooa | Make webui use translated scope descriptions | implemented | OAuth web UI renders translated scope descriptions. | No recheck. |
| `b6dd19400` | 2023-05-02 | tusooa | Add changelog | not-applicable | Historical changelog entry for OAuth scope translation. | No code backport needed. |
| `9283c784a` | 2023-05-02 | tusooa | Add English translation for oauth scopes | implemented | English OAuth scope translations are generated through the scope catalog. | No recheck. |
| `ce1c0f75c` | 2023-05-17 | Haelwenn | Merge branch 'tusooa/3065-scopes' into 'develop' | implemented | Merge wrapper for OAuth scope translation. | No recheck. |
| `c7dc5ce85` | 2022-12-29 | silverpill | TagValidator: Allow unrecognized Tag types | superseded | Unrecognized ActivityPub tag types are handled by the later drop-unrecognized-tags validator behavior. | No recheck. |
| `45646ff52` | 2022-12-30 | silverpill | TagValidator: Add test for Link tag | superseded | Link tag acceptance test is superseded by later drop-unrecognized-tags behavior. | No recheck. |
| `5cfb0578a` | 2023-02-27 | silverpill | TagValidator: Drop unrecognized tags | implemented | TagValidator ignores unrecognized tag types while retaining supported Mention Hashtag Emoji and Link tags. | No recheck. |
| `98b9c1bcb` | 2023-02-27 | silverpill | Merge branch 'develop' into accept-tags-2.5 | implemented | Merge synchronization for tag validator branch. | No recheck. |
| `0524e66a0` | 2023-05-17 | Haelwenn | Merge branch 'accept-tags-2.5' into 'develop' | implemented | Merge wrapper for tag validator behavior. | No recheck. |
| `505e58d4e` | 2023-05-22 | tusooa | Fix ObjectTest | implemented | Object test fix is represented by current Object tests. | No recheck. |
| `6aafa7fe7` | 2023-05-22 | tusooa | Add changelog | not-applicable | Historical changelog entry for object test fix. | No code backport needed. |
| `819a82da9` | 2023-05-22 | tusooa | Fix unused variable | not-applicable | Unused variable cleanup only. | No code backport needed. |
| `5433742fa` | 2023-05-23 | Haelwenn | Merge branch 'tusooa/fix-object-test' into 'develop' | implemented | Merge wrapper for object test fix branch. | No recheck. |
| `279fd47b4` | 2023-05-26 | Zero | ForceMentionsInContent: fix double mentions for Mastodon/Misskey posts | implemented | ForceMentionsInContent has Mastodon and Misskey duplicate-mention coverage. | No recheck. |
| `38bcf6b19` | 2023-05-26 | Mark Felder | MediaProxyController: Apply CSP sandbox | implemented | MediaProxyController applies sandbox CSP to proxied media. | No recheck. |
| `47e66c950` | 2023-05-26 | Haelwenn | Merge branch 'issue/3126' into 'develop' | implemented | Merge wrapper for CSP and OEmbed issue branch. | No recheck. |
| `0d68804aa` | 2023-05-26 | Mark Felder | Filter OEmbed HTML tags | implemented | OEmbed parser filters HTML tags from embedded content. | No recheck. |
| `cd9d6a12a` | 2023-05-26 | Haelwenn | Merge branch 'issue/3126' into 'develop' | implemented | Merge wrapper for OEmbed tag filtering. | No recheck. |
| `22b72cd6b` | 2023-03-30 | Haelwenn | Merge branch 'tusooa/oban-common-pipeline' into 'develop' | implemented | Merge wrapper for Oban common pipeline work already carried locally. | No recheck. |
| `d640df392` | 2023-03-30 | Haelwenn | Merge branch 'fix/static-fe-feed-500' into 'develop' | implemented | Merge wrapper for static-fe feed 500 fix already audited. | No recheck. |
| `937df7e46` | 2023-03-30 | Haelwenn | Merge branch 'fix/tag-feed-crashes' into 'develop' | implemented | Merge wrapper for tag-feed crash fixes already audited. | No recheck. |
| `40f14fd31` | 2023-03-30 | tusooa | Merge branch 'remove-crypt' into 'develop' | implemented | Merge wrapper for crypt removal already audited. | No recheck. |
| `ad38cc3b0` | 2023-03-30 | tusooa | Merge branch 'docs-otp-support' into 'develop' | implemented | Merge wrapper for OTP support docs already audited. | No recheck. |
| `e4288df50` | 2023-03-30 | Haelwenn | Merge branch 'background-timeout' into 'develop' | implemented | Merge wrapper for background timeout already audited. | No recheck. |
| `72833c84b` | 2023-05-26 | Haelwenn | Merge branch 'tusooa/rework-refetch' into 'develop' | implemented | Merge wrapper for object refetch update-rule branch. | No recheck. |
| `4339230f6` | 2023-05-26 | Haelwenn | Merge branch 'tusooa/fix-object-test' into 'develop' | implemented | Merge wrapper for object test fix branch. | No recheck. |
| `b36263e5f` | 2023-05-26 | Haelwenn | Merge branch 'issue/3126' into 'develop' | implemented | Merge wrapper for CSP and OEmbed issue branch. | No recheck. |
| `d0c2e0830` | 2023-05-26 | tusooa | Enforce unauth restrictions for public streaming endpoints | implemented | Public streaming endpoints enforce restricted_unauthenticated settings for local and federated timelines. | No recheck. |
| `4505bc1e5` | 2023-05-26 | Mark Felder | Filter OEmbed HTML tags | implemented | Release-branch copy of OEmbed HTML filtering is present locally. | No recheck. |
| `7618e562b` | 2023-05-26 | Haelwenn (lanodan) Monnier | Version 2.5.2 | not-applicable | Historical upstream 2.5.2 version marker. | No code backport needed. |
| `869f0d24a` | 2023-05-26 | Haelwenn (lanodan) Monnier | Merge branch 'release/2.5.2' into mergeback/2.5.2 | not-applicable | Historical 2.5.2 release merge. | No code backport needed. |
| `31ec5cd35` | 2023-05-26 | Haelwenn | Merge branch 'mergeback/2.5.2' into 'develop' | not-applicable | Historical 2.5.2 mergeback wrapper. | No code backport needed. |
| `9caa0b0be` | 2023-05-29 | Mark Felder | Add OnlyMedia Upload Filter to simplify restricting uploads to audio, image, and video types | implemented | OnlyMedia upload filter exists and allows only image video and audio content types. | No recheck. |
| `50a20f3bb` | 2023-05-29 | Mark Felder | Esacpe the asterisks in Markdown | implemented | Formatter markdown escape regex includes asterisks. | No recheck. |
| `da6b4003a` | 2023-05-30 | lain | Merge branch 'only_media_filter' into 'develop' | implemented | Merge wrapper for OnlyMedia upload filter. | No recheck. |
| `506a1c98e` | 2023-05-29 | Mark Felder | ConnCase: Make sure the host we use in tests is the actual Endpoint host | implemented | ConnCase builds test connections with Pleroma.Web.Endpoint.host(). | No recheck. |
| `843fcca5b` | 2023-05-29 | Mark Felder | Validate Host header matches expected value before allowing access to MediaProxy | superseded | Upstream later reverted MediaProxy Host validation; local code follows that final outcome. | No code backport needed. |
| `a60dd0d92` | 2023-05-29 | Mark Felder | Validate Host header matches expected value before allowing access to Uploads | implemented | UploadedMedia Host mismatch handling is present and modernized to redirect to the configured media host. | No recheck. |
| `84974efe4` | 2023-05-29 | Mark Felder | Host header validation is now required for MediaProxy and Uploads | superseded | Changelog row for the initial MediaProxy plus Uploads Host validation series; final code keeps Uploads handling only. | No code backport needed. |
| `43bb2f39d` | 2023-05-29 | Mark Felder | Remove unwanted parameter | implemented | ConnCase keeps the endpoint host setup without the removed helper parameter. | No recheck. |
| `da7394f33` | 2023-05-29 | Mark Felder | Fix unused assignment | implemented | UploadedMedia Host mismatch branch no longer keeps an unused conn assignment. | No recheck. |
| `b3c3bd99c` | 2023-05-30 | Mark Felder | Switch from serving a 400 to a 302 | implemented | UploadedMedia redirects mismatched Host requests to the configured media base URL. | No recheck. |
| `d998a114e` | 2023-05-31 | Haelwenn | Merge branch 'validate-host' into 'develop' | implemented | Merge wrapper for Host validation series with final Uploads redirect behavior carried locally. | No recheck. |
| `46c799f52` | 2023-05-31 | Mark Felder | Use Phoenix.ConnTest.redirected_to/2 | implemented | Uploaded-media redirect regression uses redirected_to/2 in the current test. | No recheck. |
| `e2a63dadd` | 2023-06-01 | Haelwenn | Merge branch 'test_improvement' into 'develop' | implemented | Merge wrapper for redirect test improvement. | No recheck. |
| `313e68c18` | 2023-06-02 | Haelwenn (lanodan) Monnier | mix: bump gettext to ~0.20 | superseded | Current dependency train is newer than the old gettext 0.20 bump. | No code backport needed. |
| `e8d352566` | 2023-06-02 | Haelwenn | Merge branch 'bump-gettext' into 'develop' | superseded | Merge wrapper for old gettext bump. | No code backport needed. |
| `cbc5b8ceb` | 2023-06-02 | Lain Soykaf | B Preload: Make sure that the preloaded json is html safe | implemented | Preload JSON is encoded with Jason escape html_safe before being embedded in the HTML script tag. | No recheck. |
| `40d40d67a` | 2023-06-02 | Lain Soykaf | Add changelog. | not-applicable | Historical changelog entry for preload escaping. | No code backport needed. |
| `43458cb7a` | 2023-06-06 | lain | Merge branch 'preload-escaping' into 'develop' | implemented | Merge wrapper for preload escaping. | No recheck. |
| `8336519f3` | 2023-05-31 | Haelwenn (lanodan) Monnier | installation/debian_based_en: Elixir 1.11 means Debian 12+ and Ubuntu 22.04+ | superseded | Debian/Ubuntu Elixir version guidance is superseded by Unfathomably install scripts and docs. | No code backport needed. |
| `737e45c10` | 2023-05-31 | Haelwenn (lanodan) Monnier | installation/debian_based_jp: Elixir 1.11 means Debian 12+ and Ubuntu 22.04+ | superseded | Japanese Debian/Ubuntu Elixir version guidance is superseded by Unfathomably install scripts and docs. | No code backport needed. |
| `b762a7503` | 2023-06-11 | lain | Merge branch 'distro-docs-elixir-1.11' into 'develop' | superseded | Merge wrapper for distro install documentation update. | No code backport needed. |
| `fb3335ffe` | 2023-05-17 | Haelwenn (lanodan) Monnier | EctoType: Add BareUri | implemented | BareUri Ecto type exists with tests for schemeful URI validation. | No recheck. |
| `a5066bb07` | 2023-05-17 | Haelwenn (lanodan) Monnier | CommonFields: Use BareUri for :url | implemented | ActivityPub common fields use BareUri for url. | No recheck. |
| `1db29f734` | 2023-06-11 | lain | Merge branch 'fep-fffd-url' into 'develop' | implemented | Merge wrapper for FEP-fffd url validation support. | No recheck. |
| `fadcd7f1a` | 2023-06-07 | Mark Felder | Revert MediaProxy Host header validation | implemented | MediaProxy Host validation is not retained locally, matching upstream revert. | No recheck. |
| `1ca1b4b32` | 2023-06-07 | Mark Felder | changelog.d | not-applicable | Historical changelog entry for MediaProxy Host validation revert. | No code backport needed. |
| `75900f21f` | 2023-06-11 | feld | Merge branch 'revert-mediaproxy-host-validation' into 'develop' | implemented | Merge wrapper for the MediaProxy Host validation revert. | No recheck. |
| `4fd96b24a` | 2023-05-05 | Haelwenn (lanodan) Monnier | AddRemoveValidator: Use User.fetch_by_ap_id instead of upgrade_user_from_ap_id | implemented | AddRemove validation no longer depends on upgrade_user_from_ap_id in the carried AP user-fetch cleanup. | No recheck. |
| `0903c4164` | 2023-05-05 | Haelwenn (lanodan) Monnier | User: Stop relying on ap_enabled | implemented | User schema has removed the ap_enabled field in current migrations and runtime model. | No recheck. |
| `606f78f5e` | 2023-05-05 | Haelwenn (lanodan) Monnier | ActivityPub: Stop relying on ap_enabled and upgrade_user_from_ap_id | implemented | ActivityPub user fetch paths no longer rely on ap_enabled. | No recheck. |
| `3962253cf` | 2023-05-05 | Haelwenn (lanodan) Monnier | Publisher: Stop filtering via ap_enabled?/1 | implemented | Publisher filtering is not based on ap_enabled in current code. | No recheck. |
| `2ee483ba4` | 2023-05-05 | Haelwenn (lanodan) Monnier | Transmogrifier: Remove upgrade_user_from_ap_id | implemented | Transmogrifier no longer exposes upgrade_user_from_ap_id. | No recheck. |
| `e17265a7a` | 2023-05-05 | Haelwenn (lanodan) Monnier | TransmogrifierWorker: Remove obsolete worker | implemented | Obsolete TransmogrifierWorker is absent from the current worker set. | No recheck. |
| `8181be89a` | 2023-05-05 | Haelwenn (lanodan) Monnier | Federator: Stop using ap_enabled?/1 | implemented | Federator paths no longer use ap_enabled filtering. | No recheck. |
| `9dfa1c4be` | 2023-05-05 | Haelwenn (lanodan) Monnier | ActivityPub: Mark fetch_and_prepare_user_from_ap_id/1 as private | implemented | ActivityPub user preparation is internalized in current ActivityPub fetch code. | No recheck. |
| `238edc30d` | 2023-05-05 | Haelwenn (lanodan) Monnier | User: Remove ap_enabled?/1 | implemented | User.ap_enabled?/1 is absent from current User code. | No recheck. |
| `fcd49e398` | 2023-05-05 | Haelwenn (lanodan) Monnier | User: Remove ap_enabled field | implemented | ap_enabled removal migration exists and current User schema does not expose the field. | No recheck. |
| `c63bf6a04` | 2023-05-05 | Haelwenn (lanodan) Monnier | Add changelog for !3880 | not-applicable | Historical changelog entry for ap_enabled cleanup. | No code backport needed. |
| `1f4618d64` | 2023-06-11 | lain | Merge branch 'cleanup/ostatus-user-upgrade' into 'develop' | implemented | Merge wrapper for OStatus user-upgrade cleanup. | No recheck. |
| `b6b7de201` | 2023-05-29 | faried nawaz | add url to Metadata.build_tags call | implemented | Metadata build_tags call sites pass canonical URL data to providers. | No recheck. |
| `52368e670` | 2023-05-29 | faried nawaz | fix meta tag for twitter cards and image attachments | implemented | OpenGraph and TwitterCard metadata include media proxy image attachment tags. | No recheck. |
| `a1af12249` | 2023-05-29 | faried nawaz | changelog entry | not-applicable | Historical changelog entry for metadata tag fixes. | No code backport needed. |
| `8b390d27d` | 2023-05-29 | faried nawaz | twitter card: handle case where image has no alt text | implemented | TwitterCard handles image attachments without alt text by rendering a safe empty alt value. | No recheck. |
| `4c91c0d1b` | 2023-05-29 | faried nawaz | oops, forgot the test cases | implemented | Metadata provider tests cover TwitterCard and OpenGraph attachment cases. | No recheck. |
| `16313af7e` | 2023-06-11 | lain | Merge branch 'fix/metadata-tags' into 'develop' | implemented | Merge wrapper for metadata tag fixes. | No recheck. |
| `55dd8ef1c` | 2023-06-11 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-double_mentions | implemented | Merge synchronization for ForceMentionsInContent branch. | No recheck. |
| `6611c6ce4` | 2023-06-11 | Lain Soykaf | B ForceMentionsInContent: Fix test, refactor. | implemented | ForceMentionsInContent tests and refactor are represented by local Mastodon and Misskey duplicate-mention coverage. | No recheck. |
| `d93b47cf2` | 2023-06-11 | lain | Merge branch 'pleroma-double_mentions' into 'develop' | implemented | Merge wrapper for double-mentions fix. | No recheck. |
| `1fa196d8f` | 2023-05-25 | tusooa | Fix deleting banned users' statuses | implemented | CommonAPI tests cover privileged deletion of banned user statuses. | No recheck. |
| `4e6ea7cc9` | 2023-06-11 | lain | Merge branch 'tusooa/3054-banned-delete' into 'develop' | implemented | Merge wrapper for banned-user status deletion fix. | No recheck. |
| `e444832bb` | 2023-04-10 | Duponin | fix OTP install documentation | superseded | OTP install documentation is superseded by Unfathomably installation and upgrade documentation. | No code backport needed. |
| `7944271c1` | 2023-04-15 | Duponin | Unify install guides using sudo to use `sudo -Hu` | superseded | sudo -Hu install-guide cleanup is superseded by Unfathomably install scripts and docs. | No code backport needed. |
| `d65a8bcd2` | 2023-06-11 | lain | Merge branch 'fix-otp-documentation' into 'develop' | superseded | Merge wrapper for OTP documentation cleanup. | No code backport needed. |
| `d91a82383` | 2023-04-22 | Mark Felder | Remove unused indexes | implemented | DropUnusedIndexes migration exists locally. | No recheck. |
| `175ee9e6f` | 2023-06-11 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into unused_indexes | implemented | Merge synchronization for unused-index cleanup branch. | No recheck. |
| `10dfa107d` | 2023-06-11 | Lain Soykaf | Update changelog | not-applicable | Historical changelog update for unused-index cleanup. | No code backport needed. |
| `22878cf84` | 2023-06-11 | Lain Soykaf | B Migrations: Don't remove activity_visibility_index for now. | implemented | Local DropUnusedIndexes migration keeps activities_visibility_index, matching upstream final state. | No recheck. |
| `fdb5bec43` | 2023-06-11 | lain | Merge branch 'unused_indexes' into 'develop' | implemented | Merge wrapper for unused-index cleanup. | No recheck. |
| `a663b7363` | 2023-06-13 | Haelwenn (lanodan) Monnier | Add no_new_privs to OpenRC service files | implemented | OpenRC service files include no_new_privs yes. | No recheck. |
| `589301ce0` | 2023-06-13 | lain | Merge branch 'no_new_privs' into 'develop' | implemented | Merge wrapper for OpenRC no_new_privs hardening. | No recheck. |
| `a5a354a36` | 2023-06-21 | Sean King | Prevent bypassing authorized fetch mode with a json file | implemented | HTTPSignaturePlug requires signatures for both json and activity+json formats when authorized_fetch_mode is enabled. | No recheck. |
| `994bfc4c0` | 2023-06-21 | Sean King | Add changelog entry | not-applicable | Historical changelog entry for authorized-fetch JSON bypass fix. | No code backport needed. |
| `436757994` | 2023-06-22 | Haelwenn | Merge branch 'fix/bypass-authorized-fetch-mode-json' into 'develop' | implemented | Merge wrapper for authorized-fetch JSON bypass fix. | No recheck. |
| `8bf890604` | 2023-06-22 | weblate-extractor | Extract translatable strings | not-applicable | Translation extraction commit only. | No code backport needed. |
| `4e26fbda0` | 2023-06-22 | Haelwenn | Merge branch 'weblate-extract' into 'develop' | not-applicable | Merge wrapper for translation extraction. | No code backport needed. |
| `e4ac2a7cd` | 2022-12-24 | tusooa | Detail backup states | implemented | Backups have state and processed_number fields with detailed running complete failed and invalid states. | No recheck. |
| `bdd63d2a3` | 2022-12-24 | tusooa | Expose backup status via Pleroma API | implemented | Pleroma backup API view and OpenAPI schema expose backup state and processed_number. | No recheck. |
| `46ab97d72` | 2022-12-24 | tusooa | Simplify backup update clause | implemented | Backup state updates use the simplified set_state path. | No recheck. |
| `a1b95922c` | 2022-12-24 | tusooa | Fix compile error | not-applicable | Temporary compile-fix commit in backup-status branch. | No code backport needed. |
| `070fbb89e` | 2022-12-24 | tusooa | Lint | not-applicable | Lint-only backup-status branch cleanup. | No code backport needed. |
| `7d3e4eaeb` | 2022-12-24 | tusooa | Log errors more extensively | implemented | Backup processing logs timeout and abnormal process failures with backup id and reason. | No recheck. |
| `179efd946` | 2022-12-24 | tusooa | Make backup parameters configurable | implemented | Backup limit_days and process_wait_time are configurable in config and descriptions. | No recheck. |
| `41f2ee69a` | 2023-06-27 | Haelwenn | Merge branch 'from/upstream-develop/tusooa/backup-status' into 'develop' | implemented | Merge wrapper for backup status and configurable backup parameters. | No recheck. |
| `2c66f584b` | 2023-05-25 | tusooa | Show more informative errors when profile exceeds char limits | implemented | Update-credentials tests cover specific bio and display-name limit errors. | No recheck. |
| `ae0ca4945` | 2023-06-27 | Haelwenn | Merge branch 'tusooa/3119-bio-update' into 'develop' | implemented | Merge wrapper for profile limit error improvements. | No recheck. |
| `9a2523a09` | 2023-03-16 | Haelwenn (lanodan) Monnier | instances: Store some metadata based on NodeInfo | implemented | Instance metadata stores NodeInfo software name and version, with broader local health metadata. | No recheck. |
| `043a00991` | 2023-06-27 | Haelwenn | Merge branch 'instance-nodeinfo-metadata' into 'develop' | implemented | Merge wrapper for NodeInfo instance metadata; local Instance metadata stores software and health fields. | No recheck. |
| `dd9f8150f` | 2023-06-22 | Haelwenn (lanodan) Monnier | Merge Revert "Merge branch 'validate-host' into 'develop'" | implemented | Revert wrapper for host-validation rollback, now represented in media proxy and uploaded-media behavior. | Patched UploadedMedia where local code still carried the old Host redirect. |
| `48e490cd5` | 2023-07-01 | tusooa | Merge branch 'bugfix/full-revert-media-host-validation' into 'develop' | implemented | UploadedMedia no longer rejects or redirects solely because the request Host differs from the configured media host. | Patched UploadedMedia and removed the stale redirect expectation test. |
| `63b9f7678` | 2023-07-01 | tusooa | Force the use of amd64 runners for jobs using ci-base | superseded | Old GitLab runner selection for ci-base jobs is superseded by current build and deployment tooling. | No code backport needed. |
| `8cf231c0d` | 2023-07-02 | Haelwenn | Merge branch 'tusooa/3151-amd64-runner' into 'develop' | superseded | Merge wrapper for old CI runner selection. | No code backport needed. |
| `a1621839c` | 2023-07-02 | tusooa | Fix user fetch completely broken if featured collection is not in a supported form | implemented | Featured collection parsing ignores unsupported values instead of breaking remote user fetch, with local tests around unsupported and embedded collection shapes. | No recheck. |
| `379590d43` | 2023-07-02 | Haelwenn | Merge branch 'tusooa/3142-featured-collection-shouldnt-break-user-fetch' into 'develop' | implemented | Merge wrapper for featured collection user-fetch hardening. | No recheck. |
| `6e4de2383` | 2023-07-02 | tusooa | Fix handling report from a deactivated user | implemented | Report state updates use unfiltered activity lookup so report activities involving deactivated actors remain manageable. | Patched CommonAPI report-state lookup and changelog. |
| `a31a4c522` | 2023-07-02 | Haelwenn | Merge branch 'tusooa/3131-handle-report-from-deactivated-user' into 'develop' | implemented | Merge wrapper for handling reports from deactivated users. | No recheck. |
| `8bc51288b` | 2023-06-27 | Haelwenn (lanodan) Monnier | release_runtime_provider_test: Explicitely use non-existant config file | not-applicable | Test-only release runtime provider fixture cleanup. | No code backport needed. |
| `026291697` | 2023-07-02 | Haelwenn | Merge branch 'testfix/system-config-use' into 'develop' | not-applicable | Merge wrapper for release runtime provider test cleanup. | No code backport needed. |
| `f970091c6` | 2023-05-26 | tusooa | Add instructions to serve media on another domain | implemented | Hardening docs and pleroma-mediaproxy nginx example describe serving uploads and media proxy from another domain. | No recheck. |
| `85902ad1a` | 2023-05-26 | tusooa | Recommend users to serve media on another domain in guide | implemented | Installation guides recommend serving media on another domain and link to hardening documentation. | No recheck. |
| `408ea697a` | 2023-05-26 | tusooa | Add changelog | not-applicable | Historical changelog entry for media alternate-domain docs. | No code backport needed. |
| `e92eb5f48` | 2023-05-27 | tusooa | Add instructions to other distro's guides | implemented | Distro install docs include the media alternate-domain recommendation. | No recheck. |
| `a2bbd7c9d` | 2023-05-31 | Sean King | Fix base media and proxy URL in instructions to serve media on another domain | implemented | Media alternate-domain docs use the corrected Upload and media_proxy base_url shapes. | No recheck. |
| `c9cb90ff4` | 2023-05-31 | Sean King | Media proxy base URL doesn't need /proxy | implemented | Media proxy base_url documentation no longer includes an unnecessary /proxy suffix. | No recheck. |
| `8fa435f37` | 2023-06-14 | tusooa | Add "potentially outdated" notice in non-English versions | superseded | Non-English potentially-outdated notices are upstream documentation maintenance outside the Unfathomably release docs focus. | No code backport needed. |
| `2b9cd25cf` | 2023-07-02 | Haelwenn | Merge branch 'tusooa/media-altdomain' into 'develop' | implemented | Merge wrapper for media alternate-domain documentation. | No recheck. |
| `d5a7079f4` | 2023-06-13 | Haelwenn (lanodan) Monnier | media_graphics_packages.md: Fix markdown syntax | superseded | Markdown syntax cleanup in upstream media graphics docs is superseded by current docs state. | No code backport needed. |
| `4392fff21` | 2023-06-13 | Haelwenn (lanodan) Monnier | otp_vs_from_source*: Acknowledge distro packages | implemented | OTP versus source install docs acknowledge distro packages in current install-guide set. | No recheck. |
| `fb19f0d84` | 2023-06-13 | Haelwenn (lanodan) Monnier | gentoo_otp_en: Add packaged installation documentation | implemented | Gentoo OTP packaged installation documentation exists locally. | No recheck. |
| `eddfd41c1` | 2023-06-13 | Haelwenn (lanodan) Monnier | gentoo_en: Reference packaged installation | implemented | Gentoo source installation docs reference packaged installation. | No recheck. |
| `937fa36ec` | 2023-06-13 | Haelwenn (lanodan) Monnier | changelog.d/gentoo_otp.skip: Doc-only MR | not-applicable | Doc-only changelog skip marker. | No code backport needed. |
| `bf2b4b940` | 2023-06-27 | Haelwenn (lanodan) Monnier | README.md: Update packaging state (GURU, AUR) | implemented | Packaging state is reflected in current README and install documentation rather than the old upstream wording. | No recheck. |
| `6fbbf8080` | 2023-07-03 | Haelwenn | Merge branch 'gentoo_otp' into 'develop' | implemented | Merge wrapper for Gentoo/package documentation. | No recheck. |
| `10249d1e4` | 2023-07-04 | Haelwenn (lanodan) Monnier | CI: Let curl return non-0 on http failure code | superseded | Old CI curl failure handling is superseded by current build and deployment tooling. | No code backport needed. |
| `8c3363a5e` | 2023-07-04 | Haelwenn (lanodan) Monnier | CI: Use CI_JOB_TOKEN for cross-repo pipeline triggers | superseded | Old GitLab cross-repo pipeline trigger token change is superseded by current workflow. | No code backport needed. |
| `53f4d6f23` | 2023-07-04 | Haelwenn | Merge branch 'fix/pipeline-triggers' into 'develop' | superseded | Merge wrapper for old pipeline trigger CI fix. | No code backport needed. |
| `0c3709173` | 2023-07-04 | Haelwenn (lanodan) Monnier | docs: Fix broken links | superseded | Upstream documentation broken-link cleanup is superseded by current Unfathomably documentation maintenance. | No code backport needed. |
| `624a5ccb2` | 2023-07-04 | Haelwenn | Merge branch 'hotfix/docs-broken-links' into 'develop' | superseded | Merge wrapper for documentation broken-link cleanup. | No code backport needed. |
| `3d79ceb23` | 2023-07-04 | Haelwenn (lanodan) Monnier | Deprecate audio scrobbling | implemented | Scrobble create and index OpenAPI operations are marked deprecated and API docs warn that Listen scrobbling is deprecated. | No recheck. |
| `7da6a82db` | 2023-07-04 | tusooa | Merge branch 'deprecate-scrobbles' into 'develop' | implemented | Merge wrapper for scrobble API deprecation. | No recheck. |
| `28ff828ca` | 2023-07-07 | tusooa | Add emoji policy to remove emojis matching certain urls | implemented | EmojiPolicy supports remove_url and is present in config and tests. | No recheck. |
| `80ce6482f` | 2023-07-07 | tusooa | EmojiPolicy: implement remove by shortcode | implemented | EmojiPolicy supports remove_shortcode with tests. | No recheck. |
| `7eb8abf7b` | 2023-07-07 | tusooa | EmojiPolicy: Implement delist | implemented | EmojiPolicy supports federated timeline removal by emoji URL or shortcode. | No recheck. |
| `f50422c38` | 2023-07-07 | tusooa | Move emoji_policy.ex to the right place | implemented | EmojiPolicy lives under Pleroma.Web.ActivityPub.MRF in the current source. | No recheck. |
| `18a8378be` | 2023-07-07 | tusooa | Update config cheatsheet | implemented | Config cheatsheet documents mrf_emoji options. | No recheck. |
| `20d193c91` | 2023-07-07 | tusooa | Improve config examples for EmojiPolicy | implemented | EmojiPolicy config descriptions and examples are present in the policy module and cheatsheet. | No recheck. |
| `ef8a6c539` | 2023-07-07 | tusooa | Make EmojiPolicy aware of custom emoji reactions | implemented | EmojiPolicy handles custom emoji reactions, including URL and shortcode filtering. | No recheck. |
| `d670dbdbd` | 2023-07-07 | tusooa | Test that unicode emoji reactions are not affected | implemented | EmojiPolicy tests cover unicode EmojiReact preserving native unicode reactions. | No recheck. |
| `0d914e17b` | 2023-07-07 | tusooa | Add changelog | implemented | EmojiPolicy change is represented in Unreleased changelog. | No recheck. |
| `ba3aa4f86` | 2023-07-07 | tusooa | Fix edge cases | implemented | EmojiPolicy handles malformed and edge-case emoji data plus custom emoji reactions. | No recheck. |
| `1459d6450` | 2023-07-07 | tusooa | Make regex-to-string descriptor reusable | implemented | MRF Utils.describe_regex_or_string/1 is shared by EmojiPolicy and KeywordPolicy with tests. | No recheck. |
| `e38207162` | 2023-07-07 | Haelwenn | Merge branch 'tusooa/2775-emoji-policy' into 'develop' | implemented | EmojiPolicy merge cluster is implemented with config, docs, and tests. | No recheck. |
| `aa4c4ab2a` | 2023-06-27 | Haelwenn (lanodan) Monnier | mix: 2023-06 deps update | superseded | Dependency set is newer in the current release train and tracked through advisory dependency passes. | No action. |
| `9e69adf76` | 2023-06-27 | Haelwenn (lanodan) Monnier | mix: Remove override on plug | implemented | Plug override is absent while the current Plug and Phoenix stack stays on patched newer versions. | No recheck. |
| `3a67b8f28` | 2023-06-27 | Haelwenn (lanodan) Monnier | endpoint: Use custom Multipart module for dynamic configuration | implemented | Endpoint uses Pleroma.Web.Multipart for dynamic multipart upload length configuration. | No recheck. |
| `d7e049d5e` | 2023-06-27 | Haelwenn (lanodan) Monnier | router: Fix usage of globs | implemented | Router catch-all routes use Phoenix glob syntax with *path. | No recheck. |
| `93ad16cca` | 2023-07-17 | Haelwenn | Merge branch '2023-06-deps-update' into 'develop' | implemented | Dependency, router, and multipart merge cluster is locally represented or superseded by newer deps. | No recheck. |
| `dc4de79d4` | 2023-07-28 | faried nawaz | status context: perform visibility check on activities around a status | implemented | Thread context fetch applies restrict_unauthenticated before visibility filtering and tests cover restricted context access. | No recheck. |
| `e5e76ec44` | 2023-07-28 | Faried Nawaz | cleaner ecto query to handle restrict_unauthenticated for activities | implemented | restrict_unauthenticated/2 uses direct local and remote boolean query clauses. | No recheck. |
| `11ce81d4a` | 2023-07-28 | faried nawaz | add changelog entry | implemented | Restricted context behavior is covered by current changelog and audit notes. | No recheck. |
| `b08cbe76f` | 2023-07-28 | tusooa | Merge branch 'fix/2927-disallow-unauthenticated-access' into 'develop' | implemented | Unauthenticated status-context visibility cluster is implemented. | No recheck. |
| `ea4225a64` | 2023-07-18 | tusooa | Restrict attachments to only uploaded files only | implemented | Attachments from media_ids require upload object types through Constants.upload_object_types/0. | No recheck. |
| `819fccb7d` | 2023-08-03 | Haelwenn | Merge branch 'tusooa/3154-attachment-type-check' into 'develop' | implemented | Attachment type-check merge cluster is implemented. | No recheck. |
| `2c7950945` | 2023-08-04 | Mark Felder | Resolve information disclosure vulnerability through emoji pack archive download endpoint | implemented | Emoji pack archive names are basename-validated to block path traversal and disclosure. | No recheck. |
| `8cc810012` | 2023-08-04 | Haelwenn (lanodan) Monnier | Config: Restrict permissions of OTP config file | implemented | Release runtime provider rejects world-readable or group-writable OTP config files. | No recheck. |
| `69caedc59` | 2023-08-04 | Haelwenn (lanodan) Monnier | instance gen: Reduce permissions of pleroma directories and config files | implemented | Instance generator chmods generated directories to 0700 and config to 0640. | No recheck. |
| `9f0ad901e` | 2023-08-04 | Haelwenn (lanodan) Monnier | changelog: Entry for config permissions restrictions | implemented | Config permission hardening is represented in current changelog/security notes. | No recheck. |
| `65ef8f19c` | 2023-08-04 | Haelwenn (lanodan) Monnier | release_runtime_provider_test: chmod config for hardened permissions | implemented | Release runtime provider tests cover hardened config permissions. | No recheck. |
| `6a0fd77c4` | 2023-08-04 | Haelwenn (lanodan) Monnier | Release 2.5.53 | not_applicable | Upstream release version bump only. | No action. |
| `1062185ba` | 2023-08-04 | Haelwenn | Merge branch 'mergeback/2.5.3' into 'develop' | implemented | 2.5.3 security mergeback is represented: emoji archive and config permissions are present. | No recheck. |
| `ca0859b90` | 2023-08-04 | Mae | Prevent XML parser from loading external entities | implemented | XML parser uses dtd: :none so external entities are not loaded. | No recheck. |
| `307692cee` | 2023-08-05 | FloatingGhost | Add unit test for external entity loading | implemented | XML and WebFinger tests include external entity fixture coverage. | No recheck. |
| `6d48b0f1a` | 2023-08-05 | Mark Felder | Document and test that XXE processing is disabled | implemented | XXE disabling is represented in changelog/security documentation. | No recheck. |
| `4099ddb3d` | 2023-08-05 | Haelwenn (lanodan) Monnier | Mergeback release 2.5.4 | implemented | Release 2.5.4 mergeback security content is implemented; version bump itself is not applicable. | No recheck. |
| `d0f7a5c4f` | 2023-08-05 | Haelwenn | Merge branch 'mergeback/2.5.4' into 'develop' | implemented | 2.5.4 merge cluster XML entity hardening is present. | No recheck. |
| `0e321698d` | 2023-08-04 | Haelwenn (lanodan) Monnier | gentoo_otp_en.md: Indicate which install method it covers | implemented | Gentoo OTP guide identifies that it covers Gentoo-provided package installs. | No recheck. |
| `17c336de6` | 2023-08-05 | Haelwenn | Merge branch 'docs/gentoo-otp-intro' into 'develop' | implemented | Gentoo OTP documentation merge is represented locally. | No recheck. |
| `48b1e9bdc` | 2023-08-05 | mae | Completely disable xml entity resolution | implemented | XML entity resolution is fully disabled with billion-laughs regression coverage. | No recheck. |
| `4e355b859` | 2023-08-06 | Haelwenn | Merge branch 'disable-xml-entities-completely' into 'develop' | implemented | XML entity-resolution hardening merge cluster is implemented. | No recheck. |
| `c298e0165` | 2023-08-08 | Cat pony Black | Fix config ownership in dockerfile to pass restriction test | implemented | Docker image copies config with chmod 640 for hardened config permissions. | No recheck. |
| `b729a8b14` | 2023-08-10 | tusooa | Merge branch 'fix-dockerfile-perms' into 'develop' | implemented | Docker config-permission merge cluster is implemented. | No recheck. |
| `675639225` | 2023-04-28 | HJ | allow https: so that flash works across instances without need for media proxy | implemented | Default CSP permits HTTPS media and image sources when media proxy redirect fallback requires direct remote media. | No recheck. |
| `cd20d15bb` | 2023-04-28 | HJ | changelog | implemented | CSP media-proxy behavior is covered by current changelog and audit notes. | No recheck. |
| `c0d11da2d` | 2023-05-07 | Henry Jameson | conditionally set csp depnding on media-proxy state | implemented | CSP media and image source policy is conditional on media proxy and redirect-on-failure state. | No recheck. |
| `f8ef4924e` | 2023-05-07 | Henry Jameson | fix whitespace | implemented | CSP whitespace cleanup is represented in the current implementation. | No recheck. |
| `f50fd9278` | 2023-05-07 | Henry Jameson | reduce redundant reduntancy reduction | implemented | CSP source construction avoids redundant media and image source duplication. | No recheck. |
| `2a07411b0` | 2023-05-07 | Henry Jameson | keep the websocket url for all modes | implemented | CSP connect-src keeps the websocket URL available across media proxy modes. | No recheck. |
| `d838d1990` | 2023-08-16 | Haelwenn | Apply lanodan's suggestion(s) to 1 file(s) | implemented | CSP source cleanup is represented in current HttpSecurityPlug source construction. | No recheck. |
| `1e685c830` | 2023-08-16 | Haelwenn | Merge branch 'csp-flash' into 'develop' | implemented | CSP flash/media merge cluster is implemented with conditional HTTPS media and websocket connect-src behavior. | No recheck. |
| `3d09bc320` | 2023-08-30 | tusooa | Make lint happy | implemented | HttpSecurityPlug lint cleanup is represented in the current implementation. | No recheck. |
| `3c5ecca37` | 2023-08-30 | tusooa | Skip changelog | not_applicable | Upstream changelog skip marker only. | No action. |
| `9da4f89b7` | 2023-08-31 | Haelwenn | Merge branch 'tusooa/lint' into 'develop' | implemented | Lint-only HttpSecurityPlug merge is represented locally. | No recheck. |
| `1afde067b` | 2023-09-03 | Mint | CommonAPI: Prevent users from accessing media of other users | implemented | CommonAPI media attachment access is scoped to the acting user, including scheduled posts and chat attachments. | No recheck. |
| `a94cf2ad4` | 2023-09-03 | Haelwenn | Merge branch 'check-attachment-attribution' into 'develop' | implemented | Attachment attribution security merge cluster is implemented. | No recheck. |
| `31eb3dc24` | 2023-09-13 | Alex Gleason | ObjectValidators: accept "quoteUrl" field | implemented | ActivityPub common object fields accept quoteUrl. | No recheck. |
| `7deda1fa1` | 2023-09-13 | Alex Gleason | Quote post: add fixtures | implemented | Fedibird and Misskey quote fixtures are present. | No recheck. |
| `795736af1` | 2023-09-13 | Alex Gleason | ObjectValidators: improve quoteUrl compatibility | implemented | Article/Note/Page validation normalizes quoteUrl variants through CommonFixes. | No recheck. |
| `b022d6635` | 2023-09-13 | Alex Gleason | Transmogrifier: fetch quoted post | implemented | Incoming quote posts fetch and normalize the quoted object. | No recheck. |
| `cc4badaf6` | 2023-09-13 | Alex Gleason | Transmogrifier: fix quoteUrl here too | implemented | Transmogrifier quoteUrl compatibility fixes are present. | No recheck. |
| `ce5eb3172` | 2023-09-13 | Alex Gleason | StatusView: show quoted posts through the API, probably | implemented | Mastodon status rendering exposes quoted posts through pleroma quote metadata. | No recheck. |
| `0d9c443e5` | 2023-09-13 | Alex Gleason | StatusView: render the whole quoted status | implemented | Status API renders full quoted status data with quote schema coverage. | No recheck. |
| `6ac19c399` | 2023-09-13 | Alex Gleason | ActivityDraft: create quote posts | implemented | ActivityDraft resolves quoted_status_id and quote_id into quote post state. | No recheck. |
| `d4fea8b55` | 2023-09-13 | Alex Gleason | ActivityDraft: allow quoting | implemented | Status creation API accepts quote IDs and builder emits quoteUrl. | No recheck. |
| `c20e90e89` | 2023-09-13 | Alex Gleason | BuilderTest: build quote post | implemented | Builder quote-post coverage is present. | No recheck. |
| `3a8b5d90d` | 2023-09-13 | Alex Gleason | StatusControllerTest: test creating a quote post | implemented | Status controller quote-post creation coverage is present. | No recheck. |
| `cbd1760ef` | 2023-09-13 | Alex Gleason | TransmogrifierTest: prepare an outgoing quote post | implemented | Outgoing quote post transmogrifier coverage is present. | No recheck. |
| `960097391` | 2023-09-13 | Alex Gleason | mix format | implemented | Quote-post status-operation formatting cleanup is represented locally. | No recheck. |
| `f4ccdfd50` | 2023-09-13 | Alex Gleason | Fix typos | implemented | Quote-post test typo cleanup is represented locally. | No recheck. |
| `5716f88a1` | 2023-09-13 | Alex Gleason | InstanceView: add "quote_posting" feature | implemented | Instance feature list advertises quote_posting. | No recheck. |
| `db46abce4` | 2023-09-13 | Alex Gleason | @context: add quoteUrl | implemented | LitePub context includes quoteUrl and quoteUri, with local Misskey fallback retained. | No recheck. |
| `80ab2572a` | 2023-09-13 | Alex Gleason | Return quote_url through the API, don't render quotes more than 1 level deep | implemented | Status API returns quote_url and avoids deep recursive quote rendering. | No recheck. |
| `54a989793` | 2023-09-13 | Alex Gleason | ActivityDraft: mention the OP of a quoted post | implemented | Quote posts mention the original poster when the quoted activity has an actor. | No recheck. |
| `1f19dd76f` | 2023-09-13 | Alex Gleason | ActivityDraft: mix format, defensive actor ID | implemented | Quote actor handling is defensive for activities without a usable actor ID. | No recheck. |
| `36a5578d2` | 2023-09-13 | Alex Gleason | Scrubber.Default: allow span.quote-inline for quote post compatibility | implemented | Default scrubber allows quote-inline classes for quote compatibility. | No recheck. |
| `57ef1d121` | 2023-09-13 | Alex Gleason | Add InlineQuotePolicy to force quote URLs inline | implemented | InlineQuotePolicy is present with config and tests. | No recheck. |
| `59326247a` | 2023-09-13 | Alex Gleason | CommonAPI: disallow quoting private posts through the API | implemented | CommonAPI disallows quoting private posts except allowed self-quote cases. | No recheck. |
| `6f11f1151` | 2023-09-13 | Alex Gleason | StatusView: fix quote visibility | implemented | StatusView quote visibility checks hide inaccessible quoted statuses. | No recheck. |
| `74e0a4555` | 2023-09-13 | Alex Gleason | StatusView: add `quote_visible` param | implemented | Status schema and rendering expose quote_visible. | No recheck. |
| `bee7e4195` | 2023-09-13 | Alex Gleason | InlineQuotePolicy: don't add line breaks to markdown posts | implemented | InlineQuotePolicy avoids adding extra markdown line breaks. | No recheck. |
| `93e4972b5` | 2023-09-13 | Alex Gleason | Add InlineQuotePolicy as a default MRF | implemented | InlineQuotePolicy is included in the default MRF policy list. | No recheck. |
| `cf8e42588` | 2023-09-13 | Alex Gleason | StatusView: return quote post inside a reblog | implemented | StatusView resolves quoted posts inside reblogs. | No recheck. |
| `3c8319fe9` | 2023-09-13 | Alex Gleason | Transmogrifier: federate quotes with _misskey_quote field | implemented | Outgoing quotes include the Misskey fallback field in addition to standard quoteUrl/quoteUri. | No recheck. |
| `817e308c0` | 2023-09-13 | Alex Gleason | Handle Fedibird's new quoteUri field | implemented | Fedibird quoteUri and quoteURL variants normalize to quoteUrl. | No recheck. |
| `4075eecca` | 2023-09-13 | Alex Gleason | InlineQuotePolicy: improve the way Markdown quotes are displayed by other software | implemented | InlineQuotePolicy renders markdown-friendly inline quote content. | No recheck. |
| `79fca39fa` | 2023-09-13 | Alex Gleason | Actually, don't send _misskey_quote anymore | not_applicable | Intentional Unfathomably divergence: keep _misskey_quote fallback for Misskey-family compatibility. | No action. |
| `f9697e68c` | 2023-09-13 | Alex Gleason | InlineQuotePolicy: skip objects which already have an .inline-quote span | implemented | InlineQuotePolicy skips objects already containing an inline quote span. | No recheck. |
| `b0a7e795e` | 2023-09-13 | tusooa | Unify logic for normalizing quoteUri | implemented | Quote URL normalization is centralized in CommonFixes, with harmless local compatibility duplication retained. | No recheck. |
| `9bcec87ab` | 2023-09-13 | tusooa | Allow local quote and private self-quote | implemented | Local quotes and private self-quotes are allowed while other private quotes remain blocked. | No recheck. |
| `d244c9d29` | 2023-09-13 | tusooa | Add changelog | implemented | Quote-post support is represented in changelog/audit notes. | No recheck. |
| `762794eed` | 2023-09-13 | tusooa | Fix CommonAPITest | implemented | CommonAPI quote-post regression coverage is present. | No recheck. |
| `163e56373` | 2023-09-13 | tusooa | Allow more flexibility in InlineQuotePolicy | implemented | InlineQuotePolicy has configurable template behavior and documentation. | No recheck. |
| `e9cd004ba` | 2023-09-13 | tusooa | Parse object link as quoteUrl | implemented | Object link tags are parsed as quoteUrl for FEP-e232-style quote links. | No recheck. |
| `479a6f11d` | 2023-09-13 | tusooa | Keep incoming Link tag | implemented | Incoming Link tags are preserved by the ActivityPub tag validator. | No recheck. |
| `e349e92a4` | 2023-09-13 | tusooa | Add mrf to force link tag of quoting posts | implemented | QuoteToLinkTagPolicy is present to add FEP-e232 object Link tags for quote posts. | No recheck. |
| `8b98a98df` | 2023-09-13 | tusooa | Make InlineQuotePolicy history aware | implemented | InlineQuotePolicy declares automatic history awareness. | No recheck. |
| `8596f9265` | 2023-09-13 | tusooa | Fix TransmogrifierTest | implemented | Transmogrifier quote tests match the current quote federation behavior. | No recheck. |
| `87353e5ad` | 2023-09-13 | tusooa | Fix config descriptions for mrf inline quote | implemented | InlineQuotePolicy owns its config description directly. | No recheck. |
| `875b46d97` | 2023-09-13 | tusooa | Do not mention original poster when quoting | implemented | Quote posting no longer auto-mentions the original poster; regression expectation updated. | No recheck. |
| `a8b2f9205` | 2023-09-13 | tusooa | Expose quote_id parameter on the api | implemented | Status API exposes the quote_id response parameter. | No recheck. |
| `08608afca` | 2023-09-13 | tusooa | Fix quote_visible attribute | implemented | quote_visible reflects quoted activity visibility for the requesting user. | No recheck. |
| `14b1b9c9b` | 2023-10-15 | tusooa | Merge branch 'tusooa/quote' into 'develop' | implemented | Quote-posting merge cluster is implemented, with Misskey fallback retained as an intentional Unfathomably compatibility extension. | No recheck. |
| `2b5636bf1` | 2023-10-15 | tusooa | Allow unified streaming endpoint | implemented | Unified streaming endpoint is present and accepts empty initial stream subscriptions. | No recheck. |
| `273cda63a` | 2023-10-15 | tusooa | Allow subscribing to streams | implemented | Streaming websocket client events can subscribe to additional streams. | No recheck. |
| `21395aa50` | 2023-10-15 | tusooa | Allow authenticating via client-sent events | implemented | Streaming supports client-sent pleroma:authenticate events after connection. | No recheck. |
| `7d005e8c9` | 2023-10-15 | tusooa | Return stream attribute in server-sent events | implemented | StreamerView includes stream metadata in server-sent events. | No recheck. |
| `a348c2e4d` | 2023-10-15 | tusooa | Use pleroma: instead of pleroma. for ws events | implemented | Pleroma websocket extension events use pleroma: event names. | No recheck. |
| `2d4306794` | 2023-10-15 | tusooa | Document the streaming endpoint | implemented | Mastodon API differences documentation links to and describes streaming behavior. | No recheck. |
| `9572be1e5` | 2023-10-15 | tusooa | Add tests for list streams | implemented | List stream websocket coverage is present. | No recheck. |
| `7f12ad6dc` | 2023-10-15 | tusooa | Fix docs wording | implemented | Streaming documentation wording cleanup is represented locally. | No recheck. |
| `949c4f01c` | 2023-10-15 | tusooa | Fix NotificationTest | implemented | Notification streaming tests are aligned with current stream payload behavior. | No recheck. |
| `eebc605bc` | 2023-10-15 | tusooa | Clear up debug statement | implemented | Temporary streamer debug output is absent. | No recheck. |
| `050227f11` | 2023-10-15 | tusooa | Add test to cover error: bad_topic | implemented | Websocket tests cover bad_topic errors for invalid streams. | No recheck. |
| `4cf109d3c` | 2023-10-15 | tusooa | Add test to cover rendering update with user | implemented | Websocket tests cover rendering updates with user context. | No recheck. |
| `26f5caeba` | 2023-10-15 | tusooa | Add test to cover notifications streaming | implemented | Websocket tests cover notification streaming. | No recheck. |
| `314360e5e` | 2023-10-15 | tusooa | Add test to cover edit streaming | implemented | Websocket tests cover status edit streaming. | No recheck. |
| `844d1a14e` | 2023-10-15 | tusooa | Start writing api docs for streaming endpoint | implemented | Streaming OpenAPI operation module is present. | No recheck. |
| `dcef33f5f` | 2023-10-15 | tusooa | Document server-sent events of streaming | implemented | Streaming OpenAPI docs cover server-sent events. | No recheck. |
| `8829dcaee` | 2023-10-15 | tusooa | Document client-sent events in streaming | implemented | Streaming OpenAPI docs cover client-sent events. | No recheck. |
| `f393a15dd` | 2023-10-15 | tusooa | Fix some specs about server-sent events in streaming | implemented | Streaming event schemas are adjusted for current server-sent event payloads. | No recheck. |
| `c13f0a846` | 2023-10-15 | tusooa | Add meta-info and query strings to streaming doc | implemented | Streaming docs include meta information and query-string parameters. | No recheck. |
| `32de0683c` | 2023-10-15 | tusooa | Fix unsubscribe event type in streaming doc | implemented | Streaming docs use the correct unsubscribe event type. | No recheck. |
| `840dd0103` | 2023-10-15 | tusooa | Fix duplicated schema names | implemented | Streaming OpenAPI schema names are de-duplicated. | No recheck. |
| `3e7d2e29b` | 2023-10-15 | tusooa | Add changelog | implemented | Unified streaming is represented in current changelog/audit notes. | No recheck. |
| `eb33a03d0` | 2023-10-15 | tusooa | Explain the encode-decode roundtrip | implemented | Websocket tests document the encode-decode roundtrip for stream arrays. | No recheck. |
| `340c88129` | 2023-10-15 | tusooa | Merge branch 'tusooa/3018-unified-stream' into 'develop' | implemented | Unified streaming merge cluster is implemented and extended locally for group/source aggregate streams. | No recheck. |
| `b748efe66` | 2023-10-16 | tusooa | Fix mentioning punycode domains when using Markdown | implemented | Markdown mentions preserve punycode domains in addressing. | No recheck. |
| `df0b56576` | 2023-10-16 | tusooa | Fix other quotation mark conversion tests | implemented | Markdown quotation conversion tests are aligned with current formatter output. | No recheck. |
| `e3ea311cd` | 2023-10-18 | Haelwenn | Merge branch 'tusooa/2810-punycode-mention' into 'develop' | implemented | Punycode mention merge cluster is implemented. | No recheck. |
| `50e7706b2` | 2023-11-02 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Verify link ownership with rel="me" | implemented | Local raw-field verification, BackgroundWorker verify_fields_links handling, RelMe metadata, and account-update coverage are present; local profile URL matching is stronger than upstream. | No recheck unless verified profile-field behavior regresses. |
| `47ce33a90` | 2024-03-07 | tusooa | Apply tusooa's suggestion | implemented | verify_field_link/2 now pattern-matches only confirmed rel="me" ownership links before stamping verified_at. | No recheck. |
| `5ff3783d0` | 2023-10-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Use correct domain for fqn and InstanceView | implemented | Full nicknames, WebFinger subjects, and instance views use the configured WebFinger host rather than the endpoint URL. | No recheck unless WebFinger host configuration changes. |
| `c03852fbc` | 2023-10-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | update tests | not-applicable | Upstream test-refresh commit for the WebFinger host change; local tests are organized differently and the behavior is covered by the source backport row. | No code action. |
| `6b9a34735` | 2023-11-02 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | update changelog | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries the Unfathomably-facing note. | No code action. |
| `39d3df86c` | 2023-12-21 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Use consistent terminology | implemented | WebFinger.host/0 is canonical locally, while domain/0 remains as a compatibility alias for older local or third-party callers. | No recheck. |
| `e154ebbf7` | 2022-10-10 | Ekaterina Vaartis | Initial meilisearch implementation, doesn't delete posts yet | implemented | Meilisearch backend, configuration, application hook, controller integration, and indexing task are present. | No recheck. |
| `0318e9a59` | 2022-10-10 | Ekaterina Vaartis | Add logging to milisiearch index and make it use desc(id) | implemented | Meilisearch indexing logs progress and indexes in descending object order. | No recheck. |
| `365024abe` | 2022-10-10 | Ekaterina Vaartis | Ensure only indexing public posts and implement clearing and delete | implemented | Meilisearch indexes public and unlisted posts, supports clear, and removes deleted objects from the index. | No recheck. |
| `ea6a6a128` | 2022-10-10 | Ekaterina Vaartis | Make the indexing batch differently and more, show number indexed | implemented | Meilisearch indexing batches work in configured chunks and reports indexed counts. | No recheck. |
| `38996f551` | 2022-10-10 | Ekaterina Vaartis | Make meilisearch sort on publish date converted to unix time | implemented | Meilisearch index data includes sortable published timestamps. | No recheck. |
| `9beaebd97` | 2022-10-10 | Ekaterina Vaartis | Tweak search ordering to hopefully return newer results | implemented | Meilisearch search ordering prefers newer published objects. | No recheck. |
| `00c48a33a` | 2022-10-10 | Ekaterina Vaartis | Use content instead of source and scrub it | implemented | Meilisearch indexing uses scrubbed object content rather than raw source. | No recheck. |
| `e35d87ea5` | 2022-10-10 | Ekaterina Vaartis | Make the chunk size smaller | implemented | Meilisearch initial indexing chunk size is configurable and smaller by default. | No recheck. |
| `2b2e409ad` | 2022-10-10 | Ekaterina Vaartis | Also index incoming federated posts | implemented | Incoming federated posts are indexed through ActivityPub side effects. | No recheck. |
| `9f16ca80e` | 2022-10-10 | Ekaterina Vaartis | Mark only content as searchable for meilisearch | implemented | Meilisearch setup marks only content as searchable. | No recheck. |
| `3dedadf19` | 2022-10-10 | Ekaterina Vaartis | Adjust content indexing to skip more unneeded stuff | implemented | Search data generation strips HTML and skips empty or dot-only content. | No recheck. |
| `35e9192ce` | 2022-10-10 | Ekaterina Vaartis | Rework task indexing to share code with the main module | implemented | Meilisearch indexing task shares Pleroma.Search.object_to_search_data/1 with runtime indexing. | No recheck. |
| `410c8cb76` | 2022-10-10 | Ekaterina Vaartis | Make indexing logs rewrite themselves | implemented | Meilisearch indexing progress rewrites the current console line. | No recheck. |
| `2c7d973af` | 2022-10-10 | Ekaterina Vaartis | Implement meilisearch auth | implemented | Meilisearch requests include JSON content-type and optional bearer-token authentication. | No recheck. |
| `a67f9da5c` | 2022-10-10 | Ekaterina Vaartis | Add a message with a count of posts to index | implemented | Meilisearch indexing task reports the number of entries to index. | No recheck. |
| `09a1ae1b6` | 2022-10-10 | Ekaterina Vaartis | Add the meilisearch.stats command | implemented | Meilisearch stats command is present. | No recheck. |
| `07ccab976` | 2022-10-10 | Ekaterina Vaartis | Add search/meilisearch documentation | implemented | Meilisearch search documentation is present. | No recheck. |
| `d9ef7e075` | 2022-10-10 | Ekaterina Vaartis | Fix activity being passed to objec_to_search_data | implemented | Index task passes objects, not activities, to object_to_search_data/1. | No recheck. |
| `005947e9f` | 2022-10-10 | Ekaterina Vaartis | Add tests for local post indexing for meilisearch | implemented | Meilisearch tests cover adding local posts to the index. | No recheck. |
| `a5bb7f934` | 2022-10-10 | Ekaterina Vaartis | Add private_key: nil to default meilisearch options | implemented | Default Meilisearch config includes private_key: nil. | No recheck. |
| `40280cc27` | 2022-10-10 | Ekaterina Vaartis | Reorder ranking rules for (maybe) better results | implemented | Meilisearch ranking rules are configured with published-first ordering. | No recheck. |
| `6beef2d11` | 2022-10-10 | Ekaterina Vaartis | Move add_to_index / remove_from_index to Pleroma.Actitivy.Search | implemented | Index add/remove calls are centralized behind the Pleroma.Search facade. | No recheck. |
| `c569ad05b` | 2022-10-10 | Ekaterina Vaartis | Add more documentation about rum to meilisearch docs | implemented | Search documentation includes Meilisearch and RUM tradeoff context. | No recheck. |
| `95cb2bb69` | 2022-10-10 | Ekaterina Vaartis | Don't try removing from index again in common_api | implemented | CommonAPI delete no longer removes search index entries directly; side effects handle removal. | No recheck. |
| `cf558208c` | 2022-10-10 | Ekaterina Vaartis | Use proper deleted object for removing from index | implemented | Delete side effects remove the normalized deleted object from the search index. | No recheck. |
| `e4b7a3f51` | 2022-10-10 | Ekaterina Vaartis | Modify some meilisearch variables | implemented | Meilisearch task variable cleanup is represented in current task code. | No recheck. |
| `0b4fd0d34` | 2022-10-10 | Ekaterina Vaartis | Set content-type to application/json | implemented | Meilisearch HTTP requests set Content-Type to application/json. | No recheck. |
| `444542129` | 2022-10-10 | Ekaterina Vaartis | Only add local posts to index in activity_pub | implemented | ActivityPub side-effect indexing is limited by search_indexable_object?/1 to public or unlisted Note objects. | No recheck. |
| `e928e307f` | 2022-10-10 | Ekaterina Vaartis | Add a reindex option | implemented | Meilisearch task setup supports clearing and rebuilding the index. | No recheck. |
| `9c1a93070` | 2022-10-10 | Ekaterina Vaartis | Support reindexing meilisearch >=0.24.0 | implemented | Meilisearch task supports newer >=0.25.0 task uid responses. | No recheck. |
| `8898b5e92` | 2022-10-10 | Ekaterina Vaartis | Fix a typo in search docs | implemented | Search documentation typo cleanup is represented and further typos were fixed. | No recheck. |
| `7009ef567` | 2022-10-10 | Ekaterina Vaartis | Move the search.ex file so credo doesn't complain | implemented | Database search backend lives under Pleroma.Search.DatabaseSearch. | No recheck. |
| `39e596a5b` | 2022-10-10 | Ekaterina Vaartis | Style fixes | implemented | Search style cleanup is represented in current modules. | No recheck. |
| `0fae71f88` | 2022-10-10 | Ekaterina Vaartis | Rename search.ex to database_search.ex and add search/2 | implemented | DatabaseSearch module exposes search/2-style callback-compatible entry points. | No recheck. |
| `a6946048f` | 2022-10-10 | Ekaterina Vaartis | Rename Activity.Search to Search.DatabaseSearch | implemented | Activity search backend was renamed to Pleroma.Search.DatabaseSearch. | No recheck. |
| `a12f63bc8` | 2022-10-10 | Ekaterina Vaartis | Implement suggestions from the Meilisearch MR | implemented | Meilisearch MR suggestions are reflected in the current task/backend split and docs. | No recheck. |
| `3a11e79de` | 2022-10-10 | Ekaterina Vaartis | Add config description for meilisearch | implemented | Config descriptions include Pleroma.Search and Pleroma.Search.Meilisearch settings. | No recheck. |
| `3412713c5` | 2022-10-10 | Ekaterina Vaartis | Update search.md documentation with meilisearch indexing steps | implemented | Search documentation includes Meilisearch indexing setup and operational steps. | No recheck. |
| `3179ed092` | 2022-10-10 | Ekaterina Vaartis | Make chunk size configurable | implemented | Meilisearch initial indexing chunk size is configurable. | No recheck. |
| `571533ae2` | 2022-10-10 | Ekaterina Vaartis | Don't support meilisearch < 0.24.0, since it breaks things | implemented | Meilisearch task refuses unsupported pre-0.25.0 servers with corrected error wording. | No recheck. |
| `4f2637acc` | 2022-10-10 | Ekaterina Vaartis | Add description for initial_indexing_chunk_size | implemented | Config descriptions document initial_indexing_chunk_size. | No recheck. |
| `6f2f45775` | 2022-10-10 | Ekaterina Vaartis | Add a search backend behaviour | implemented | Search backend behaviour defines search, add_to_index, and remove_from_index callbacks. | No recheck. |
| `2bc21c6f1` | 2022-10-10 | Ekaterina Vaartis | Use oban for search indexing | implemented | Search indexing uses Oban SearchIndexingWorker. | No recheck. |
| `d89dc5518` | 2022-10-10 | Ekaterina Vaartis | Fix meilisearch tests and jobs for oban | implemented | Search indexing worker and Meilisearch tests reflect Oban-based indexing. | No recheck. |
| `3387935e8` | 2022-10-10 | Ekaterina Vaartis | Don't try removing deleted users and such from index as posts | implemented | Search removal handles only object-like posts and avoids deleting users as posts. | No recheck. |
| `fd2cfc80d` | 2022-10-10 | Ekaterina Vaartis | Change search_indexing = 10 and retries for indexing = 2 | implemented | search_indexing queue concurrency and worker retry limits are configured. | No recheck. |
| `79225d9b0` | 2022-10-10 | Ekaterina Vaartis | Actually, unlisted posts are indexed | implemented | Public and unlisted posts are indexed; documentation was corrected to match. | No recheck. |
| `1e23f527e` | 2022-10-10 | Ekaterina Vaartis | Change the meilisearch key auth to conform to 0.25.0 | implemented | Meilisearch auth and task handling target the newer 0.25.0 API shape. | No recheck. |
| `84608be87` | 2022-10-10 | Ekaterina Vaartis | Change updateId to uid because apparently that's the new name | implemented | Meilisearch task response handling checks uid instead of updateId. | No recheck. |
| `b150e6f15` | 2022-10-10 | Ekaterina Vaartis | Update meilisearch docs | implemented | Meilisearch documentation is updated for current setup and version requirements. | No recheck. |
| `e20f74c71` | 2022-10-10 | Ekaterina Vaartis | Remove duplicate function call | implemented | Duplicate Meilisearch setup calls are absent from current task code. | No recheck. |
| `119b2b847` | 2022-10-10 | Ekaterina Vaartis | Instead of checking string length, explicitly check for "" and "." | implemented | Search indexing explicitly skips empty and dot-only content. | No recheck. |
| `102ebb42b` | 2022-10-10 | Ekaterina Vaartis | Make search a callback | implemented | Search backend behaviour includes search callback used by DatabaseSearch and Meilisearch. | No recheck. |
| `5ac676323` | 2022-10-10 | Ekaterina Vaartis | Make add_to_index and remove_from_index report errors | implemented | Search add/remove operations report backend errors instead of silently swallowing failures. | No recheck. |
| `6256822af` | 2022-10-10 | Ekaterina Vaartis | Check for updateId, not uid | superseded | Local Meilisearch code has the later task-status API handling rather than this older updateId naming fix. | No source change needed beyond the current Meilisearch backend. |
| `5a3986638` | 2022-10-10 | Ekaterina Vaartis | Specifically strip mentions for search indexing | implemented | The local search-indexing scrubber removes mention anchors before indexing content. | No source change needed. |
| `398141da6` | 2022-12-20 | Ekaterina Vaartis | Merge remote-tracking branch 'upstream/develop' into meilisearch | superseded | Merge-only commit; individual Meilisearch and develop-side changes are tracked on their own rows. | No source change needed. |
| `a2a69709b` | 2023-10-24 | tusooa | Bump version to 2.6.0 | not_applicable | Upstream release-number bump does not map to Unfathomably release metadata. | No source change needed. |
| `6a13c2d18` | 2023-10-25 | tusooa | Add collect-changelog script | implemented | `tools/collect-changelog` exists locally and collects security, change, add, fix, and remove entries. | No source change needed. |
| `ab894d98f` | 2023-10-29 | tusooa | Bundle 2.6.0 frontend | not_applicable | Unfathomably FE is promoted from the separate frontend tree rather than Pleroma's bundled frontend artifact. | No source change needed. |
| `2d193861d` | 2023-05-26 | Haelwenn | Merge branch 'release/2.5.2' into 'stable' | superseded | Merge-only stable branch commit; release contents are tracked by their individual changes. | No source change needed. |
| `18a0c923d` | 2023-08-04 | Mark Felder | Resolve information disclosure vulnerability through emoji pack archive download endpoint | implemented | Emoji-pack archive hardening was already imported in the earlier security block of this audit. | No source change needed. |
| `4befb3b1d` | 2023-08-04 | Haelwenn (lanodan) Monnier | Config: Restrict permissions of OTP config file | implemented | Runtime config permission hardening was already imported in the earlier security block of this audit. | No source change needed. |
| `bd7381f2f` | 2023-08-04 | Haelwenn (lanodan) Monnier | instance gen: Reduce permissions of pleroma directories and config files | implemented | Instance-generation permission hardening was already imported in the earlier security block of this audit. | No source change needed. |
| `22df32b3f` | 2023-08-04 | Haelwenn (lanodan) Monnier | changelog: Entry for config permissions restrictions | implemented | Local changelog already records the imported config-permission hardening. | No source change needed. |
| `76e408e42` | 2023-08-04 | Haelwenn (lanodan) Monnier | release_runtime_provider_test: chmod config for hardened permissions | implemented | Permission-hardening test coverage was imported with the earlier config permission work. | No source change needed. |
| `c37561214` | 2023-08-04 | Haelwenn (lanodan) Monnier | Force the use of amd64 runners for jobs using ci-base | not_applicable | Upstream GitLab runner selection does not apply to the local source distribution. | No source change needed. |
| `5ac2b7417` | 2023-08-04 | Haelwenn (lanodan) Monnier | test: Fix warnings | implemented | Warning cleanup was covered by the stricter local compiler-warning pass. | No source change needed. |
| `57f745374` | 2023-08-04 | Haelwenn (lanodan) Monnier | Release 2.5.3 | not_applicable | Upstream release tag bump does not map to Unfathomably release metadata. | No source change needed. |
| `ff2f3862a` | 2023-08-04 | Haelwenn | Merge branch 'release/2.5.3' into 'stable' | superseded | Merge-only stable branch commit; contents are tracked by their individual rows. | No source change needed. |
| `fc10e07ff` | 2023-08-05 | Mae | Prevent XML parser from loading external entities | implemented | XXE-safe XML parsing was already imported in the earlier security block of this audit. | No source change needed. |
| `77d57c974` | 2023-08-05 | FloatingGhost | Add unit test for external entity loading | implemented | XXE regression coverage was already imported with the XML parser hardening. | No source change needed. |
| `cc848b78d` | 2023-08-05 | Mark Felder | Document and test that XXE processing is disabled | implemented | The XML parser hardening and documentation were already imported in the earlier security block. | No source change needed. |
| `b631180b3` | 2023-08-05 | Haelwenn (lanodan) Monnier | Release 2.5.4 | not_applicable | Upstream release tag bump does not map to Unfathomably release metadata. | No source change needed. |
| `1f4be2b34` | 2023-08-05 | Haelwenn | Merge branch 'releases/2.5.4' into 'stable' | superseded | Merge-only stable branch commit; contents are tracked by their individual rows. | No source change needed. |
| `535a5ecad` | 2023-09-03 | Mint | CommonAPI: Prevent users from accessing media of other users | implemented | Uploaded-media ownership hardening and regression coverage are present locally. | No source change needed. |
| `385492577` | 2023-09-03 | Haelwenn (lanodan) Monnier | mix: version 2.5.5 | not_applicable | Upstream release-number bump does not map to Unfathomably release metadata. | No source change needed. |
| `f966abe4f` | 2023-09-03 | Haelwenn | Merge branch 'release/2.5.5' into 'stable' | superseded | Merge-only stable branch commit; contents are tracked by their individual rows. | No source change needed. |
| `ad45b06b3` | 2023-10-31 | tusooa | Merge branch 'stable' into 'release/2.6.0' | superseded | Merge-only release branch commit; contents are tracked by their individual rows. | No source change needed. |
| `6f654d534` | 2023-11-01 | tusooa | Merge branch 'release/2.6.0' into 'stable' | superseded | Merge-only stable branch commit; contents are tracked by their individual rows. | No source change needed. |
| `aaf53d9d7` | 2023-10-31 | tusooa | Bump package version for mergeback | not_applicable | Upstream package-version bump does not map to Unfathomably release metadata. | No source change needed. |
| `4c5b45ed7` | 2023-11-01 | tusooa | Merge branch 'mergeback/2.6.0' into 'develop' | superseded | Merge-only develop branch commit; contents are tracked by their individual rows. | No source change needed. |
| `bf426c53b` | 2023-11-07 | Mark Felder | Fix digest email processing, consolidate Oban queues | implemented | The migration exists, digest/new-user digest work now uses the mailer queue, and the stale `new_users_digest` queue was removed from config. | Patched `DigestEmailsWorker`, `config/config.exs`, and the changelog. |
| `11c520607` | 2023-11-07 | feld | Merge branch 'mailer-queue' into 'develop' | superseded | Merge-only commit for the mailer queue work tracked on `bf426c53b`. | No source change needed. |
| `e1bc95ae6` | 2023-11-08 | Mark Felder | Support a type called "change" | implemented | `tools/collect-changelog` and the MR template both support the `change` changelog type. | No source change needed. |
| `cfc01a660` | 2023-11-08 | feld | Merge branch 'changelogd-change' into 'develop' | superseded | Merge-only commit for the changelog type work tracked on `e1bc95ae6`. | No source change needed. |
| `8076deeeb` | 2023-11-07 | Mark Felder | Activate test for object validator that has not been running | implemented | The BareUri validator test is active under the `.exs` test naming convention. | No source change needed. |
| `76c070fe8` | 2023-11-08 | Haelwenn (lanodan) Monnier | ObjectValidators.BareUriTest: Replace calls of SafeText to BareUri | implemented | BareUri test coverage targets the BareUri validator rather than the old SafeText type. | No source change needed. |
| `0f56304f0` | 2023-11-08 | feld | Merge branch 'bare_uri_test' into 'develop' | superseded | Merge-only commit for BareUri test activation tracked on nearby rows. | No source change needed. |
| `1810b2f47` | 2023-11-08 | Mark Felder | Update MR template to include the type 'change' | implemented | The MR template lists `change` as an accepted changelog entry type. | No source change needed. |
| `17524865e` | 2023-11-08 | feld | Merge branch 'update_mr_template' into 'develop' | superseded | Merge-only commit for MR-template changelog wording tracked on `1810b2f47`. | No source change needed. |
| `addc5408f` | 2023-11-08 | Mark Felder | Fix changelogd grep syntax error | implemented | The local changelog collection script uses shell glob iteration and no longer depends on the broken grep path. | No source change needed. |
| `aef1a88dc` | 2023-11-08 | feld | Merge branch 'changelogd-fix' into 'develop' | superseded | Merge-only commit for changelog collection script fixes tracked on nearby rows. | No source change needed. |
| `e23672d82` | 2023-11-08 | Mark Felder | Ensure benchee doesn't run unless we are executing benchmarks | implemented | Benchmark code is isolated to benchmark paths and the normal compile path no longer pulls benchmark work in. | No source change needed. |
| `a51f3937e` | 2023-11-08 | feld | Merge branch 'benchee' into 'develop' | superseded | Merge-only commit for benchmark isolation tracked on `e23672d82`. | No source change needed. |
| `0c5cc5198` | 2023-11-12 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-meilisearch | superseded | Merge-only Meilisearch branch sync; contents are tracked by individual rows. | No source change needed. |
| `c1402af29` | 2023-11-12 | Lain Soykaf | B Getting: Add default implementation, delegate, prepare test support. | implemented | `Pleroma.Config.Getting` exists locally and provides the delegated config access used by tests and Meilisearch code. | No source change needed. |
| `d3f895058` | 2023-11-12 | Lain Soykaf | B MeiliSearch, SearchIndexingWorker: Use Config.Getting, make tests async. | implemented | Meilisearch and search-indexing worker code use the Config.Getting abstraction. | No source change needed. |
| `5208bd8a9` | 2023-11-12 | Lain Soykaf | Add changelog. | implemented | Local changelog records the imported Meilisearch and search-indexing behavior. | No source change needed. |
| `5996bef7c` | 2023-11-12 | Lain Soykaf | Fix most tests that call SearchIndexWorker. | implemented | Search-indexing worker tests were already modernized with the current Config.Getting-backed Meilisearch setup. | No source change needed. |
| `a1a25029d` | 2023-11-12 | Lain Soykaf | B DatabaseSearch: Fix local-only search. | implemented | Local database search includes the upstream local-only behavior. | No source change needed. |
| `59018d73c` | 2023-11-12 | Lain Soykaf | B Meilisearch: Update to current API responses. | implemented | Local Meilisearch code targets the newer response shape and task status behavior. | No source change needed. |
| `3d62c71ed` | 2023-11-12 | Lain Soykaf | Credo fixes. | implemented | Style-only Meilisearch cleanup is covered by the current local implementation. | No source change needed. |
| `e902c7168` | 2023-11-12 | lain | Merge branch 'meilisearch' into 'develop' | superseded | Merge-only Meilisearch commit; contents are tracked by the individual Meilisearch rows above. | No source change needed. |
| `bed44f9f6` | 2023-05-31 | Mark Felder | Update to Phoenix 1.7 | superseded | Local dependency train has already moved past this to Phoenix 1.8.x. | No source change needed. |
| `6e1ea2eaf` | 2023-05-31 | Mark Felder | Remove unnecessary compilers as of Phoenix 1.7 | implemented | `mix.exs` uses the default `Mix.compilers()` path rather than the old custom compiler list. | No source change needed. |
| `e3110cb34` | 2023-05-31 | Mark Felder | Fix deprecated calls to get_flash/2 | implemented | No deprecated `get_flash/2` calls remain in local web code. | No source change needed. |
| `f622f82c0` | 2023-05-31 | Mark Felder | No user facing changes | not_applicable | Upstream changelog skip marker only. | No source change needed. |
| `a7e7db4a2` | 2023-05-31 | Mark Felder | Phoenix.Endpoint.Cowboy2Handler -> Plug.Cowboy.Handler | implemented | Runtime config no longer uses the old handler and stale config serialization fixtures now expect `Plug.Cowboy.Handler`. | Patched config serialization tests and changelog. |
| `4dc2d4bf7` | 2023-05-31 | Mark Felder | Remove locked version of plug | superseded | Local dependency train uses newer Plug/Phoenix constraints and no longer needs the old lock workaround. | No source change needed. |
| `ffee478ed` | 2023-05-31 | Mark Felder | Move websocket config for Shoutbox to the Endpoint | implemented | The endpoint owns the websocket path and transport options for the shout socket. | No source change needed. |
| `62322f71e` | 2023-05-31 | Mark Felder | Clean up Plug.Parsers.MULTIPART deprecation warnings | implemented | Local endpoint uses `Pleroma.Web.Multipart` as the dynamic multipart parser wrapper. | No source change needed. |
| `ba988a9ab` | 2023-05-31 | Mark Felder | Fix test warnings | implemented | Warning cleanup from this Phoenix chunk is covered by current local tests and stricter compiler-warning work. | No source change needed. |
| `d9f031c9d` | 2023-05-31 | Mark Felder | Bump minimum Elixir to 1.12 | superseded | Local project now requires a newer Elixir baseline than 1.12. | No source change needed. |
| `2b8bbb288` | 2023-05-31 | Mark Felder | Phoenix.Socket.Transport.force_ssl/4 no longer exists | not_applicable | The local Phoenix dependency train no longer carries the removed Phoenix transport shim. | No source change needed. |
| `f0e5f0e83` | 2023-05-31 | Mark Felder | Fix compile warning | implemented | Router warning cleanup is represented by the current public route-introspection code. | No source change needed. |
| `2e45be265` | 2023-06-02 | Mark Felder | Add :phoenix to extra_applications to suppress a warning | implemented | Phoenix is included in the application runtime setup through the modern dependency/application configuration. | No source change needed. |
| `86b38dd14` | 2023-06-02 | feld | Merge branch 'develop' into 'phoenix1.7' | superseded | Merge-only Phoenix 1.7 branch sync; local dependency train is already newer. | No source change needed. |
| `bcd7ccac1` | 2023-06-03 | Mark Felder | Support a type called "change" | implemented | Changelog tooling supports the change entry type. | No source change needed. |
| `c665d5329` | 2023-06-03 | Mark Felder | Update to Phoenix 1.7 | superseded | Phoenix 1.7 release-note row is superseded by the local Phoenix 1.8 dependency train. | No source change needed. |
| `63ef1dced` | 2023-06-03 | Mark Felder | Phoenix.Router.routes/1 is the public function we are meant to be using here | implemented | Router route metadata now uses the public Phoenix.Router.routes/1 API. | No source change needed. |
| `a0e08c6ec` | 2023-11-07 | Mark Felder | Merge branch 'develop' into phoenix1.7 | superseded | Merge-only Phoenix 1.7 branch sync; local runtime has already moved beyond this stack. | No source change needed. |
| `9fa653110` | 2023-11-07 | Mark Felder | Phoenix is no longer required in extra_applications | implemented | mix.exs does not list :phoenix in extra_applications. | No source change needed. |
| `0ab853cab` | 2023-11-08 | Mark Felder | Merge branch 'develop' into phoenix1.7 | superseded | Merge-only Phoenix branch sync, with BareUri test activation tracked separately. | No source change needed. |
| `ef6d3dddd` | 2023-11-08 | Mark Felder | Fix changelogd grep syntax error | implemented | Changelog checking no longer uses the broken grep syntax from the upstream fix. | No source change needed. |
| `5f19fbc5a` | 2023-11-12 | lain | Merge branch 'phoenix1.7' into 'develop' | superseded | Merge-only Phoenix 1.7 branch row; individual runtime changes are tracked on nearby rows and local Phoenix is newer. | No source change needed. |
| `9a063deac` | 2023-11-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Count and display post quotes | implemented | Quote counts, quote lookup, API schema fields, status rendering, and quote endpoint support are present locally. | No source change needed. |
| `752bc168f` | 2023-11-12 | lain | Merge branch 'quotes-count' into 'develop' | superseded | Merge-only quote-count row covered by the concrete quote-count implementation row. | No source change needed. |
| `2f6fc6a7a` | 2023-09-24 | Haelwenn (lanodan) Monnier | TwitterAPI: Return proper error when healthcheck is disabled | implemented | Disabled healthcheck returns a clear 503 error payload instead of a generic fallthrough. | No source change needed. |
| `bf2d6abaf` | 2023-11-14 | Haelwenn | Merge branch 'healthcheck-disabled-error' into 'develop' | superseded | Merge-only healthcheck-disabled-error row covered by the controller behavior row. | No source change needed. |
| `8ac7cc98c` | 2023-11-16 | Haelwenn (lanodan) Monnier | MastoAPI AccountView: Change last_status_at to be a date | implemented | AccountView renders last_status_at as an ISO date string for NaiveDateTime values. | No recheck unless account rendering changes. |
| `3831d3100` | 2023-11-14 | Haelwenn (lanodan) Monnier | docs: Put a max version on erlang and elixir | not_applicable | Older upstream maximum Erlang and Elixir documentation does not match Unfathomably latest-runtime policy. | No source change needed. |
| `19519d6c9` | 2023-11-14 | Haelwenn (lanodan) Monnier | docs: clang is also supported | not_applicable | Compiler documentation note is upstream install-doc maintenance only. | No source change needed. |
| `6d708664b` | 2023-11-14 | Haelwenn | Merge branch 'docs/max-elixir-erlang' into 'develop' | not_applicable | Merge-only upstream install-doc row superseded by Unfathomably install documentation. | No source change needed. |
| `2b6ae571b` | 2023-11-14 | Haelwenn (lanodan) Monnier | mix: cherry-pick eblurhash latest git for system-CFLAGS | superseded | Current dependency train supersedes the old eblurhash system-CFLAGS pin. | No source change needed. |
| `5f85067a9` | 2023-11-14 | Haelwenn (lanodan) Monnier | mix: Bump elixir-captcha for system-CFLAGS | superseded | Current dependency train supersedes the old elixir-captcha system-CFLAGS bump. | No source change needed. |
| `4472ab1fe` | 2023-11-14 | Haelwenn (lanodan) Monnier | changelog.d/system-cflags.fix: New entry | superseded | Changelog entry for dependency pinning is covered by current dependency maintenance notes. | No source change needed. |
| `50c896169` | 2023-11-15 | Haelwenn | Merge branch 'cflags' into 'develop' | superseded | Merge-only system-CFLAGS dependency row covered by current dependency train. | No source change needed. |
| `66f5ae0c5` | 2023-11-14 | Haelwenn (lanodan) Monnier | router: Make /federation_status publicly available | implemented | /federation_status is publicly routable as in upstream. | No source change needed. |
| `ca1b18ba2` | 2023-11-15 | Haelwenn | Merge branch 'federation_status-access' into 'develop' | superseded | Merge-only federation_status access row covered by router behavior. | No source change needed. |
| `a5aa8ea79` | 2023-11-14 | Henry Jameson | Add support for configuring a favicon and embed PWA manifest in server-generated-meta | implemented | Instance favicon config exists and RedirectController injects favicon and manifest links through the local SSR metadata composer. | No recheck unless fallback frontend metadata changes. |
| `5d3e145dc` | 2023-11-14 | Haelwenn (lanodan) Monnier | RedirectController: Unify server-generated-meta insertion code | implemented | RedirectController uses compose_meta/build_meta for title, favicon, manifest, preload, and metadata tags instead of duplicating insertion logic. | No recheck. |
| `2a58596ae` | 2023-11-15 | Haelwenn (lanodan) Monnier | Fix tests for Add support for configuring a favicon and embed PWA manifest in server-generated-meta | not-applicable | Upstream test-only adjustment for Pleroma frontend metadata tests; local static fallback tests differ. | No runtime action. |
| `4ebfc011f` | 2023-11-19 | HJ | Merge branch 'favicon' into 'develop' | implemented | Merge commit for the favicon/manifest metadata cluster; covered by a5aa8ea79 and 5d3e145dc rows. | No recheck. |
| `637926dcb` | 2023-11-10 | Henry Jameson | Initial draft on frontends management | deferred | Documentation-only upstream frontend-management draft is Pleroma-specific and should be adapted against Unfathomably FE deployment docs before importing. | Revisit during documentation hardening, not runtime backporting. |
| `2112e8b5e` | 2023-11-19 | Henry Jameson | update, add images | deferred | Documentation/media update for upstream frontend-management docs; importing verbatim would not match Unfathomably FE packaging. | Revisit with the frontend deployment docs. |
| `6513f54f7` | 2023-11-19 | Henry Jameson | changelog | not-applicable | Upstream changelog-only commit for frontend docs. | No code action. |
| `9c57f17af` | 2023-11-27 | HJ | Merge branch 'frontends-docs' into 'develop' | deferred | Merge commit for upstream frontend-management documentation; runtime code is unaffected. | Revisit during documentation hardening. |
| `5a3b81d92` | 2023-11-27 | Lain Soykaf | ActivityPub.UtilsTest: Add failing test for strip_report_status_data | implemented | Local strip_report_status_data behavior already keeps only valid object IDs, covering the regression described by this test commit. | No recheck unless report sanitizing changes. |
| `27df2c0ce` | 2023-11-27 | NEETzsche | Fix #strip_report_status_data | implemented | ActivityPub.Utils strips report status data defensively instead of assuming every item is a plain object id. | No recheck. |
| `4ef56c5b6` | 2023-11-27 | Lain Soykaf | ActivityPub.Utils: Only treat object ids as valid while stripping | implemented | Local implementation uses ObjectID.cast/1 so only valid object IDs survive report-status stripping. | No recheck. |
| `2b839197a` | 2023-11-27 | lain | Merge branch 'strip-fix' into 'develop' | implemented | Merge commit for the report-status stripping cluster; covered by the individual rows above. | No recheck. |
| `66cb3294e` | 2023-11-13 | Mark Felder | Switch to PromEx for prometheus metrics | implemented | `lib/pleroma/prom_ex.ex`, `config/dev.exs`, `config/test.exs` | PromEx metrics integration is present locally. |
| `1db10744f` | 2023-11-13 | Mark Felder | Use the "change" type | not-applicable | Upstream changelog-fragment classification only; local changelog tracks PromEx as part of the Unfathomably dependency/security stream. | No code action. |
| `ef7bda61a` | 2023-11-28 | lain | Merge branch 'promex' into 'develop' | implemented | Merge commit for the PromEx migration; local metrics stack is already PromEx-based. | No recheck. |
| `fe776d8b3` | 2023-11-13 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix GenerateUnsetUserKeys migration | implemented | GenerateUnsetUserKeys now uses a migration-local users schema rather than the current runtime Pleroma.User schema. | No recheck. |
| `35774d44b` | 2023-11-28 | lain | Merge branch 'generate-unset-user-keys-migration' into 'develop' | implemented | Merge commit for the GenerateUnsetUserKeys migration fix; covered by fe776d8b3. | No recheck. |
| `13baba90f` | 2023-11-13 | Mark Felder | Replace ImageMagick with Vips for Media Preview Proxy | implemented | MediaHelper.image_resize/2 now uses Vix/libvips thumbnail and save operations for still-image preview generation while retaining local safer video handling. | No recheck unless media preview code changes. |
| `481b6ac0d` | 2023-11-13 | Mark Felder | Add Pleroma.Upload.Filter.HeifToJpeg based on vips | not-applicable | This upstream experiment was reverted by a4b6e5613 before the branch landed; no HeifToJpeg filter is kept locally. | No code action. |
| `577ade75c` | 2023-11-13 | Mark Felder | Override elixir_make version | implemented | Local mix.exs already keeps elixir_make as an override, currently on the newer 0.10 release line used by Vix. | No recheck unless native dependency resolution changes. |
| `a4b6e5613` | 2023-11-13 | Mark Felder | Revert "Add Pleroma.Upload.Filter.HeifToJpeg based on vips" | implemented | Final upstream state has no HeifToJpeg filter; local tree also has none. | No recheck. |
| `ce42dac33` | 2023-11-13 | Mark Felder | Change mediaproxy previews to use vips to generate thumbnails instead of ImageMagick | implemented | Local media preview proxy source and changelog now describe the Vix/libvips thumbnail path. | No recheck. |
| `0c6a54b37` | 2023-11-17 | Mark Felder | Upload.Filter.AnalyzeMetadata: Blurhash with a Rust NIF, and use Vix to retrieve image metadata | implemented | AnalyzeMetadata now uses Vix for image dimensions and small-image blurhash input; the blurhash dependency is modernized to pure Elixir BlurHash 2.0 instead of the older upstream NIF path. | No recheck unless upload metadata extraction changes. |
| `88cc7e6a0` | 2023-11-17 | Mark Felder | Resize images to 100 pixels before hashing | implemented | AnalyzeMetadata generates blurhashes from a Vix thumbnail_image/2 result capped at 100px. | No recheck. |
| `9511212e3` | 2023-11-17 | Mark Felder | Fetch the library from the Pleroma repository | superseded | Rather than depending on the old Pleroma-hosted blurhash fork, local source uses the current Hex BlurHash 2.0 package. | No action unless BlurHash API changes. |
| `7988c62f6` | 2023-11-17 | Mark Felder | Update changelogs | not-applicable | Upstream changelog-fragment commit; local CHANGELOG.md carries the Unfathomably-facing Vix/BlurHash note. | No code action. |
| `8208777b0` | 2023-11-17 | Mark Felder | Rust is required for blurhash | superseded | Local blurhash generation uses pure Elixir BlurHash 2.0, so the old Rust blurhash NIF requirement does not apply. | No action. |
| `cf5ef1d75` | 2023-11-17 | Mark Felder | Vix has pre-built NIFs for the following triples: | superseded | Local dependency resolution uses current Vix 0.40 and the Unfathomably source/Docker setup documents libvips directly rather than importing old upstream NIF-triple notes. | No action. |
| `be39146ec` | 2023-11-17 | Mark Felder | Update docs to include dependencies on rust and vips where appropriate | implemented | Dockerfile, source install guide, and media/graphics dependency docs now include libvips while avoiding obsolete Rust blurhash requirements. | No recheck unless installation docs are reorganized. |
| `906b121a1` | 2023-11-17 | feld | Merge branch 'develop' into 'vips' | implemented | Merge-sync commit for the Vips branch; covered by individual Vips and blurhash rows. | No recheck. |
| `299c548b1` | 2023-11-23 | Mark Felder | Prevent a blurhash failure from breaking all metadata collection | implemented | AnalyzeMetadata.get_blurhash/1 returns nil on Vix/BlurHash failure, allowing dimensions and uploads to continue. | No recheck. |
| `03db495e1` | 2023-11-28 | Lain Soykaf | AnalyzeMetadata: Switch to rinpatch_blurhash | superseded | rinpatch_blurhash conflicts with the newer local Mogrify line; local source instead uses the maintained Hex BlurHash 2.0 package with the same RGB-list encode path. | No action unless BlurHash behavior regresses. |
| `b3214be32` | 2023-11-28 | Lain Soykaf | AnayzeMetadata: Fix error case that would never match | implemented | media_dimensions/1 now wraps unmatched ffprobe failures with {:error, error} so callers can log and noop cleanly. | No recheck. |
| `da26964d2` | 2023-11-28 | Lain Soykaf | Changelog: Adjust blurhash change | not-applicable | Upstream changelog-only adjustment; local CHANGELOG.md has the Unfathomably dependency note. | No code action. |
| `ccc2adee4` | 2023-11-28 | Lain Soykaf | Linting | implemented | Local Vix/BlurHash code was integrated in current project style rather than importing the intermediate lint-only patch. | No recheck unless formatting changes. |
| `1955b3c55` | 2023-11-29 | lain | Merge branch 'vips' into 'develop' | implemented | Merge commit for the Vips media preview and upload metadata cluster; covered by individual source, dependency, and documentation rows above. | No recheck. |
| `10525ac7f` | 2023-11-28 | Lain Soykaf | Docs: Remove rust references | implemented | Local docs do not introduce the obsolete Rust blurhash requirement and instead describe libvips directly. | No recheck. |
| `cd6adef47` | 2023-11-29 | Lain Soykaf | Add changelog | not-applicable | Upstream changelog-fragment commit; local CHANGELOG.md carries the Unfathomably-facing note. | No code action. |
| `bc7fcc2db` | 2023-11-29 | lain | Merge branch 'vips' into 'develop' | implemented | Final merge state for the Vips docs adjustment; covered by be39146ec and 10525ac7f. | No recheck. |
| `510a7b64f` | 2023-11-23 | NEETzsche | Add optional URL value for scrobbles | implemented | Scrobble create/render/API spec support a link field; local implementation also preserves legacy url as a compatibility alias. | No recheck unless scrobble API changes. |
| `e21660347` | 2023-11-29 | NEETzsche | Change url to externalLink as requested by hj here: https://shigusegubu.club/notice/AcIjZjackKAt6e522a | implemented | Scrobble ActivityDraft stores externalLink, ScrobbleView renders externalLink, and url remains as a deprecated compatibility alias. | No recheck unless scrobble field names change. |
| `6a6a631c8` | 2023-11-29 | HJ | Merge branch 'neetzsche/add_url_to_scrobbles' into 'develop' | implemented | Merge commit for scrobble external links; covered by 510a7b64f and e21660347 rows. | No recheck. |
| `1ad0d94d6` | 2023-12-06 | Mark Felder | Change set_reachable/1 to an upsert | implemented | Instance.set_reachable/1 uses Repo.insert with on_conflict replace for unreachable_since and updates the reachability cache. | No recheck unless reachability storage changes. |
| `6c10fd22a` | 2023-12-07 | lain | Merge branch 'reachable-upsert' into 'develop' | implemented | Merge commit for reachability upsert behavior; covered by 1ad0d94d6. | No recheck. |
| `15a8acbd6` | 2023-11-30 | Lain Soykaf | MRF, Docs.Generator: Ensure code is loaded before checking it | implemented | Docs.Generator and MRF now call Code.ensure_loaded/1 before function_exported?/module_info introspection. | No recheck unless MRF or docs introspection changes. |
| `265d8749b` | 2023-11-30 | Lain Soykaf | Gitlab CI: Make it work for a local runner | implemented | .gitlab-ci.yml quotes DB_PORT as a string for local GitLab runners. | No recheck unless CI variables change. |
| `30084b733` | 2023-11-30 | Lain Soykaf | Add changelog. | not-applicable | Upstream changelog-skip fragment only; local CHANGELOG.md carries the Unfathomably-facing note. | No code action. |
| `eb6be3060` | 2023-11-30 | Lain Soykaf | Linting | implemented | MRF config description loading guard is formatted in local style with a separating blank line before the function_exported? branch. | No recheck. |
| `d99e139c6` | 2023-11-30 | Lain Soykaf | CI: Remove test coverage | not-applicable | This upstream change was reverted by 5dce39d17; local CI and mix.exs keep covertool coverage. | No action. |
| `5dce39d17` | 2023-12-03 | Lain Soykaf | Revert "CI: Remove test coverage" | implemented | Local mix.exs still configures covertool and .gitlab-ci.yml still emits coverage_report artifacts. | No recheck unless CI test coverage changes. |
| `2656199dc` | 2023-12-07 | lain | Merge branch 'more-test-fixes' into 'develop' | implemented | Merge commit for module-loading and CI local-runner fixes; covered by 15a8acbd6, 265d8749b, and 5dce39d17 rows. | No recheck. |
| `6a191a91a` | 2023-12-07 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into last_status_at | implemented | Merge-sync commit pulling already audited rel=me, Vips, PromEx, favicon, reachability, scrobble, and test-fix work into the last_status_at branch. | No recheck unless one of the constituent rows reopens. |
| `ef8a2134b` | 2023-12-07 | Lain Soykaf | AccountView: Add test, refactor | implemented | AccountView renders last_status_at as an ISO date and local code additionally accepts Date values safely. | No recheck unless account rendering changes. |
| `5f74aadaa` | 2023-12-07 | lain | Merge branch 'last_status_at' into 'develop' | implemented | Merge commit for Mastodon-compatible last_status_at date rendering; covered by 8ac7cc98c and ef8a2134b rows. | No recheck. |
| `003d3312f` | 2023-12-08 | Mark Felder | Permit the index creation to run concurrently | implemented | AddQuoteUrlIndexToObjects creates objects_quote_url with concurrently: true. | No recheck unless historical migration is rewritten. |
| `ee15939d3` | 2023-12-09 | lain | Skip transaction to generate the index concurrently | implemented | AddQuoteUrlIndexToObjects disables the DDL transaction so the concurrent index can run on fresh installs. | No recheck. |
| `0e7531536` | 2023-12-09 | lain | Merge branch 'migration-fix' into 'develop' | implemented | Merge commit for the concurrent quoteUrl index migration fix; covered by 003d3312f and ee15939d3 rows. | No recheck. |
| `b70ca7d54` | 2023-12-07 | kPherox | fix: AnalyzeMetadata filter no longer depends on ImageMagick's commands | implemented | Application requirements no longer check mogrify/convert for AnalyzeMetadata after the Vix metadata backport. | No recheck unless upload metadata requirements change. |
| `0818a9136` | 2023-12-07 | kPherox | add changelog | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries the Unfathomably-facing media metadata note. | No code action. |
| `a67fc30d8` | 2023-12-09 | feld | Merge branch 'kphrx-develop-patch-87655' into 'develop' | implemented | Merge commit for removing ImageMagick command checks from AnalyzeMetadata; covered by b70ca7d54. | No recheck. |
| `06c58bce0` | 2023-11-16 | Haelwenn (lanodan) Monnier | scrubbers/default: Add more formatting elements from HTML4 / GoToSocial | implemented | Default scrubber allows the upstream HTML4/GoToSocial formatting tags while preserving Unfathomably MFM-specific classes and attributes. | No recheck unless scrubber policy changes. |
| `a7f82ff82` | 2023-12-10 | lain | Merge branch 'scrubbers-html4-GtS' into 'develop' | implemented | Merge commit for the HTML4/GoToSocial scrubber additions; covered by 06c58bce0. | No recheck. |
| `074b31d9a` | 2023-12-08 | Mark Felder | Optimistic Inbox | implemented | `lib/pleroma/web/activity_pub/activity_pub_controller.ex`, `lib/pleroma/web/federator.ex`, `lib/pleroma/workers/signature_retry_worker.ex` | Local BE uses the optimistic failed-signature inbox path and a stricter retry worker that revalidates signature, actor identity, and host headers before handing the activity to the normal federator. |
| `0d3f1be23` | 2023-12-08 | Mark Felder | Fix test; log message no longer emitted here | not-applicable | `test/pleroma/signature_test.exs` | Test-only upstream cleanup; local signature retry coverage follows the newer worker path instead of relying on this removed log message. |
| `ce5acd415` | 2023-12-08 | Mark Felder | get_cached_by_ap_id/1 returns a single result, not a tuple | implemented | `lib/pleroma/user.ex` | Fixed cached current and historical public-key lookup paths so they match `get_cached_by_ap_id/1` returning `%User{}` or `nil`. |
| `1b5964979` | 2023-12-08 | Mark Felder | Optimistic Inbox | not-applicable | `CHANGELOG.md` | Upstream changelog-only commit; local changelog records the compatible implementation and fixes. |
| `97cf78f63` | 2023-12-08 | Mark Felder | Remove unnecessary forced refresh of user | superseded | `lib/pleroma/user.ex` | Superseded by upstream revert `94daa3e8c`; local BE keeps the safer `needs_update?/1` refresh path. |
| `1d417d2a3` | 2023-12-08 | Mark Felder | Our version of Oban only supports priorities 0-3 | superseded | `lib/pleroma/web/federator.ex` | Local failed-signature optimistic inbox jobs already use priority 2 and inbound Deletes use priority 3; the remaining ordinary verified inbox priority is allowed by the current Oban release train. |
| `403910650` | 2023-12-08 | Mark Felder | Fix the req_headers formatting | implemented | `lib/pleroma/workers/signature_retry_worker.ex` | Local signature retry worker normalizes serialized list headers and tuple headers before rebuilding the Plug connection used for validation. |
| `82724f666` | 2023-12-09 | Mark Felder | Do not retry fetching deleted objects | implemented | `lib/pleroma/workers/receiver_worker.ex` | Local receiver error handling unwraps nested errors and cancels terminal deleted-object fetches instead of retrying them. |
| `94daa3e8c` | 2023-12-09 | Mark Felder | Revert "Remove unnecessary forced refresh of user" | implemented | `lib/pleroma/user.ex` | Local `get_or_fetch_by_ap_id/1` retains the `needs_update?/1` forced-refresh behavior. |
| `d417f7321` | 2023-12-09 | Mark Felder | Process inbound Delete activities at lowest priority | implemented | `lib/pleroma/web/federator.ex` | Incoming `Delete` activities enqueue through `ReceiverWorker` at priority 3. |
| `223c1bac8` | 2023-12-10 | Mark Felder | Cancel the job if the signature is still invalid after a refetch of the public key | implemented | `lib/pleroma/workers/signature_retry_worker.ex`, `lib/pleroma/workers/receiver_worker.ex` | Local retry workers cancel invalid signatures after refetch/revalidation instead of cycling forever. |
| `18deea59b` | 2023-12-10 | Mark Felder | ActivityPub.make_user_from_ap_id/1 fetches the whole actor object including updating the public key for us | implemented | `lib/pleroma/signature.ex` | Local `Signature.refetch_public_key/1` already refreshes through `ActivityPub.make_user_from_ap_id/1` before reading the actor key. |
| `c0a50b7c3` | 2023-12-10 | Mark Felder | User.get_or_fetch_public_key_for_ap_id/1 is no longer required. | superseded | `lib/pleroma/user.ex`, `lib/pleroma/signature.ex` | Kept intentionally because later upstream authorized-fetch work reintroduced this helper; local BE needs the fetch-capable key path. |
| `e7974afd3` | 2023-12-11 | lain | Merge branch 'optimistic-inbox' into 'develop' | implemented | `lib/pleroma/web/activity_pub/activity_pub_controller.ex`, `lib/pleroma/web/federator.ex`, `lib/pleroma/workers/signature_retry_worker.ex` | Cluster reviewed; local implementation includes the optimistic inbox behavior plus later host-header and actor-mapping hardening. |
| `600364f4f` | 2023-12-11 | Lain Soykaf | Gitlab CI: Build using system provided libvips | implemented | `Dockerfile`, `docs/installation/generic_dependencies.include`, `docs/installation/optional/media_graphics_packages.md` | Local build/runtime dependencies use platform libvips, matching the upstream release-build direction. |
| `7cf65cfee` | 2023-12-11 | Lain Soykaf | Changelog | not-applicable | `CHANGELOG.md` | Upstream changelog marker only; local changelog records the modernized libvips backport. |
| `8d4a47bf9` | 2023-12-11 | lain | Merge branch 'build-releases-with-provided-libvips-2' into 'develop' | implemented | `Dockerfile`, `mix.exs`, `mix.lock` | Merge-only libvips/Vix build cluster; local BE already uses platform libvips and current Vix. |
| `c62696c8e` | 2023-11-02 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Support /authorize-interaction route used by Mastodon | implemented | `lib/pleroma/web/router.ex`, `lib/pleroma/web/twitter_api/controllers/remote_follow_controller.ex` | Local BE exposes `/authorize-interaction` as a Mastodon-compatible alias. |
| `41c02b3d1` | 2023-12-11 | lain | Merge branch 'authorize-interaction' into 'develop' | implemented | `lib/pleroma/web/router.ex` | Merge-only route cluster; local alias route is present. |
| `8b4a78626` | 2023-12-11 | Lain Soykaf | Use version of vix that compiles correctly under arm32 | implemented | `mix.exs`, `mix.lock` | Local BE uses Hex Vix 0.40.0 with platform libvips rather than the old arm32-problematic version. |
| `1d51ae757` | 2023-12-11 | lain | Merge branch 'build-releases-with-provided-libvips-2' into 'develop' | implemented | `mix.exs`, `mix.lock`, `Dockerfile` | Merge-only Vix/libvips cluster; local dependency and Docker paths are modernized. |
| `6c5ebcded` | 2023-12-12 | Lain Soykaf | Mix: Update vix. | implemented | `mix.exs`, `mix.lock` | Local BE resolves Vix to 0.40.0. |
| `3c89f3cf1` | 2023-12-12 | lain | Merge branch 'build-releases-with-provided-libvips-2' into 'develop' | implemented | `mix.exs`, `mix.lock`, `Dockerfile` | Merge-only Vix/libvips cluster; no further action. |
| `7371e72e6` | 2023-12-12 | Lain Soykaf | Dockerfile: Use platform libvips. | implemented | `Dockerfile` | Build stage installs `libvips-dev`; runtime installs `libvips42`. |
| `e9d9caa77` | 2023-12-12 | lain | Merge branch 'fix-dockerfile' into 'develop' | implemented | `Dockerfile` | Merge-only Dockerfile libvips fix; local Dockerfile has the dependency split. |
| `da3d1157e` | 2023-12-12 | Lain Soykaf | Fix dockerfile compilation. | implemented | `Dockerfile` | Docker source build compiled successfully on the live promotion path after the libvips work. |
| `31a524fb5` | 2023-12-12 | lain | Merge branch 'docker-fix-22' into 'develop' | implemented | `Dockerfile` | Merge-only Docker compilation fix; local Dockerfile includes the relevant dependency adjustments. |
| `221f18dc3` | 2023-12-10 | Lain Soykaf | Tests: Don't run tests that use clear_config asynchronously. | not-applicable | `test/pleroma/*` | Upstream test scheduling cleanup; no runtime behavior to backport. |
| `075222525` | 2023-12-10 | Lain Soykaf | TransmogrifierTest: Capture the log | not-applicable | `test/pleroma/web/activity_pub/transmogrifier_test.exs` | Test log-noise cleanup only; no runtime behavior to backport. |
| `b7ce2cf6a` | 2023-12-10 | Lain Soykaf | Add .rgignore for easier grepping | implemented | `.rgignore` | Added upstream ignore for generated `priv/static` content. |
| `68f7a79f2` | 2023-12-10 | Lain Soykaf | Tests: Remove async from cases that use Mock | not-applicable | `test/pleroma/*` | Test scheduling cleanup only; no runtime behavior to backport. |
| `e5beab7f1` | 2023-12-10 | Lain Soykaf | Config/Test: Don't start promex during testing. | implemented | `config/test.exs` | Local test config disables `Pleroma.PromEx`. |
| `20b76acc0` | 2023-12-10 | Lain Soykaf | ActivityPubTest: Swallow log | not-applicable | `test/pleroma/web/activity_pub/activity_pub_test.exs` | Test log-noise cleanup only; no runtime behavior to backport. |
| `c068a218e` | 2023-12-10 | Lain Soykaf | Backup Tests: Split out async tests, use mox. | implemented | `lib/pleroma/user/backup.ex`, `test/support/mocks.ex` | Backported processor injection and Mox behaviour while preserving local followers/following backup export additions. |
| `6e3267d1b` | 2023-12-10 | Lain Soykaf | Tests: Fix all the tests. | implemented | `config/test.exs`, `lib/pleroma/user/backup.ex` | Runtime-relevant backup config injection is present; remaining upstream hunks were test-only. |
| `06fc19677` | 2023-12-10 | Lain Soykaf | Backup: Fix config | implemented | `lib/pleroma/user/backup.ex`, `config/test.exs` | Backup module reads `:pleroma, Pleroma.User.Backup, :config_impl` via `Application.compile_env/3`. |
| `0d83b6d17` | 2023-12-10 | Lain Soykaf | Linting | not-applicable | `test/pleroma/user/backup_async_test.exs` | Test lint cleanup only; no runtime behavior to backport. |
| `0e005acd4` | 2023-12-10 | Lain Soykaf | CI: Use Elixir 1.13 for linting. | superseded | `.tool-versions`, `mix.exs` | Local BE targets a newer Elixir/OTP release train; older CI pin is intentionally not carried forward. |
| `90a47ca05` | 2023-12-11 | Lain Soykaf | S3 Test: Remove global state dependencies | implemented | `lib/pleroma/upload.ex`, `lib/pleroma/uploaders/s3.ex`, `test/support/mocks.ex` | Backported config and ExAws request injection so S3/upload tests can avoid global state. |
| `3cce929ee` | 2023-12-11 | Lain Soykaf | ChatValidationTest: Fix tests. | not-applicable | `test/pleroma/web/activity_pub/object_validators/chat_validation_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `2c10843bc` | 2023-12-11 | Lain Soykaf | MediaControllerTest: Fix test. | not-applicable | `test/pleroma/web/mastodon_api/controllers/media_controller_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `5a95847c5` | 2023-12-11 | Lain Soykaf | MediaProxyCacheControllerTest: Fix tests. | not-applicable | `test/pleroma/web/admin_api/controllers/media_proxy_cache_controller_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `5530c7dca` | 2023-12-11 | Lain Soykaf | MediaProxyTest: Fix test | not-applicable | `test/pleroma/web/media_proxy_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `305c76470` | 2023-12-11 | Lain Soykaf | OpenGraphTest: Fix test | not-applicable | `test/pleroma/web/metadata/providers/open_graph_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `42c11466c` | 2023-12-11 | Lain Soykaf | MediaProxyWarmingPolicyTest: Fix tests | not-applicable | `test/pleroma/web/activity_pub/mrf/media_proxy_warming_policy_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `60800c0b2` | 2023-12-11 | Lain Soykaf | ChatMessageReferenceView: Fix test | not-applicable | `test/pleroma/web/pleroma_api/views/chat_message_reference_view_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `b9f135eaf` | 2023-12-11 | Lain Soykaf | FrontendStaticPlugTest: Fix test | not-applicable | `test/pleroma/web/plugs/frontend_static_plug_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `8c0b1fd1d` | 2023-12-11 | Lain Soykaf | MediaProxyControllerTest: Fix tests | not-applicable | `test/pleroma/web/media_proxy/media_proxy_controller_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `844d0d314` | 2023-12-11 | Lain Soykaf | UploadTest: Fix test | not-applicable | `test/pleroma/upload_test.exs` | Test-only cleanup; source-level upload config injection is tracked under `90a47ca05`. |
| `50c31cb31` | 2023-12-11 | Lain Soykaf | RemoteFollowControllerTest: Fix test | not-applicable | `test/pleroma/web/twitter_api/remote_follow_controller_test.exs` | Test-only cleanup; `/authorize-interaction` runtime support is tracked under `c62696c8e`. |
| `e8e74146e` | 2023-12-11 | Lain Soykaf | MastodonAPI.AccountViewTest: Fix tests | not-applicable | `test/pleroma/web/mastodon_api/views/account_view_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `d3822269c` | 2023-12-11 | Lain Soykaf | ObjectTest: Fix tests | not-applicable | `test/pleroma/object_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `6a738720e` | 2023-12-11 | Lain Soykaf | ChatControllerTest: Fix tests | not-applicable | `test/pleroma/web/pleroma_api/controllers/chat_controller_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `d19f5d18e` | 2023-12-11 | Lain Soykaf | UpdateCredentialsTest: Fix tests | not-applicable | `test/pleroma/web/mastodon_api/update_credentials_test.exs` | Test-only cleanup; no runtime behavior to backport. |
| `6e448ef23` | 2023-12-11 | Lain Soykaf | ActivityPubTest: Fix tests | implemented | ActivityPub tests have been modernized for the current async/config setup. | No source change needed. |
| `f5a2337b3` | 2023-12-11 | Lain Soykaf | CommonAPITest: Fix tests | implemented | CommonAPI tests have been modernized for the current async/config setup. | No source change needed. |
| `82beb4987` | 2023-12-11 | Lain Soykaf | MascotControllerTest: Fix tests | implemented | Mascot controller tests have been modernized for current config isolation. | No source change needed. |
| `dec524e7d` | 2023-12-11 | Lain Soykaf | BackupViewTest: Fix Tests | implemented | Backup view tests cover the current backup state rendering. | No source change needed. |
| `54c0510d1` | 2023-12-11 | Lain Soykaf | Push.ImplTest: Fix tests | implemented | Push implementation tests have been modernized for current config isolation. | No source change needed. |
| `dd0cf0371` | 2023-12-11 | Lain Soykaf | AttachmentValidatorTest: Fix tests | implemented | Attachment validator tests have been modernized for the current validator shape. | No source change needed. |
| `d62b17eb6` | 2023-12-11 | Lain Soykaf | UploadMediaPlugTest: Fix tests | implemented | Uploaded media plug tests now match the final media-host behavior. | Patched stale media-host redirect expectation while importing the rollback. |
| `e4292c94d` | 2023-12-11 | Lain Soykaf | BackupTest: Fix tests | implemented | Backup tests cover current backup state and processing behavior. | No source change needed. |
| `6be3704bc` | 2023-12-11 | Lain Soykaf | Linting | implemented | Linting-only cleanup is represented by current formatted code. | No source change needed. |
| `18ab36d70` | 2023-12-12 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into no-async-clear-config | superseded | Merge-only no-async-clear-config sync; individual test rows are tracked separately. | No source change needed. |
| `228966e6d` | 2023-12-12 | Lain Soykaf | Exiftool.ReadDescription: Remove wrong spec. | implemented | Exiftool.ReadDescription no longer carries the bad spec from this upstream cleanup. | No source change needed. |
| `8da1fd329` | 2023-12-12 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into no-async-clear-config | superseded | Merge-only no-async-clear-config sync; individual test rows are tracked separately. | No source change needed. |
| `22c4d89db` | 2023-12-12 | Lain Soykaf | ScheduledActivity: Use config mocking | implemented | ScheduledActivity tests use config mocking in the current test setup. | No source change needed. |
| `4ba03aa29` | 2023-12-12 | Lain Soykaf | MastodonAPITest: Fix tests | implemented | Mastodon API tests are updated for the current config isolation approach. | No source change needed. |
| `650edb60d` | 2023-12-12 | Lain Soykaf | ScheduledActivityControllerTest: Fix tests, make async. | implemented | ScheduledActivity controller tests are updated for current async/config setup. | No source change needed. |
| `00def0875` | 2023-12-12 | Lain Soykaf | RichMediaTest: Use mocked config | implemented | RichMedia tests use mocked configuration in the current test setup. | No source change needed. |
| `190120fd7` | 2023-12-12 | Lain Soykaf | Tests: More test fixes | implemented | Additional test fixes are represented by current updated tests. | No source change needed. |
| `b13820dcd` | 2023-12-12 | Lain Soykaf | Tests: Remove `skip_on_mac` tag | implemented | Mac-specific skip handling has been removed from the current test setup. | No source change needed. |
| `dca41cc4a` | 2023-12-12 | Lain Soykaf | EmailTest: use config mock | superseded | Upstream later reverted this email-test config mock change in the same branch. | No source change needed. |
| `05352330b` | 2023-12-12 | Lain Soykaf | Tests: fix more tests | superseded | Upstream later reverted this broader test-fix commit in the same branch. | No source change needed. |
| `877552c6f` | 2023-12-12 | Lain Soykaf | Linting | implemented | Linting-only cleanup is represented by current formatted code. | No source change needed. |
| `a989b793d` | 2023-12-12 | Lain Soykaf | Revert "Tests: fix more tests" | superseded | Revert row documents removal of the earlier test-fix commit; final local tests match the post-revert state. | No source change needed. |
| `cca6c20eb` | 2023-12-12 | Lain Soykaf | Revert "EmailTest: use config mock" | superseded | Revert row documents removal of the email-test config mock change; final local tests match the post-revert state. | No source change needed. |
| `2c560266e` | 2023-12-12 | lain | Merge branch 'no-async-clear-config' into 'develop' | superseded | Merge-only no-async-clear-config branch row; final individual test states are tracked above. | No source change needed. |
| `e7af2addd` | 2023-12-12 | Alexander Tumin | Add media proxy to opengraph rich media cards | implemented | Status rich-media card rendering proxies OpenGraph image URLs and tests cover proxied og image output. | No source change needed. |
| `29d202e1d` | 2023-12-13 | lain | Merge branch 'add-opengraph-rich-media-proxy' into 'develop' | superseded | Merge-only OpenGraph media-proxy row covered by status view behavior. | No source change needed. |
| `40fa1099b` | 2023-12-13 | Lain Soykaf | StatusViewTest: Fix tests. | implemented | Status view tests cover the current quote, OpenGraph, and status rendering behavior. | No source change needed. |
| `935dce9a0` | 2023-12-13 | Lain Soykaf | Gitlab CI: Update postgres for rum tests. | not_applicable | GitLab CI PostgreSQL service selection does not affect the local source distribution. | No source change needed. |
| `1458de92f` | 2023-12-13 | Lain Soykaf | Gitlab CI: Switch to our own docker hub | not_applicable | GitLab CI container registry selection is upstream infrastructure only. | No source change needed. |
| `02acf7c0b` | 2023-12-13 | lain | Merge branch 'fix-develop-tests' into 'develop' | superseded | Merge-only test-fix branch row; individual test and runtime rows are tracked nearby. | No source change needed. |
| `cb1b52d98` | 2023-12-15 | Yonle | ap userview: add outbox field. | implemented | ActivityPub service actor rendering includes an outbox field. | No source change needed. |
| `766011544` | 2023-12-15 | Lain Soykaf | UserViewTest: Add basice service actor test. | implemented | UserView tests cover service actor rendering. | No source change needed. |
| `7622a8397` | 2023-12-15 | lain | Merge branch 'service-actor-outbox' into 'develop' | superseded | Merge-only service actor outbox row covered by UserView behavior. | No source change needed. |
| `476fd01f8` | 2023-12-14 | Henry Jameson | Initial draft on frontends management | not_applicable | Upstream bundled frontend-management documentation is superseded by separate Unfathomably FE promotion workflow. | No source change needed. |
| `57445e65c` | 2023-12-14 | Henry Jameson | update, add images | not_applicable | Frontend-management documentation image update is upstream docs only. | No source change needed. |
| `e635ee8b3` | 2023-12-14 | Henry Jameson | changelog | not_applicable | Changelog entry for upstream frontend-management docs does not affect runtime behavior. | No source change needed. |
| `1b22f1348` | 2023-12-14 | Haelwenn (lanodan) Monnier | docs: Put a max version on erlang and elixir | not_applicable | Older upstream Erlang and Elixir maximum-version docs do not match Unfathomably latest-runtime policy. | No source change needed. |
| `272271d93` | 2023-12-14 | Haelwenn (lanodan) Monnier | docs: clang is also supported | not_applicable | Compiler support documentation note is upstream install-doc maintenance only. | No source change needed. |
| `35090f6ea` | 2023-12-14 | Haelwenn (lanodan) Monnier | TwitterAPI: Return proper error when healthcheck is disabled | implemented | Disabled healthcheck returns a proper 503 error payload. | No source change needed. |
| `08839602b` | 2023-12-14 | Haelwenn (lanodan) Monnier | mix: cherry-pick eblurhash latest git for system-CFLAGS | superseded | Current dependency train supersedes the old eblurhash system-CFLAGS pin. | No source change needed. |
| `41f6e8f7f` | 2023-12-14 | Haelwenn (lanodan) Monnier | mix: Bump elixir-captcha for system-CFLAGS | superseded | Current dependency train supersedes the old elixir-captcha system-CFLAGS bump. | No source change needed. |
| `b1ea63b4c` | 2023-12-14 | Haelwenn (lanodan) Monnier | changelog.d/system-cflags.fix: New entry | superseded | Changelog entry for old system-CFLAGS dependency pins is superseded by current dependency maintenance notes. | No source change needed. |
| `ad6a6aa07` | 2023-12-14 | tusooa | Bump version to 2.6.1 | not_applicable | Upstream 2.6.1 version bump does not map to Unfathomably release metadata. | No source change needed. |
| `948f01f19` | 2023-12-14 | tusooa | Bundle 2.6.1 frontend | not_applicable | Bundled upstream frontend artifact does not apply to the separate Unfathomably FE tree. | No source change needed. |
| `f07b134ad` | 2023-12-15 | Haelwenn | Fix formatting of changelog | not_applicable | Upstream changelog formatting cleanup does not affect current Unfathomably changelog structure. | No source change needed. |
| `6722b7f39` | 2023-12-16 | tusooa | Merge branch 'release/2.6.1' into 'stable' | superseded | Merge-only upstream release branch row. | No source change needed. |
| `453cb6a38` | 2023-12-15 | tusooa | Merge remote-tracking branch 'upstream/stable' into mergeback/2.6.1 | superseded | Merge-only upstream stable mergeback row. | No source change needed. |
| `f5559f3af` | 2023-12-15 | tusooa | Skip changelog for 2.6.1 mergeback | not_applicable | Changelog skip marker for upstream mergeback only. | No source change needed. |
| `147b37b89` | 2023-12-16 | Haelwenn | Merge branch 'mergeback/2.6.1' into 'develop' | superseded | Merge-only upstream 2.6.1 mergeback row. | No source change needed. |
| `3fbc80eb5` | 2023-12-16 | Lain Soykaf | B ActivityPub.Publisher: Prioritize direct mentions | implemented | ActivityPub publisher splits priority recipients and sends direct-addressed inboxes at higher priority. | No source change needed. |
| `c212fc1dc` | 2023-12-16 | Lain Soykaf | User: Ignore non-local users when setting 'last active at' | implemented | User last_active_at updates ignore non-local users. | No source change needed. |
| `a0f70cf7d` | 2023-12-16 | Lain Soykaf | Add changelog | implemented | Local changelog records the priority-recipient and local-activity accounting work. | No source change needed. |
| `77bb1bb6c` | 2023-12-16 | Lain Soykaf | Actually write changelog | implemented | Local changelog records the priority-recipient and local-activity accounting work. | No source change needed. |
| `c1423ddca` | 2023-12-17 | Lain Soykaf | ActivityPub.Publisher: Filter inboxes | implemented | ActivityPub publisher filters inboxes before enqueueing delivery jobs. | No source change needed. |
| `8893a044b` | 2023-12-18 | Haelwenn | Merge branch 'priority_activities' into 'develop' | superseded | Merge-only priority_activities row covered by publisher and user activity accounting rows. | No source change needed. |
| `e2066994b` | 2023-12-19 | Mark Felder | Fix Web Push notification delivery | implemented | Web push delivery adds the octet-stream content-type header. | No source change needed. |
| `99b07c817` | 2023-12-19 | feld | Merge branch 'web_push' into 'develop' | superseded | Merge-only web_push row covered by the concrete web push delivery fix. | No source change needed. |
| `bf57fd82b` | 2023-12-20 | Mark Felder | Clarify location of test.secret.exs file | not_applicable | Test secret file documentation clarification is upstream developer-doc maintenance only. | No source change needed. |
| `d72d42f9c` | 2023-12-20 | feld | Merge branch 'testsecrets' into 'develop' | not_applicable | Merge-only test secret documentation row. | No source change needed. |
| `9896b64f5` | 2023-12-20 | Mark Felder | Elixir 1.15: Chase the Logger.warn deprecation | implemented | Source no longer uses deprecated Logger.warn calls. | No source change needed. |
| `107f00d93` | 2023-12-20 | Mark Felder | OTP26: Chase the :slave.start/3 deprecation | implemented | Test cluster support no longer depends on deprecated :slave.start behavior. | No source change needed. |
| `3c80c8643` | 2023-12-20 | Mark Felder | Chase deprecations/warnings for Elixir 1.15 | implemented | Elixir 1.15 warning cleanup is represented by the current warning-clean source. | No source change needed. |
| `45150848f` | 2023-12-20 | Mark Felder | Backwards compatibility for OTP | implemented | OTP compatibility handling is represented in current test support configuration. | No source change needed. |
| `cbdd13417` | 2023-12-20 | feld | Merge branch 'deprecations' into 'develop' | superseded | Merge-only deprecation cleanup row covered by the concrete warning rows. | No source change needed. |
| `cd3abe0b4` | 2023-12-20 | Mark Felder | Fix more Logger warn -> warning | implemented | Logger.warn deprecation cleanup is complete in source. | No source change needed. |
| `2207fafa9` | 2023-12-20 | Mark Felder | Fix more Logger warn -> warning | implemented | Additional Logger.warn deprecation cleanup is complete in source. | No source change needed. |
| `fb3eb6e0a` | 2023-12-20 | Mark Felder | Fix more Logger warn -> warning | implemented | Additional Logger.warn deprecation cleanup is complete in source. | No source change needed. |
| `1fc53c307` | 2023-12-20 | Haelwenn (lanodan) Monnier | config/description.exs: Remove quack | implemented | Quack configuration references are absent from current config descriptions. | No source change needed. |
| `d9fe41a30` | 2023-12-20 | Mark Felder | More deprecation fixes | implemented | Additional deprecation cleanup is represented by current warning-clean source. | No source change needed. |
| `56618873a` | 2023-12-20 | feld | Merge branch 'deprecations' into 'develop' | superseded | Merge-only deprecation cleanup row covered by concrete warning rows. | No source change needed. |
| `928bda2e4` | 2023-12-20 | Mark Felder | Fix invalid string comparison for OTP versions and replace with config | implemented | OTP version compatibility logic uses numeric/runtime configuration rather than invalid string comparison. | No source change needed. |
| `344c798b4` | 2023-12-20 | feld | Merge branch 'fix-otp-comparison' into 'develop' | superseded | Merge-only OTP comparison fix row covered by compatibility behavior. | No source change needed. |
| `9effa24f3` | 2023-08-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Implement api/v2/instance route | implemented | /api/v2/instance route, OpenAPI operation, controller action, and tests are present. | No source change needed. |
| `79e46ce73` | 2023-08-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | InstanceView: Add common_information function | implemented | InstanceView uses shared common instance information for v1 and v2 rendering. | No source change needed. |
| `28ef5ebd3` | 2023-09-07 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update InstanceView.features | implemented | InstanceView feature metadata is updated and extended for local capabilities. | No source change needed. |
| `c6cedbb81` | 2023-10-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | InstanceV2: skip auth | implemented | /api/v2/instance is publicly accessible without auth. | No source change needed. |
| `1e9333a9a` | 2023-11-08 | Marcin MikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into instance-v2 | superseded | Merge-only instance-v2 branch sync covered by concrete instance route/view rows. | No source change needed. |
| `4f2fb8dc5` | 2023-12-21 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Use consistent terminology | pending |  | Review against local BE/FE behavior, then update this row. |
| `bd50892c2` | 2023-12-21 | Haelwenn | Merge branch 'instance-v2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f43f33e30` | 2023-12-19 | Mark Felder | Return a 400 from a bad delivery attempt to the inbox | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f1d70736` | 2023-12-22 | lain | Merge branch 'bad_inbox_request' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `28e5e6567` | 2023-12-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into webfinger-fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `40f170f0a` | 2023-12-27 | tusooa | Merge branch 'webfinger-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1a337dcc1` | 2023-12-27 | Mark Felder | These functions in Pleroma.Instances should be defdelegates to Pleroma.Instances.Instance | pending |  | Review against local BE/FE behavior, then update this row. |
| `47e00524f` | 2023-12-27 | feld | Merge branch 'instance-defdelegates' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f53197c82` | 2023-12-27 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix operation name typo | pending |  | Review against local BE/FE behavior, then update this row. |
| `017e35fbf` | 2023-12-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix some more typos | pending |  | Review against local BE/FE behavior, then update this row. |
| `81ce04990` | 2023-12-28 | Haelwenn | Merge branch 'typo' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7a58ddfa4` | 2023-12-27 | tusooa | Allow local user to have group actor type | pending |  | Review against local BE/FE behavior, then update this row. |
| `5459bbc1e` | 2023-12-27 | tusooa | Allow group actors to boost posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f5533b88` | 2023-12-27 | tusooa | Test group actor behaviour in SideEffects | pending |  | Review against local BE/FE behavior, then update this row. |
| `e34a975dd` | 2023-12-27 | tusooa | Do not boost if group is blocking poster | pending |  | Review against local BE/FE behavior, then update this row. |
| `e9d2fadd8` | 2023-12-27 | tusooa | Add changelog for group actors | pending |  | Review against local BE/FE behavior, then update this row. |
| `b273025fd` | 2023-12-27 | tusooa | Add pleroma:group_actors to instance features | pending |  | Review against local BE/FE behavior, then update this row. |
| `ddc321a09` | 2023-12-28 | Haelwenn | Merge branch 'tusooa/3205-group-actor' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1d816222e` | 2023-12-28 | Mark Felder | Remove support for multiple federation publisher modules | pending |  | Review against local BE/FE behavior, then update this row. |
| `3acfdb6f8` | 2023-12-28 | Mark Felder | Retire the Pleroma.Web.Federator.Publisher module | pending |  | Review against local BE/FE behavior, then update this row. |
| `e35fa60d8` | 2023-12-28 | Mark Felder | Remove reference to the :federation_publisher_modules setting in our config test | pending |  | Review against local BE/FE behavior, then update this row. |
| `013f7c4f8` | 2023-12-28 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `7f3a83d3e` | 2023-12-29 | Haelwenn | Merge branch 'remove-multiple-federator-modules' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `08ba9a15b` | 2023-12-28 | Mark Felder | Fix the Federator perform/2 Oban callback | pending |  | Review against local BE/FE behavior, then update this row. |
| `efd50759d` | 2023-12-28 | Mark Felder | Log errors when publishing activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `d519a535e` | 2023-12-28 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `3954dfd4f` | 2023-12-29 | feld | Merge branch 'remove-multiple-federator-modules' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `39dc6c65e` | 2023-12-29 | Haelwenn (lanodan) Monnier | ChatMessage: Tolerate attachment field set to an empty array | pending |  | Review against local BE/FE behavior, then update this row. |
| `a6fc97ffe` | 2023-12-29 | lain | Merge branch 'bugfix/chat-attachment-empty-array' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2950397d4` | 2023-12-29 | Mark Felder | Fix following redirects with Finch | pending |  | Review against local BE/FE behavior, then update this row. |
| `8ac445863` | 2023-12-29 | feld | Merge branch 'finch-redirects' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `77949d459` | 2023-12-29 | Mark Felder | Make the Publisher log error less noisy | pending |  | Review against local BE/FE behavior, then update this row. |
| `7ebca7ecf` | 2023-12-29 | Mark Felder | Activity publishing failures will prevent the job from retrying if the publishing request returns a 403 or 410 | pending |  | Review against local BE/FE behavior, then update this row. |
| `141702538` | 2023-12-29 | Mark Felder | Discard on a 404 as well | pending |  | Review against local BE/FE behavior, then update this row. |
| `4afe211e5` | 2023-12-29 | Mark Felder | Return the full tuple from Tesla | pending |  | Review against local BE/FE behavior, then update this row. |
| `833117f57` | 2023-12-29 | Mark Felder | Fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `f74f5e0a5` | 2023-12-29 | Haelwenn | Merge branch 'publisher' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `32d8e0d49` | 2024-01-04 | Alexander Tumin | Fix authentication check on account rendering when bio is defined | pending |  | Review against local BE/FE behavior, then update this row. |
| `67a5542a7` | 2024-01-05 | Haelwenn | Merge branch 'fix-account-auth-check' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `69e4ebbb8` | 2024-01-07 | Ekaterina Vaartis | Make remote emoji packs API use specifically the V1 URL | pending |  | Review against local BE/FE behavior, then update this row. |
| `29158681f` | 2024-01-07 | Ekaterina Vaartis | Fetch count before downloading the pack and use that as page size | pending |  | Review against local BE/FE behavior, then update this row. |
| `6a55b680a` | 2024-01-07 | Ekaterina Vaartis | Fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `8bc59e974` | 2024-01-10 | tusooa | Merge branch 'emoji-use-v1-api' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3c30eadd5` | 2024-01-11 | Mint | Fix duplicate inbox deliveries | pending |  | Review against local BE/FE behavior, then update this row. |
| `dcb2b1413` | 2024-01-11 | Mark Felder | Add test to validate shared inboxes are used when multiple recipients from the same instance are recipients | pending |  | Review against local BE/FE behavior, then update this row. |
| `379d7fafd` | 2024-01-11 | Mint | Merge branch 'use-shared-inbox-test' of pleromergit:pleroma/pleroma into fix-duplicate-inbox-deliveries | pending |  | Review against local BE/FE behavior, then update this row. |
| `d4b889783` | 2024-01-11 | feld | Merge branch 'fix-duplicate-inbox-deliveries' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `50edef5bc` | 2023-12-29 | Mark Felder | Change QTFastStart to recover gracefully if it encounters an error during bitstring matching | pending |  | Review against local BE/FE behavior, then update this row. |
| `9cc46c553` | 2024-01-13 | feld | Merge branch 'qtfaststart-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `765119850` | 2024-01-11 | Haelwenn (lanodan) Monnier | Support objects with a nil contentMap (firefish) | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3a4f5b7d` | 2024-01-13 | tusooa | Merge branch 'nil-contentMap' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4ca65c618` | 2024-01-07 | Haelwenn (lanodan) Monnier | MRF.StealEmojiPolicy: Properly add fallback extension to filenames missing one | pending |  | Review against local BE/FE behavior, then update this row. |
| `c29430b01` | 2024-01-15 | Haelwenn | Merge branch 'mrf-steal-emoji-extname' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6af49270a` | 2024-01-02 | Haelwenn (lanodan) Monnier | MRF: Log sensible error for subdomains_regex | pending |  | Review against local BE/FE behavior, then update this row. |
| `9b39bc6aa` | 2024-01-15 | Haelwenn | Merge branch 'mrf-regex-error' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e7d6b835a` | 2023-12-29 | Mark Felder | Fix tests by leveraging Keyword.equal?/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `e121e0621` | 2023-12-29 | Mark Felder | Implement a custom uri_equal?/2 to fix comparisons of URLs with unordered query parameters | pending |  | Review against local BE/FE behavior, then update this row. |
| `b51ba39dd` | 2023-12-29 | Mark Felder | Update Floki to get the :attributes_as_maps feature to allow us to compare equality of parsed documents without issues of key ordering | pending |  | Review against local BE/FE behavior, then update this row. |
| `36b386778` | 2023-12-29 | Mark Felder | Fix test "transforms config to tuples" | pending |  | Review against local BE/FE behavior, then update this row. |
| `d4dd21303` | 2023-12-29 | Mark Felder | Remove call to Pleroma.Web.Endpoint.config_change/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `0820c2398` | 2023-12-29 | Mark Felder | Fix Chat controller tests failing due to OTP26 key order change | pending |  | Review against local BE/FE behavior, then update this row. |
| `347e5f33c` | 2023-12-29 | Mark Felder | Fix regex string match due to OTP26 key order change | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b5168ae0` | 2023-12-29 | Mark Felder | Phoenix detects the webfinger requests with content-type application/jrd+json as "jrd" now | pending |  | Review against local BE/FE behavior, then update this row. |
| `04366492b` | 2023-12-29 | Mark Felder | ConfigDB export to file does not have a consistent order. | pending |  | Review against local BE/FE behavior, then update this row. |
| `63a74f7b6` | 2023-12-29 | Mark Felder | Support for Erlang OTP 26 | pending |  | Review against local BE/FE behavior, then update this row. |
| `c6acd2abb` | 2023-12-29 | Mark Felder | Revert grammar leak from bad merge | pending |  | Review against local BE/FE behavior, then update this row. |
| `8883fa326` | 2023-12-30 | Lain Soykaf | Mix: Update http_signatures version | pending |  | Review against local BE/FE behavior, then update this row. |
| `fc910f9bb` | 2023-12-30 | Lain Soykaf | Linting | pending |  | Review against local BE/FE behavior, then update this row. |
| `e7c641019` | 2024-01-15 | Mark Felder | Add Pleroma.Support.Helpers.uri_query_sort/1 for easy sorting of a URL's query parameters | pending |  | Review against local BE/FE behavior, then update this row. |
| `4cbf11d32` | 2024-01-15 | Mark Felder | Fix ChatController tests validating prev/next URLs by sorting the query parameters before comparison | pending |  | Review against local BE/FE behavior, then update this row. |
| `8bd8ee03c` | 2024-01-15 | Mark Felder | Add Pleroma.Test.Helpers.get_query_parameter/2 to retrieve specific query parameter values | pending |  | Review against local BE/FE behavior, then update this row. |
| `ad363c62c` | 2024-01-15 | Mark Felder | Fix StatusController test by using the get_query_parameter/2 helper to reliably retrieve the max_id value | pending |  | Review against local BE/FE behavior, then update this row. |
| `012ab8760` | 2024-01-16 | Mark Felder | Pleroma.Web.MastodonAPI.SubscriptionControllerTest: disable async and use on_exit/1 to ensure web push config gets restored | pending |  | Review against local BE/FE behavior, then update this row. |
| `e44f6a2ab` | 2024-01-15 | Mark Felder | Skip tests on MacOS/Darwin that have always failed | pending |  | Review against local BE/FE behavior, then update this row. |
| `355487041` | 2024-01-16 | Haelwenn | We are unsure if OTP27 will bring more breaking changes | pending |  | Review against local BE/FE behavior, then update this row. |
| `4c20713ec` | 2024-01-17 | Haelwenn | Merge branch 'otp26' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b39403a48` | 2024-01-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update API docs for my changes | pending |  | Review against local BE/FE behavior, then update this row. |
| `81a13b4b9` | 2024-01-18 | Haelwenn | Merge branch 'api-docs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ea0ec5fbc` | 2023-12-26 | Mark Felder | Remove Fetcher.fetch_object_from_id!/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `603e9f6a9` | 2023-12-26 | Mark Felder | Fix Transmogrifier tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `d472bafec` | 2023-12-26 | Mark Felder | Mark instances as unreachable when returning a 403 from an object fetch | pending |  | Review against local BE/FE behavior, then update this row. |
| `67dd81e82` | 2023-12-26 | Mark Felder | Consolidate the HTTP status code checking into the private get_object/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `c6b38441f` | 2023-12-26 | Mark Felder | Cancel remote fetch jobs for deleted objects | pending |  | Review against local BE/FE behavior, then update this row. |
| `c4f0a3b57` | 2023-12-26 | Mark Felder | Changelogs | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f6966cd9` | 2023-12-26 | Mark Felder | Remove mistaken duplicate fetch | pending |  | Review against local BE/FE behavior, then update this row. |
| `9c0040124` | 2023-12-26 | Mark Felder | Skip remote fetch jobs for unreachable instances | pending |  | Review against local BE/FE behavior, then update this row. |
| `73c4c6d7d` | 2023-12-26 | Mark Felder | Revert "Mark instances as unreachable when returning a 403 from an object fetch" | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f5109413` | 2023-12-27 | Mark Felder | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `d4c77103d` | 2023-12-27 | Mark Felder | Fix detection of user follower collection being private | pending |  | Review against local BE/FE behavior, then update this row. |
| `53db65678` | 2023-12-27 | Mark Felder | Separate files for each distinct sentence in the changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `be0cca9af` | 2023-12-27 | Mark Felder | RemoteFetcherWorker Oban job tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `6c9929b80` | 2023-12-27 | Mark Felder | Set Logger level to error | pending |  | Review against local BE/FE behavior, then update this row. |
| `becb07060` | 2023-12-27 | Mark Felder | Conslidate log messages for object fetcher failures and leverage Logger.metadata | pending |  | Review against local BE/FE behavior, then update this row. |
| `882267e3e` | 2023-12-27 | Mark Felder | Remove duplicate log messages from Transmogrifier | pending |  | Review against local BE/FE behavior, then update this row. |
| `287f2c971` | 2023-12-27 | Mark Felder | Formatting | pending |  | Review against local BE/FE behavior, then update this row. |
| `a2708f7fe` | 2023-12-27 | Mark Felder | Leverage existing atoms as return errors for the object fetcher | pending |  | Review against local BE/FE behavior, then update this row. |
| `ad0a5deb6` | 2023-12-27 | Mark Felder | Prevent requeuing Remote Fetcher jobs that exceed thread depth | pending |  | Review against local BE/FE behavior, then update this row. |
| `a6fd251e4` | 2023-12-27 | Mark Felder | Improve test descriptions | pending |  | Review against local BE/FE behavior, then update this row. |
| `aa070c7da` | 2023-12-28 | Mark Felder | Handle 401s as I have observed it in the wild | pending |  | Review against local BE/FE behavior, then update this row. |
| `f17f92105` | 2023-12-28 | Mark Felder | Oban jobs should be discarded on permanent errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `12c052551` | 2024-01-14 | Mark Felder | Allow the Remote Fetcher to attempt fetching an unreachable instance | pending |  | Review against local BE/FE behavior, then update this row. |
| `3c65a2899` | 2024-01-19 | Haelwenn | Merge branch 'handle_object_fetch_failures' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2a28377be` | 2024-01-20 | Mark Felder | Fix mix task pleroma.instance dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `df1d390a4` | 2024-01-20 | Mark Felder | Pleroma.Activity.Queries: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `b16a01ba9` | 2024-01-20 | Mark Felder | Pleroma.ApplicationRequirements: fix dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `dc8045d76` | 2024-01-20 | Mark Felder | FlakeId.Ecto.CompatType.t() does not exist | pending |  | Review against local BE/FE behavior, then update this row. |
| `0b7d21421` | 2024-01-20 | Mark Felder | Fix invalid typespec references to Ecto.Changeset.t() | pending |  | Review against local BE/FE behavior, then update this row. |
| `8ed506a37` | 2024-01-20 | Mark Felder | Fix invalid type | pending |  | Review against local BE/FE behavior, then update this row. |
| `559aeb5dd` | 2024-01-20 | Mark Felder | Add missing type Pleroma.Emoji.t() | pending |  | Review against local BE/FE behavior, then update this row. |
| `593c7e26d` | 2024-01-20 | Mark Felder | Fix invalid type | pending |  | Review against local BE/FE behavior, then update this row. |
| `e3f52ee13` | 2024-01-20 | Mark Felder | Fix invalid types | pending |  | Review against local BE/FE behavior, then update this row. |
| `467a65af9` | 2024-01-20 | Mark Felder | Fix invalid types | pending |  | Review against local BE/FE behavior, then update this row. |
| `09ae0ab24` | 2024-01-20 | Mark Felder | Fix invalid type | pending |  | Review against local BE/FE behavior, then update this row. |
| `65dfaa6cb` | 2024-01-20 | Mark Felder | Fix invalid type due to late aliasing | pending |  | Review against local BE/FE behavior, then update this row. |
| `e5120a270` | 2024-01-20 | Mark Felder | Fix invalid type due to typos | pending |  | Review against local BE/FE behavior, then update this row. |
| `f050a75b9` | 2024-01-20 | Mark Felder | Fix invalid types due to typos | pending |  | Review against local BE/FE behavior, then update this row. |
| `551e90cd5` | 2024-01-20 | Mark Felder | Fix invalid type | pending |  | Review against local BE/FE behavior, then update this row. |
| `2061a1d91` | 2024-01-20 | Mark Felder | Fix invalid type | pending |  | Review against local BE/FE behavior, then update this row. |
| `ec5ae83da` | 2024-01-20 | Mark Felder | Fix invalid types | pending |  | Review against local BE/FE behavior, then update this row. |
| `4f0711610` | 2024-01-20 | Mark Felder | Fix invalid type | pending |  | Review against local BE/FE behavior, then update this row. |
| `83eece776` | 2024-01-20 | Mark Felder | Fix invalid type | pending |  | Review against local BE/FE behavior, then update this row. |
| `38d01ff51` | 2024-01-20 | Mark Felder | Fix invalid types | pending |  | Review against local BE/FE behavior, then update this row. |
| `ea26add54` | 2024-01-20 | Mark Felder | Fix incorrect type definition for maybe_direct_follow/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `2fbb67add` | 2024-01-20 | Mark Felder | Fix typo in typespec | pending |  | Review against local BE/FE behavior, then update this row. |
| `7f649a7a1` | 2024-01-20 | Mark Felder | Dialyzer: remove function that will never match | pending |  | Review against local BE/FE behavior, then update this row. |
| `88042109a` | 2024-01-20 | Mark Felder | Dialyzer: fix pattern match coverage | pending |  | Review against local BE/FE behavior, then update this row. |
| `65ac51377` | 2024-01-20 | Mark Felder | Dialyzer: fix pattern match coverage | pending |  | Review against local BE/FE behavior, then update this row. |
| `029aaf3d7` | 2024-01-20 | Mark Felder | Use config to control max_restarts | pending |  | Review against local BE/FE behavior, then update this row. |
| `c7eda0b24` | 2024-01-20 | Mark Felder | Use config to control loading of custom modules | pending |  | Review against local BE/FE behavior, then update this row. |
| `4bb57d4f2` | 2024-01-20 | Mark Felder | Use config to control background migrators | pending |  | Review against local BE/FE behavior, then update this row. |
| `17877f612` | 2024-01-20 | Mark Felder | Use config to control streamer registry | pending |  | Review against local BE/FE behavior, then update this row. |
| `233010037` | 2024-01-20 | Mark Felder | Use config to control starting all HTTP pools in test env | pending |  | Review against local BE/FE behavior, then update this row. |
| `cca9d6aea` | 2024-01-20 | Mark Felder | Dialyzer fixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `dcd010280` | 2024-01-20 | Mark Felder | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `1edfce432` | 2024-01-21 | feld | Merge branch 'dialyzer-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a0518a4ee` | 2024-01-20 | Mark Felder | Add a build and test pipeline for elixir 1.15 with a new naming convention | pending |  | Review against local BE/FE behavior, then update this row. |
| `df31ec0d5` | 2024-01-20 | Mark Felder | Linting as a separate stage | pending |  | Review against local BE/FE behavior, then update this row. |
| `06ac829eb` | 2024-01-20 | Mark Felder | Spec building should be in build stage | pending |  | Review against local BE/FE behavior, then update this row. |
| `179040031` | 2024-01-20 | Mark Felder | Add Dialyxir with manual job execution | pending |  | Review against local BE/FE behavior, then update this row. |
| `68f421c20` | 2024-01-20 | Mark Felder | Use our own 1.15 ci-base image | pending |  | Review against local BE/FE behavior, then update this row. |
| `06813d4a0` | 2024-01-21 | Mark Felder | Reorganize ci scripts | pending |  | Review against local BE/FE behavior, then update this row. |
| `aee971bd2` | 2024-01-21 | Mark Felder | Only need amd64 for now | pending |  | Review against local BE/FE behavior, then update this row. |
| `058fa5471` | 2024-01-21 | Mark Felder | Fix the image name | pending |  | Review against local BE/FE behavior, then update this row. |
| `8f0051d73` | 2024-01-21 | Mark Felder | Rename 1.15 image to include otp25, clarify test names | pending |  | Review against local BE/FE behavior, then update this row. |
| `518ddd458` | 2024-01-21 | Mark Felder | Clarify formatting and cycles versions | pending |  | Review against local BE/FE behavior, then update this row. |
| `931fa4cb7` | 2024-01-21 | feld | Merge branch 'new-pipelines' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `badd7654f` | 2024-01-21 | Mark Felder | Fix testing cache policy | pending |  | Review against local BE/FE behavior, then update this row. |
| `12b689a81` | 2024-01-21 | feld | Merge branch 'new-pipelines' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `951a82f2d` | 2024-01-21 | Mark Felder | Fix testing cache policy | pending |  | Review against local BE/FE behavior, then update this row. |
| `548434f85` | 2024-01-21 | feld | Merge branch 'new-pipelines' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0ac010ba3` | 2024-01-22 | Mark Felder | Replace custom fifo implementation with Exile | pending |  | Review against local BE/FE behavior, then update this row. |
| `52aadc09e` | 2024-01-22 | lain | Merge branch 'exile' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `fff235433` | 2024-01-22 | Mark Felder | Exile: switch to fork with BSD compile fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `d802e65cd` | 2024-01-22 | feld | Merge branch 'exile-bsds' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1632a3fec` | 2024-01-22 | Mark Felder | Exile: fix for MacOS dev environments | pending |  | Review against local BE/FE behavior, then update this row. |
| `f7b3681eb` | 2024-01-22 | feld | Merge branch 'exile-macos' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8efae57d6` | 2024-01-22 | Mark Felder | Dialyzer: suppress Mix.Task errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `653b14e1c` | 2024-01-22 | Mark Felder | Use config to control Uploader callback timeout | pending |  | Review against local BE/FE behavior, then update this row. |
| `6df93e61c` | 2024-01-22 | Mark Felder | Use config to determine sending to the streamer registry instead of MIX_ENV compile time function definition | pending |  | Review against local BE/FE behavior, then update this row. |
| `eb4dd50f5` | 2024-01-22 | Mark Felder | Use config to control inclusion of test emoji | pending |  | Review against local BE/FE behavior, then update this row. |
| `38ebefce9` | 2024-01-22 | Mark Felder | Announcement: fix dialyzer errors and add typespec for the changeset | pending |  | Review against local BE/FE behavior, then update this row. |
| `bff47479a` | 2024-01-22 | Mark Felder | Exile: fix for MacOS dev environments | pending |  | Review against local BE/FE behavior, then update this row. |
| `136185621` | 2024-01-22 | Mark Felder | Pleroma.User.Backup: fix some dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `40feac086` | 2024-01-22 | Mark Felder | Pleroma.User: fix dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `10f3a2833` | 2024-01-22 | Mark Felder | Pleroma.User.Query: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `39da451b6` | 2024-01-22 | Mark Felder | Pleroma.Web.ActivityPub.Builder: fix dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `36355d3ed` | 2024-01-22 | Mark Felder | Pleroma.Web.ActivityPub.Builder: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `c74c5f479` | 2024-01-22 | Mark Felder | Pleroma.Migrators.Support.BaseMigratorState: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `65d49ac09` | 2024-01-22 | Mark Felder | Pleroma.HTTP.AdapterHelper: fix dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `6ce7011a2` | 2024-01-22 | Mark Felder | Pleroma.Gun.ConnectionPool.WorkerSupervisor: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `a7fa6f18d` | 2024-01-22 | Mark Felder | Pleroma.Migrators.Support.BaseMigrator: Fix dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f71928f6` | 2024-01-22 | Mark Felder | MRF.InlineQuotePolicy: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `0dd65246e` | 2024-01-22 | Mark Felder | MRF.HashtagPolicy: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `115b2ad63` | 2024-01-22 | Mark Felder | MRF.KeywordPolicy: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `138b3cb60` | 2024-01-22 | Mark Felder | Clear up missing function dialyzer errors for :eldap | pending |  | Review against local BE/FE behavior, then update this row. |
| `3a8594e92` | 2024-01-22 | Mark Felder | MastodonAPI.Controller.StatusController: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `626c22961` | 2024-01-23 | feld | Merge branch 'dialyzer-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f23c07f43` | 2024-01-26 | Mark Felder | Set correct image version | pending |  | Review against local BE/FE behavior, then update this row. |
| `6bd29956f` | 2024-01-26 | feld | Merge branch 'elixir-1.15-base' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a658cf70b` | 2024-01-26 | Mark Felder | Pin to otp25 | pending |  | Review against local BE/FE behavior, then update this row. |
| `a24322fcc` | 2024-01-26 | feld | Merge branch 'elixir-1.15-base' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `28af5e3bd` | 2024-01-26 | Mark Felder | TwitterAPI.UtilController: fix dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `06b8923d4` | 2024-01-26 | Mark Felder | RichMedia.Parser.TTL.AwsSignedUrl: dialyzer fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `87cf7010f` | 2024-01-26 | Mark Felder | Pleroma.Upload: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b40ebfa2` | 2024-01-26 | Mark Felder | Pleroma.Signature: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `e83434349` | 2024-01-26 | Mark Felder | Pleroma.Search.SearchBackend: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `6e0945354` | 2024-01-26 | Mark Felder | Pleroma.ModerationLog: fix invalid type | pending |  | Review against local BE/FE behavior, then update this row. |
| `b2ab47948` | 2024-01-26 | Mark Felder | Pleroma.Helpers.QtFastStart: Dialzyer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `7d7662277` | 2024-01-26 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `6fcecbd48` | 2024-01-27 | Mark Felder | Formatting | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1659b775` | 2024-01-27 | feld | Merge branch 'dialyzer-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3fbe8ada9` | 2024-01-27 | Mark Felder | Pleroma.ReverseProxy: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `2062e126f` | 2024-01-27 | Mark Felder | Pleroma.Web.ActivityPub.Builder: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `948d5a93a` | 2024-01-27 | Mark Felder | Pleroma.Object: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `9f357d88c` | 2024-01-27 | Mark Felder | Pleroma.Emoji: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `5c08153fc` | 2024-01-27 | Mark Felder | Pleroma.Gun.ConnectionPool.Reclaimer: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `94d7e28cb` | 2024-01-27 | Mark Felder | Pleroma.Web.ActivityPub.ObjectValidator: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f5bd64b8` | 2024-01-27 | Mark Felder | Pleroma.Web.ActivityPub.SideEffects: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `b6a1e7fb3` | 2024-01-27 | Mark Felder | Pleroma.Web.ActivityPub.SideEffects: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `5c193a34a` | 2024-01-27 | Mark Felder | Pleroma.Web.ActivityPub.SideEffects: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `861c8ebfe` | 2024-01-27 | Mark Felder | These are all due to Cachex typespec bugs | pending |  | Review against local BE/FE behavior, then update this row. |
| `8b02c8581` | 2024-01-27 | Mark Felder | Pleroma.Web.AdminAPI.MediaProxyCacheController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `17f4251b1` | 2024-01-27 | Mark Felder | Pleroma.Web.TwitterAPI.UtilController: dialyzer fixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `52e18a624` | 2024-01-27 | Mark Felder | Pleroma.Web.PleromaAPI.UserImportController: Dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `26a95e578` | 2024-01-27 | Mark Felder | Pleroma.Web.PleromaAPI.NotificationController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `60d89cb40` | 2024-01-27 | Mark Felder | Pleroma.Web.AdminAPI.ConfigController: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `563aebd5c` | 2024-01-28 | Mark Felder | Pleroma.Web.Plugs.UploadedMedia: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `9c8055d4b` | 2024-01-28 | Mark Felder | Pleroma.Web.PleromaAPI.MascotController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `a32d6b3aa` | 2024-01-28 | Mark Felder | Pleroma.Web.PleromaAPI.MascotController: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `77bf617c4` | 2024-01-28 | Mark Felder | Pleroma.Web.PleromaAPI.EmojiPackController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `dc912dc59` | 2024-01-28 | Mark Felder | Pleroma.Web.PleromaAPI.EmojiFileController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `456f7cab3` | 2024-01-28 | Mark Felder | Pleroma.Web.PleromaAPI.ChatController: Dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `8d64eedbe` | 2024-01-28 | Mark Felder | Pleroma.Web.PleromaAPI.ChatController: Dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `db87be126` | 2024-01-28 | Mark Felder | Pleroma.Web.AdminAPI.InviteController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `d92c3d927` | 2024-01-28 | Mark Felder | Pleroma.Web.AdminAPI.UserController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `94838ed94` | 2024-01-28 | Mark Felder | Pleroma.Web.AdminAPI.RelayController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `bfe626d57` | 2024-01-28 | Mark Felder | Pleroma.Web.AdminAPI.ReportController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `a3024dd5a` | 2024-01-28 | Mark Felder | Pleroma.Web.AdminAPI.InstanceDocumentController: fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `082d66516` | 2024-01-28 | Mark Felder | Pleroma.Web.AdminAPI.UserController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `e2fc03ec7` | 2024-01-28 | Mark Felder | Pleroma.Web.ActivityPub.Utils: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `e53c20b03` | 2024-01-28 | Mark Felder | Pleroma.Web.MastodonAPI.AccountController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `6a22a80f9` | 2024-01-28 | Mark Felder | Pleroma.Web.MastodonAPI.DirectoryController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `c9dc88174` | 2024-01-28 | feld | Merge branch 'dialyzer-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `5c5d9d9b9` | 2024-01-26 | Haelwenn (lanodan) Monnier | Bump dependencies | pending |  | Review against local BE/FE behavior, then update this row. |
| `18d38486a` | 2024-01-26 | Mark Felder | InetCidr.parse/2 is deprecated | pending |  | Review against local BE/FE behavior, then update this row. |
| `5b95abaee` | 2024-01-26 | Mark Felder | Credo.Check.Readability.PredicateFunctionNames | pending |  | Review against local BE/FE behavior, then update this row. |
| `251c455b9` | 2024-01-29 | Haelwenn | Merge branch 'deps-bump' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4fc177eb4` | 2024-01-29 | Mark Felder | Pleroma.Web.ControllerHelper: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `2de84e2e3` | 2024-01-29 | Mark Felder | API Specs: many dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `a26649277` | 2024-01-29 | Mark Felder | Pleroma.User: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `3cb280724` | 2024-01-29 | Mark Felder | Pleroma.Web.MastodonAPI.StatusView: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `378edeaf1` | 2024-01-29 | Mark Felder | Pleroma.Web.MastodonAPI.DomainBlockController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `8cd527985` | 2024-01-29 | Mark Felder | Pleroma.Web.MastodonAPI.MediaController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `b66671057` | 2024-01-29 | Mark Felder | Pleroma.Web.MediaProxy.MediaProxyController: dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `a3426fcaf` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.MastodonAPI.MediaController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `41493bd64` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.MastodonAPI.DomainBlockController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `1fa1a93cd` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.MastodonAPI.AccountController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `39241107d` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.AdminAPI.InstanceDocumentController: fix dialyzer error" | pending |  | Review against local BE/FE behavior, then update this row. |
| `da5e0fca4` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.AdminAPI.ReportController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `ac06a4768` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.AdminAPI.RelayController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `4227db087` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.AdminAPI.UserController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `589456f0b` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.AdminAPI.InviteController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `b709fc4df` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.PleromaAPI.ChatController: Dialyzer error" | pending |  | Review against local BE/FE behavior, then update this row. |
| `4a9ed4682` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.PleromaAPI.EmojiFileController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1a6102a8` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.PleromaAPI.EmojiPackController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `2c8e4f32c` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.PleromaAPI.MascotController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `1e76ceacd` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.AdminAPI.ConfigController: dialyzer error" | pending |  | Review against local BE/FE behavior, then update this row. |
| `4a80a285d` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.PleromaAPI.NotificationController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `674ae51d6` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.PleromaAPI.UserImportController: Dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `88a35b286` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.TwitterAPI.UtilController: dialyzer fixes" | pending |  | Review against local BE/FE behavior, then update this row. |
| `8476eb184` | 2024-01-30 | Mark Felder | Revert "Pleroma.Web.AdminAPI.MediaProxyCacheController: dialyzer errors" | pending |  | Review against local BE/FE behavior, then update this row. |
| `91a70ba55` | 2024-01-30 | Mark Felder | Bump open_api_spex | pending |  | Review against local BE/FE behavior, then update this row. |
| `608466d09` | 2024-01-30 | Mark Felder | Modify our CastAndValidate plug to include the new functionality provided by the :replace_params config option | pending |  | Review against local BE/FE behavior, then update this row. |
| `cfe7438b2` | 2024-01-30 | Mark Felder | Pleroma.Web.MastodonAPI.DomainBlockController: dialyzer fixes via :replace_params | pending |  | Review against local BE/FE behavior, then update this row. |
| `1bba02863` | 2024-01-30 | feld | Merge branch 'dialyzer-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `81c8592d6` | 2024-01-30 | Mark Felder | Pleroma.Web.MastodonAPI.AccountController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `dec82a6a3` | 2024-01-30 | Mark Felder | Phoenix.Endpoint.Cowboy2Handler does not exist | pending |  | Review against local BE/FE behavior, then update this row. |
| `ef1f30175` | 2024-01-30 | Mark Felder | Pleroma.Web.AdminAPI.ConfigController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `85c9397ec` | 2024-01-30 | Mark Felder | Pleroma.Web.AdminAPI.InstanceDocumentController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `ea26dcd80` | 2024-01-30 | Mark Felder | Pleroma.Web.AdminAPI.InviteController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `fb6f53fc1` | 2024-01-30 | Mark Felder | Pleroma.Web.AdminAPI.MediaProxyCacheController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `b84a33a10` | 2024-01-30 | Mark Felder | Pleroma.Web.AdminAPI.RelayController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `dd916e0b4` | 2024-01-30 | Mark Felder | Pleroma.Web.AdminAPI.ReportController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `f400224a0` | 2024-01-30 | Mark Felder | Pleroma.Web.AdminAPI.UserController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `14de8376a` | 2024-01-30 | Mark Felder | Pleroma.Web.MastodonAPI.FollowRequestController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `9741f045e` | 2024-01-30 | Mark Felder | Pleroma.Web.MastodonAPI.ListController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `90c9f38f4` | 2024-01-30 | Mark Felder | Pleroma.Web.MastodonAPI.MediaController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `0a6b2c958` | 2024-01-30 | Mark Felder | Pleroma.Web.MastodonAPI.NotificationController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3c6acd2f` | 2024-01-30 | Mark Felder | Pleroma.Web.MastodonAPI.PollController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `324fd0845` | 2024-01-30 | Mark Felder | Pleroma.Web.MastodonAPI.ScheduledActivityController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `fdddba100` | 2024-01-30 | Mark Felder | Pleroma.Web.MastodonAPI.SearchController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `4d20fbc6d` | 2024-01-31 | Mark Felder | Pleroma.Web.PleromaAPI.ChatController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `f1aeb8051` | 2024-01-31 | Mark Felder | Pleroma.Web.PleromaAPI.EmojiFileController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `9d16393d8` | 2024-01-31 | Mark Felder | Pleroma.Web.PleromaAPI.EmojiPackController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `e157fd60e` | 2024-01-31 | Mark Felder | Pleroma.Web.PleromaAPI.MascotController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `c39e4dd21` | 2024-01-31 | Mark Felder | Pleroma.Web.PleromaAPI.NotificationController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `976014988` | 2024-01-31 | Mark Felder | Pleroma.Web.PleromaAPI.UserImportController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `fb7535ff9` | 2024-01-31 | Mark Felder | MascotController dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `b8db67daf` | 2024-01-31 | Mark Felder | Pleroma.Web.MastodonAPI.StatusController: fix dialzyer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `225afe05b` | 2024-01-31 | Mark Felder | Pleroma.Web.TwitterAPI.UtilController: fix dialyzer errors with replace_params: false | pending |  | Review against local BE/FE behavior, then update this row. |
| `e17441b0e` | 2024-01-31 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `3b9d99151` | 2024-01-31 | feld | Merge branch 'dialyzer-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c6f783c55` | 2024-01-31 | Mark Felder | Pleroma.Web.ControllerHelper: fix @spec to resolve dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `ed2f8e45e` | 2024-01-31 | Mark Felder | Pleroma.Web.MastodonAPI.SearchController: fix dialyzer errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `5e8bedcca` | 2024-01-31 | Mark Felder | Pleroma.Web.PleromaAPI.MascotController: fix dialyzer error due to bad error match | pending |  | Review against local BE/FE behavior, then update this row. |
| `92992c022` | 2024-01-31 | Mark Felder | Pleroma.Web.OAuth.OAuthController: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `97c4d3bcc` | 2024-01-31 | Mark Felder | Pleroma.Web.Plugs.RateLimiter.Supervisor: dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `518a38577` | 2024-01-31 | Mark Felder | Fix dialyzer errors due to deprecated usage of put_layout/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `f933d24b0` | 2024-01-31 | Mark Felder | Pleroma.Config.DeprecationWarnings: fix type errors detected by gradient | pending |  | Review against local BE/FE behavior, then update this row. |
| `7745ee27b` | 2024-02-02 | Mark Felder | Pleroma.MFA.Totp.provisioning_uri/3: add @spec | pending |  | Review against local BE/FE behavior, then update this row. |
| `cccfdde14` | 2024-02-02 | Mark Felder | Pleroma.MFA: fix gradient error | pending |  | Review against local BE/FE behavior, then update this row. |
| `15621b728` | 2024-02-02 | Mark Felder | Pleroma.HTTP.RequestBuilder: fix gradient error | pending |  | Review against local BE/FE behavior, then update this row. |
| `ac7f2cf10` | 2024-02-02 | Mark Felder | Pleroma Emoji mix task: fix gradient error | pending |  | Review against local BE/FE behavior, then update this row. |
| `bff04da0f` | 2024-02-02 | Mark Felder | Pleroma.Emoji.Pack: fix gradient error | pending |  | Review against local BE/FE behavior, then update this row. |
| `d42b0eb29` | 2024-02-02 | Mark Felder | Pleroma.Config.DeprecationWarnings: fix gradient errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `a2c686e16` | 2024-02-02 | Mark Felder | Pleroma.Filter: fix gradient error | pending |  | Review against local BE/FE behavior, then update this row. |
| `0ffeb84f0` | 2024-02-02 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `0b9990a7e` | 2024-02-04 | feld | Merge branch 'dialyzer-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `04fc4edda` | 2024-02-04 | Mark Felder | Fix Rich Media Previews for updated activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `579561e97` | 2024-02-04 | Mark Felder | URI.authority is deprecated | pending |  | Review against local BE/FE behavior, then update this row. |
| `0cc038b67` | 2024-02-05 | Mark Felder | Ensure URLs with IP addresses for the host do not generate previews | pending |  | Review against local BE/FE behavior, then update this row. |
| `e95736277` | 2024-02-05 | feld | Merge branch 'rich-media-cache' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6b7b443ff` | 2024-02-06 | Mark Felder | Pleroma.Web.RichMedia.Parser: Remove test-specific codepaths | pending |  | Review against local BE/FE behavior, then update this row. |
| `9f2319e50` | 2024-02-06 | Mark Felder | RichMedia.Helpers: move the validate_page_url/1 function to the Parser module | pending |  | Review against local BE/FE behavior, then update this row. |
| `72480e7b2` | 2024-02-07 | feld | Merge branch 'rich-media-tests' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0eca3e38e` | 2024-02-09 | Mark Felder | Fix Gun connection supervisor logic error | pending |  | Review against local BE/FE behavior, then update this row. |
| `991807080` | 2024-02-09 | feld | Merge branch 'gun-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8daf19ec0` | 2024-02-12 | Alex Gleason | Fix notifications index | pending |  | Review against local BE/FE behavior, then update this row. |
| `cb4d3db8c` | 2024-02-12 | Mark Felder | Changelog for notifications fix pulled in from Rebased | pending |  | Review against local BE/FE behavior, then update this row. |
| `769e02d0d` | 2024-02-12 | feld | Merge branch 'notifications-query' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `67c3acde3` | 2024-02-12 | Mark Felder | Update .gitignore | pending |  | Review against local BE/FE behavior, then update this row. |
| `79d69ce72` | 2024-02-12 | feld | Merge branch 'gitignore' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `60ba6fd24` | 2024-02-14 | Mark Felder | MediaProxy RFC compliance | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b2f9d4a6` | 2024-02-14 | feld | Merge branch 'proxy-headers' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9a4c8e231` | 2024-02-14 | Mark Felder | Change some Gun connection pool logs to debug level | pending |  | Review against local BE/FE behavior, then update this row. |
| `af9bb77ca` | 2024-02-14 | feld | Merge branch 'gun-logs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `86e6d395d` | 2024-02-14 | Mark Felder | Fix atom leak in password digest functionality | pending |  | Review against local BE/FE behavior, then update this row. |
| `91c83a82a` | 2024-02-14 | Mark Felder | Fix atom leak in background worker | pending |  | Review against local BE/FE behavior, then update this row. |
| `9138754b0` | 2024-02-14 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `802c61888` | 2024-02-14 | feld | Merge branch 'atom-leaks' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0de1a7629` | 2024-01-26 | Haelwenn (lanodan) Monnier | Maps: Add filter_empty_values/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `acef2a4a4` | 2024-01-26 | Haelwenn (lanodan) Monnier | CommonFixes: Use Maps.filter_empty_values on fix_object_defaults | pending |  | Review against local BE/FE behavior, then update this row. |
| `558b42107` | 2024-01-26 | Haelwenn (lanodan) Monnier | Test incoming federation from Convergence AP Bridge | pending |  | Review against local BE/FE behavior, then update this row. |
| `799891d35` | 2024-01-26 | Haelwenn (lanodan) Monnier | Transmogrifier: Cleanup obsolete handling of `"contentMap": null` | pending |  | Review against local BE/FE behavior, then update this row. |
| `d19642d7e` | 2024-02-15 | Haelwenn | Merge branch 'bugfix-ccworks' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3b82864bc` | 2024-02-14 | Haelwenn (lanodan) Monnier | Config: Check the permissions of the linked file instead of the symlinkÃƒÂ¢Ã¢â‚¬Â Ã‚Âµ | pending |  | Review against local BE/FE behavior, then update this row. |
| `f28dcc9cb` | 2024-02-15 | Haelwenn | Merge branch 'config-stat-symlink' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6b74a5527` | 2022-07-01 | Mark Felder | InstanceStatic should have reasonable caching | pending |  | Review against local BE/FE behavior, then update this row. |
| `f2f455f28` | 2024-02-15 | lain | Merge branch 'frontend-caching' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0fcdcc230` | 2024-02-09 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Use User.full_nickname/1 in oauth html template | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3208d225` | 2024-02-15 | lain | Merge branch 'oauth-nickname' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `64ad451a7` | 2024-02-14 | Mark Felder | Websocket refactor to use Phoenix.Socket.Transport | pending |  | Review against local BE/FE behavior, then update this row. |
| `d0f4b2b02` | 2024-02-14 | Mark Felder | Remove invalid test | pending |  | Review against local BE/FE behavior, then update this row. |
| `6be129ead` | 2024-02-14 | Mark Felder | Websocket refactor changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `4dd8a1a1c` | 2024-02-15 | feld | Merge branch 'websocket-refactor' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0c5bec049` | 2024-02-15 | Mark Felder | Support Bandit as an alternate HTTP backend to Cowboy. This is currently considered experimental, but may improve performance and resource usage. | pending |  | Review against local BE/FE behavior, then update this row. |
| `202721e80` | 2024-02-15 | Mark Felder | Remove Cowboy-specific HTTP options | pending |  | Review against local BE/FE behavior, then update this row. |
| `b91317b9b` | 2024-02-15 | feld | Merge branch 'bandit' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4648997a1` | 2024-02-15 | Mark Felder | Support a new changelog entry type: deps | pending |  | Review against local BE/FE behavior, then update this row. |
| `772f8d08c` | 2024-02-15 | Mark Felder | Tesla changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `2a4fa4c40` | 2024-02-15 | Mark Felder | Add support for a "deps" changelog type and document deps changes since 2.6.1 release | pending |  | Review against local BE/FE behavior, then update this row. |
| `03834454d` | 2024-02-15 | feld | Merge branch 'tesla' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c9cd449bb` | 2024-02-16 | Mark Felder | Revert "Support a new changelog entry type: deps" | pending |  | Review against local BE/FE behavior, then update this row. |
| `1951d56ed` | 2024-02-16 | Mark Felder | Revert "Add support for a "deps" changelog type and document deps changes since 2.6.1 release" | pending |  | Review against local BE/FE behavior, then update this row. |
| `0fbec6b53` | 2024-02-16 | feld | Merge branch 'deps-changelog-revert' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2c9fed9b7` | 2024-02-16 | SyoBoN | Translated using Weblate (Japanese) | pending |  | Review against local BE/FE behavior, then update this row. |
| `a145d909b` | 2024-02-16 | Haelwenn | Merge branch 'weblate' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7e99d0619` | 2024-02-17 | Mark Felder | Force more frequent full_sweep GC runs on the Websocket processes | pending |  | Review against local BE/FE behavior, then update this row. |
| `0b9bc4a0d` | 2024-02-17 | feld | Merge branch 'memleak' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7d624c475` | 2024-02-20 | Haelwenn (lanodan) Monnier | StealEmojiPolicy: Sanitize shortcodes | pending |  | Review against local BE/FE behavior, then update this row. |
| `e149ee6e2` | 2024-02-20 | Haelwenn (lanodan) Monnier | Mergeback of security release 2.6.2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `f0468697c` | 2024-02-20 | Haelwenn | Merge branch 'mergeback/2.6.2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ac5576459` | 2024-02-22 | Mark Felder | Gun Connection Pool was not attempting to free a connection and retry once if the pool was full. | pending |  | Review against local BE/FE behavior, then update this row. |
| `72fc41d89` | 2024-02-22 | Mark Felder | Prevent publisher jobs from erroring if the connection pool is full | pending |  | Review against local BE/FE behavior, then update this row. |
| `00e828b1a` | 2024-02-23 | Haelwenn | Merge branch 'gun-pool-retry' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f4e48bc53` | 2024-02-23 | Mark Felder | Rename variable to make the worker retry logic easier to read | pending |  | Review against local BE/FE behavior, then update this row. |
| `6144cb43a` | 2024-02-23 | feld | Merge branch 'gun-pool-retry' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `267e20dbc` | 2024-02-23 | Mark Felder | Exile: change to upstream pre-release commit that fixes build on FreeBSD | pending |  | Review against local BE/FE behavior, then update this row. |
| `bd4d2e1d8` | 2024-02-23 | feld | Merge branch 'exile-freebsd' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6af6a9704` | 2024-02-23 | Haelwenn (lanodan) Monnier | RemoteFetcherWorker: Make sure {:error, _} is returned on failure | pending |  | Review against local BE/FE behavior, then update this row. |
| `03e54aaba` | 2024-02-24 | Haelwenn | Merge branch 'remote-fetcher-error' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `acb9e4607` | 2024-02-27 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add some missing fields to instanceV2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `8298b326a` | 2024-03-07 | tusooa | Merge branch 'instance-v2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b7c625db0` | 2024-03-07 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into link-verification | pending |  | Review against local BE/FE behavior, then update this row. |
| `961a5dd4c` | 2024-03-07 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add test | pending |  | Review against local BE/FE behavior, then update this row. |
| `139057f34` | 2024-03-08 | tusooa | Merge branch 'link-verification' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `54ff7234b` | 2024-03-07 | Mark Felder | Fix ffmpeg framegrabs with Exile | pending |  | Review against local BE/FE behavior, then update this row. |
| `72daf522c` | 2024-03-08 | feld | Merge branch 'fix-framegrabs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6b8c5e12d` | 2023-10-26 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add contact account to InstanceView | pending |  | Review against local BE/FE behavior, then update this row. |
| `9fc6676d8` | 2023-12-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into instance-contact-account | pending |  | Review against local BE/FE behavior, then update this row. |
| `c0c4a9ed0` | 2024-03-08 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into instance-contact-account | pending |  | Review against local BE/FE behavior, then update this row. |
| `df7a8d4ef` | 2024-03-10 | tusooa | Merge branch 'instance-contact-account' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8b651fab1` | 2024-03-15 | Haelwenn (lanodan) Monnier | AttachmentValidator: Set "Link" as default type | pending |  | Review against local BE/FE behavior, then update this row. |
| `48c22a67d` | 2024-03-15 | Haelwenn (lanodan) Monnier | QuestionOptionsValidator: set default AS types | pending |  | Review against local BE/FE behavior, then update this row. |
| `4ad1d02d7` | 2024-03-15 | Haelwenn (lanodan) Monnier | changelog.d/transient-validators-defaults.change: insert | pending |  | Review against local BE/FE behavior, then update this row. |
| `8a14fdbe4` | 2024-03-19 | lain | Update transient-validators-defaults.change | pending |  | Review against local BE/FE behavior, then update this row. |
| `d415686bb` | 2024-03-01 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Allow to group bookmarks in folders | pending |  | Review against local BE/FE behavior, then update this row. |
| `6ad4acea5` | 2024-03-02 | Kaede Fujisaki | Consider a case when inbox is nil | pending |  | Review against local BE/FE behavior, then update this row. |
| `2e548c31d` | 2024-03-02 | Kaede Fujisaki | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `fb1873b6e` | 2024-03-02 | Kaede Fujisaki | add changelog.d | pending |  | Review against local BE/FE behavior, then update this row. |
| `1311f8314` | 2024-03-02 | Kaede Fujisaki | add changelog.d | pending |  | Review against local BE/FE behavior, then update this row. |
| `0242c1f69` | 2024-03-02 | Kaede Fujisaki | fmt | pending |  | Review against local BE/FE behavior, then update this row. |
| `1422082bf` | 2024-03-07 | tusooa | Apply ledyba's suggestion(s) to 1 file(s) | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb0b17f4d` | 2024-03-10 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Include following/followers in backups | pending |  | Review against local BE/FE behavior, then update this row. |
| `0b5bba23c` | 2024-03-15 | feld | Merge branch 'backups' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9cfa4e67b` | 2024-03-01 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add ForceMention mrf | pending |  | Review against local BE/FE behavior, then update this row. |
| `95bcd5d28` | 2024-03-17 | lain | Merge branch 'force-mention' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0450da88b` | 2024-03-17 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-fix-3241 | pending |  | Review against local BE/FE behavior, then update this row. |
| `caf855cf9` | 2024-03-17 | Lain Soykaf | ActivityPub.Publisher: Don't try federating if a user doesn't have an inbox. | pending |  | Review against local BE/FE behavior, then update this row. |
| `56e456fb5` | 2024-03-17 | lain | Merge branch 'fix-3241' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f0cca36e0` | 2024-03-17 | Lain Soykaf | CI: Remove RUM tests. | pending |  | Review against local BE/FE behavior, then update this row. |
| `d5b64846e` | 2024-03-17 | lain | Merge branch 'remove-rum-tests' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a48f5f860` | 2024-03-17 | Matthieu Rakotojaona | Notifications: filter on users rather than activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `4f7f44ced` | 2024-03-17 | lain | Merge branch 'develop' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `93370b870` | 2023-10-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Expose nonAnonymous field from Smithereen polls | implemented | `lib/pleroma/web/activity_pub/object_validators/question_validator.ex`, `lib/pleroma/web/mastodon_api/views/poll_view.ex` | Smithereen `nonAnonymous` poll metadata is validated and rendered as `non_anonymous`. |
| `e5bd1ee80` | 2023-10-29 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add entry to @context, tests | implemented | `priv/static/schemas/litepub-0.1.jsonld` | LitePub context maps `nonAnonymous` for Smithereen poll compatibility. |
| `fa02a1e63` | 2024-01-19 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update MastoAPI responses docs | pending |  | Review against local BE/FE behavior, then update this row. |
| `a5f64ffd0` | 2024-01-19 | Haelwenn | Apply lanodanÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢s suggestion to 1 file | pending |  | Review against local BE/FE behavior, then update this row. |
| `ab3f03a04` | 2024-01-21 | Haelwenn | Merge branch 'develop' into 'public-polls' | pending |  | Review against local BE/FE behavior, then update this row. |
| `def088ce5` | 2024-01-21 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | format | pending |  | Review against local BE/FE behavior, then update this row. |
| `c592a0e58` | 2024-02-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into HEAD | pending |  | Review against local BE/FE behavior, then update this row. |
| `cf0aa1238` | 2024-03-18 | lain | Merge branch 'public-polls' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2b71f4897` | 2024-03-18 | lain | Merge branch 'develop' into 'bookmark-folders' | pending |  | Review against local BE/FE behavior, then update this row. |
| `60c4cb21e` | 2024-03-18 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | InstanceView: Update features | pending |  | Review against local BE/FE behavior, then update this row. |
| `0e4e20315` | 2024-03-18 | lain | Merge branch 'bookmark-folders' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7f97fbc1a` | 2024-03-18 | Mark Felder | Update minimum Postgres version to 11.0; disable JIT | pending |  | Review against local BE/FE behavior, then update this row. |
| `1413d2e51` | 2024-03-18 | Mark Felder | Remove vestiges of old Postgres support | pending |  | Review against local BE/FE behavior, then update this row. |
| `b822a912a` | 2024-03-18 | Mark Felder | Remove test for postgres < 11 | pending |  | Review against local BE/FE behavior, then update this row. |
| `357553a64` | 2024-03-18 | Mark Felder | Remove usage of :persistent_term for Postgres version storage, fix test | pending |  | Review against local BE/FE behavior, then update this row. |
| `ca5766c0a` | 2024-03-19 | lain | Merge branch 'postgres-bump' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `923803a53` | 2024-03-19 | Lain Soykaf | Tests: Explicitly set db pool size and max cases to the same value. | pending |  | Review against local BE/FE behavior, then update this row. |
| `3cc8414c2` | 2024-03-19 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `665947ab2` | 2024-03-19 | Lain Soykaf | Tests: Reduced the max case number to make tests more stable. | pending |  | Review against local BE/FE behavior, then update this row. |
| `8e37f1988` | 2024-03-19 | lain | Merge branch 'test-improvements' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9617189e9` | 2024-03-19 | Lain Soykaf | Tests: Actually run the bookmark folder tests. | pending |  | Review against local BE/FE behavior, then update this row. |
| `afae3a94a` | 2024-03-19 | Lain Soykaf | CI: Move changelog check to later in the pipeline | pending |  | Review against local BE/FE behavior, then update this row. |
| `040a98027` | 2024-03-19 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `4e37cd85e` | 2024-03-19 | lain | Merge branch 'fix-bookmark-test' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4e8a1b40c` | 2024-03-19 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into transient-validators-defaults | pending |  | Review against local BE/FE behavior, then update this row. |
| `f775a1931` | 2024-03-19 | lain | Merge branch 'transient-validators-defaults' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `37ec645ff` | 2024-03-20 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix BookmarkFolderView, add test | pending |  | Review against local BE/FE behavior, then update this row. |
| `987f44d81` | 2024-03-20 | lain | Merge branch 'bookmark-folders' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4f5c4d79c` | 2024-04-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | FEP-2c59, add "webfinger" to user actor | pending |  | Review against local BE/FE behavior, then update this row. |
| `d80e0d687` | 2024-04-12 | tusooa | Merge branch 'user-actor-webfinger' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `741f22bfe` | 2024-03-19 | Mark Felder | MediaHelper: cache failed URLs for 15 minutes to prevent excessive retries | pending |  | Review against local BE/FE behavior, then update this row. |
| `71a037323` | 2024-04-17 | Haelwenn | Merge branch 'ffmpeg-limiter' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a299ddb10` | 2024-04-17 | Haelwenn (lanodan) Monnier | ReceiverWorker: Make sure non-{:ok, _} is returned as {:error, ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦} | pending |  | Review against local BE/FE behavior, then update this row. |
| `87b8ac3ce` | 2024-04-19 | lain | Merge branch 'receiverworker-error-handling' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6f6bede90` | 2024-04-19 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Include image description in status media cards | pending |  | Review against local BE/FE behavior, then update this row. |
| `50af909c0` | 2024-04-19 | lain | Merge branch 'pleroma-card-image-description' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `637f5bc43` | 2024-04-27 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix type in description | pending |  | Review against local BE/FE behavior, then update this row. |
| `ffa6805c0` | 2024-05-07 | lain | Merge branch 'description-type' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `750fb25f4` | 2024-05-07 | feld | Revert "Merge branch 'pleroma-card-image-description' into 'develop'" | pending |  | Review against local BE/FE behavior, then update this row. |
| `b42963a52` | 2024-05-07 | feld | Merge branch 'revert-50af909c' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ede414094` | 2024-05-07 | Mark Felder | RichMedia refactor | pending |  | Review against local BE/FE behavior, then update this row. |
| `df0734fcb` | 2024-05-07 | Mark Felder | Increase the :max_body for Rich Media to 5MB | pending |  | Review against local BE/FE behavior, then update this row. |
| `f40084e01` | 2024-05-07 | Mark Felder | Fix broken tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `d21aa1a77` | 2024-05-07 | Mark Felder | Respect the TTL returned in OpenGraph tags | pending |  | Review against local BE/FE behavior, then update this row. |
| `5a5a19387` | 2024-05-07 | Mark Felder | Fix broken Rich Media parsing when the image URL is a relative path | pending |  | Review against local BE/FE behavior, then update this row. |
| `fa66bd95d` | 2024-05-08 | Mark Felder | Rich Media Cards are cached by URL not per status | pending |  | Review against local BE/FE behavior, then update this row. |
| `c16c023eb` | 2024-05-08 | Mark Felder | Rich Media Cards are fetched asynchonously and not guaranteed to be available on first post render | pending |  | Review against local BE/FE behavior, then update this row. |
| `5bbcf5b8b` | 2024-05-08 | Mark Felder | Improve test description | pending |  | Review against local BE/FE behavior, then update this row. |
| `37de58823` | 2024-05-08 | Mark Felder | Remove test validating missing descriptions are returned as an empty string | pending |  | Review against local BE/FE behavior, then update this row. |
| `19002fd6c` | 2024-05-08 | Mark Felder | Mastodon API: Remove deprecated GET /api/v1/statuses/:id/card endpoint | pending |  | Review against local BE/FE behavior, then update this row. |
| `9b9a32bf7` | 2024-05-07 | Mark Felder | Fix compile warning | pending |  | Review against local BE/FE behavior, then update this row. |
| `37c35daba` | 2024-05-07 | Mark Felder | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `9a83301ff` | 2024-05-07 | Mark Felder | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `54c2bab25` | 2024-05-07 | Mark Felder | Fix module struct matching | pending |  | Review against local BE/FE behavior, then update this row. |
| `8eea4f58c` | 2024-05-08 | feld | Merge branch 'rich-media-db' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `818d9f7b6` | 2024-05-08 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Include image description in status media cards | pending |  | Review against local BE/FE behavior, then update this row. |
| `5e7f4f687` | 2024-05-08 | Mark Felder | Improve StatusView tests for Cards | pending |  | Review against local BE/FE behavior, then update this row. |
| `ccceb41bf` | 2024-05-08 | Mark Felder | Add test for StatusView rendering of Cards when missing descriptions | pending |  | Review against local BE/FE behavior, then update this row. |
| `6cfb0d7dd` | 2024-05-08 | feld | Merge branch 'restore/card-img-alt' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1bf3ae07b` | 2024-05-09 | faried nawaz | add options to mix pleroma.database prune_objects to delete more activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `fdc3cbb8c` | 2024-05-09 | faried nawaz | add documentation for the prune_objects mix task options | pending |  | Review against local BE/FE behavior, then update this row. |
| `c899af1d6` | 2022-08-05 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Reject requests from specified instances if `authorized_fetch_mode` is enabled | implemented | `config/config.exs`, `config/description.exs`, `lib/pleroma/web/plugs/http_signature_plug.ex` | Local BE has `:activitypub, :authorized_fetch_mode_exceptions` and HTTP-signature exception handling. |
| `6e51845d4` | 2022-12-27 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'pleroma/develop' into secure-mode | pending |  | Review against local BE/FE behavior, then update this row. |
| `fa2a6d5d6` | 2022-07-07 | Claudio Maradonna | feat: simple, but not stupid, uploader for IPFS | implemented | `lib/pleroma/uploaders/ipfs.ex`, `config/config.exs`, `config/description.exs` | Backported optional IPFS uploader with safer URL joining and explicit writable-gateway config. |
| `43dfa58eb` | 2022-07-07 | Claudio Maradonna | added tests for ipfs uploader. adapted changelog.md accordingly. improved ipfs uploader with external suggestions | implemented | `lib/pleroma/uploaders/ipfs.ex`, `CHANGELOG.md` | Runtime improvements and changelog are present; old upstream tests were not copied verbatim. |
| `44659ecd6` | 2022-07-07 | Claudio Maradonna | ipfs: revert to String.replace for cid placeholder | implemented | `lib/pleroma/uploaders/ipfs.ex` | IPFS get URL uses string replacement for `{CID}`. |
| `7c1af86f9` | 2022-07-07 | Claudio Maradonna | ipfs: refactor final_url generation. add tests for final_url | implemented | `lib/pleroma/uploaders/ipfs.ex` | Local IPFS endpoint generation avoids `Path.join/2` on HTTP URLs and trims the base URL explicitly. |
| `98f268e5e` | 2022-07-07 | Claudio Maradonna | ipfs: small refactor and more tests | implemented | `lib/pleroma/uploaders/ipfs.ex` | Local IPFS uploader uses small helpers for upload, config lookup, and endpoint generation. |
| `254f2ea85` | 2022-07-07 | Claudio Maradonna | ipfs: remove unused alias | implemented | `lib/pleroma/uploaders/ipfs.ex` | Backported IPFS uploader has only the aliases it uses. |
| `5e097eb91` | 2022-07-07 | Claudio Maradonna | ipfs: better tests with @ilja suggestions | not-applicable | `lib/pleroma/uploaders/ipfs.ex` | Upstream test-only refinement; local runtime code carries the safer uploader behavior. |
| `21d9091f5` | 2022-07-08 | Claudio Maradonna | ipfs: replacing single quotes with double quotes | implemented | `lib/pleroma/uploaders/ipfs.ex` | Local IPFS uploader uses normal double-quoted strings. |
| `3cad57bf4` | 2024-05-07 | Mark Felder | Add configuration[statuses][characters_reserved_per_url] to /api/v2/instance | pending |  | Review against local BE/FE behavior, then update this row. |
| `b97938995` | 2024-05-07 | Mark Felder | Add configuration[accounts][max_pinned_statuses] to /api/v2/instance | pending |  | Review against local BE/FE behavior, then update this row. |
| `06c26bf9c` | 2024-05-07 | Mark Felder | Add the absent max_featured_tags to the api spec for /api/v1/instance | pending |  | Review against local BE/FE behavior, then update this row. |
| `acf73f7e1` | 2024-05-07 | Mark Felder | Update changelog entry | pending |  | Review against local BE/FE behavior, then update this row. |
| `c954437cc` | 2024-05-11 | feld | Merge branch 'mastodon-instance-v2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `291d531e4` | 2024-03-19 | Mark Felder | Unify notification push and streaming events for both local and federated activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `c25fda34e` | 2024-03-19 | Mark Felder | Skip generating notifications for internal users | pending |  | Review against local BE/FE behavior, then update this row. |
| `16c72d070` | 2024-05-11 | Mark Felder | Merge branch 'develop' into fix-muted-web-push | pending |  | Review against local BE/FE behavior, then update this row. |
| `8da103da5` | 2024-05-15 | feld | Merge branch 'fix-muted-web-push' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `bd52e2aec` | 2022-05-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Instance rules | implemented | `lib/pleroma/rule.ex`, `lib/pleroma/web/admin_api/controllers/rule_controller.ex` | Instance rules schema, admin endpoints, and rendering are present locally. |
| `432599311` | 2022-05-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add GET /api/v1/instance/rules | implemented | `lib/pleroma/web/router.ex`, `lib/pleroma/web/mastodon_api/controllers/instance_controller.ex` | `/api/v1/instance/rules` is routed and documented locally. |
| `384f8bfa7` | 2022-05-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Instance rules: Use render_many | implemented | `lib/pleroma/web/mastodon_api/views/instance_view.ex` | Local instance-rule rendering follows the current view path. |
| `bbf3bc222` | 2022-05-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add RuleTest | not-applicable | `test/pleroma/web/admin_api/controllers/rule_controller_test.exs` | Upstream test-only commit; local rules behavior is present and covered by current tests. |
| `574db5b98` | 2022-05-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Allow submitting an array of rule_ids to /api/v1/reports | implemented | `lib/pleroma/web/common_api.ex`, `lib/pleroma/web/api_spec/operations/report_operation.ex` | Reports accept `rule_ids` and render associated rules locally. |
| `d26aadb74` | 2022-05-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add tests | not-applicable | `test/pleroma/web/mastodon_api/controllers/report_controller_test.exs` | Upstream test-only commit; report `rule_ids` behavior is already present. |
| `5c383ada8` | 2022-05-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Correctly order rules by id/creation date | implemented | `lib/pleroma/rule.ex` | Local rules are stored and exposed through the current rule schema/controller path. |
| `b354d70e8` | 2022-05-30 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Apply, suggestions, use strings for actual Mastodon API compatibility | implemented | `lib/pleroma/web/api_spec/operations/report_operation.ex` | Report `rule_ids` API shape uses string IDs for Mastodon compatibility. |
| `0ecd6ba35` | 2022-05-30 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | AdminAPI: Allow filtering reports by rule_id | implemented | `lib/pleroma/web/api_spec/operations/admin/report_operation.ex`, `lib/pleroma/web/admin_api/views/report_view.ex` | Admin report rule metadata and API paths are present locally. |
| `5846e7d5f` | 2022-06-01 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Use Repo.exists? | implemented | `lib/pleroma/rule.ex`, `lib/pleroma/web/common_api.ex` | Local rule/report lookup paths avoid loading unnecessary rows where existence checks are sufficient. |
| `6051715a9` | 2023-12-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into instance_rules | pending |  | Review against local BE/FE behavior, then update this row. |
| `f6fee39e4` | 2023-12-27 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `90b442727` | 2024-01-19 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update Admin API docs | pending |  | Review against local BE/FE behavior, then update this row. |
| `918c406a9` | 2024-03-18 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into instance_rules | pending |  | Review against local BE/FE behavior, then update this row. |
| `01a5f839c` | 2024-04-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into instance_rules | pending |  | Review against local BE/FE behavior, then update this row. |
| `ccc3ac241` | 2024-04-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add hint to rules | pending |  | Review against local BE/FE behavior, then update this row. |
| `53ef57673` | 2024-05-15 | feld | Merge branch 'instance_rules' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `dd0318481` | 2024-05-07 | Mark Felder | Strip actor from objects before federating | pending |  | Review against local BE/FE behavior, then update this row. |
| `2965ed47b` | 2024-05-15 | Mark Felder | Changelog for stripping actor from objects | pending |  | Review against local BE/FE behavior, then update this row. |
| `e944b1529` | 2024-05-15 | feld | Merge branch 'strip-object-actor' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7f8a9329e` | 2024-05-16 | Mark Felder | Startup detection for configured MRF modules that are missing or incorrectly defined | pending |  | Review against local BE/FE behavior, then update this row. |
| `7de657ac4` | 2024-05-16 | feld | Merge branch 'bad-mrf' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9988dc222` | 2024-05-16 | feld | Revert "Merge branch 'strip-object-actor' into 'develop'" | pending |  | Review against local BE/FE behavior, then update this row. |
| `99eab1fa2` | 2024-05-16 | feld | Merge branch 'revert-e944b152' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d07d49227` | 2024-05-18 | Mark Felder | PleromaAPI: marking notifications as read no longer returns notifications | pending |  | Review against local BE/FE behavior, then update this row. |
| `401aca254` | 2024-05-19 | lain | Merge branch 'mark-read' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9e6cf4590` | 2024-04-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | /api/v1/accounts/familiar_followers | pending |  | Review against local BE/FE behavior, then update this row. |
| `88412daf1` | 2024-04-25 | Haelwenn | Apply @lanodan's suggestion | pending |  | Review against local BE/FE behavior, then update this row. |
| `e8cd6662e` | 2024-05-19 | lain | Merge branch 'familiar-followers' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9423052e9` | 2022-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add "status" notification type | implemented | `lib/pleroma/notification.ex`, `lib/pleroma/web/mastodon_api/views/notification_view.ex`, `priv/repo/migrations/20220319000000_add_status_to_notifications_enum.exs` | Subscribed-user status notifications are present locally. |
| `3ed39e310` | 2022-07-08 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add test | not-applicable | `test/pleroma/web/mastodon_api/controllers/report_controller_test.exs` | Upstream test-only commit for already-present report rule behavior. |
| `92592c25c` | 2023-02-19 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'pleroma/develop' into status-notification-type | pending |  | Review against local BE/FE behavior, then update this row. |
| `78d1105bf` | 2023-02-19 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix down migration | pending |  | Review against local BE/FE behavior, then update this row. |
| `9363ef53a` | 2023-05-14 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add test for 'status' notification type for NotificationView | pending |  | Review against local BE/FE behavior, then update this row. |
| `226e53fdd` | 2024-01-31 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into status-notification-type | pending |  | Review against local BE/FE behavior, then update this row. |
| `1ed8ae2d8` | 2024-01-31 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `2e76ceb5b` | 2024-05-18 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into status-notification-type | pending |  | Review against local BE/FE behavior, then update this row. |
| `36fa0debf` | 2024-05-20 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix `get_notified_from` | pending |  | Review against local BE/FE behavior, then update this row. |
| `7fca59826` | 2024-05-21 | lain | Merge branch 'status-notification-type' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d1b053f3b` | 2024-05-22 | Lain Soykaf | Webfinger: Add test showing wrong webfinger behavior | pending |  | Review against local BE/FE behavior, then update this row. |
| `b15f8b064` | 2024-05-22 | Alex Gleason | Prevent webfinger spoofing | pending |  | Review against local BE/FE behavior, then update this row. |
| `206ea9283` | 2024-05-22 | Lain Soykaf | Webfinger: Fix test | pending |  | Review against local BE/FE behavior, then update this row. |
| `4491e8c9a` | 2024-05-22 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `91c93ce3c` | 2024-05-22 | Lain Soykaf | Changelog: Adjust changelog type | pending |  | Review against local BE/FE behavior, then update this row. |
| `84bb85405` | 2024-05-22 | Lain Soykaf | Webfinger: Allow managing account for subdomain | pending |  | Review against local BE/FE behavior, then update this row. |
| `c8e5a1f6b` | 2024-05-22 | lain | Merge branch 'fix-webfinger-spoofing' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1f2f7e044` | 2024-05-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Revert "Webfinger: Allow managing account for subdomain" | pending |  | Review against local BE/FE behavior, then update this row. |
| `d0b18e338` | 2024-05-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix validate_webfinger when running a different domain for Webfinger | pending |  | Review against local BE/FE behavior, then update this row. |
| `70cabbf6d` | 2024-05-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `d536d5808` | 2024-05-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f1f574f0` | 2024-05-22 | Lain Soykaf | WebFingerControllerTest: Restore host after test. | pending |  | Review against local BE/FE behavior, then update this row. |
| `a8e1fc0f6` | 2024-05-22 | lain | Merge branch 'webfinger-validation' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ac977bdb1` | 2024-02-20 | Haelwenn (lanodan) Monnier | StealEmojiPolicy: Sanitize shortcodes | pending |  | Review against local BE/FE behavior, then update this row. |
| `be075a433` | 2024-02-20 | Haelwenn (lanodan) Monnier | Security release 2.6.2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `fb4aa9f72` | 2024-02-20 | Haelwenn | Merge branch 'release/2.6.2' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `29b968ce2` | 2024-05-22 | Lain Soykaf | Webfinger: Add test showing wrong webfinger behavior | pending |  | Review against local BE/FE behavior, then update this row. |
| `364f6e162` | 2024-05-22 | Alex Gleason | Prevent webfinger spoofing | pending |  | Review against local BE/FE behavior, then update this row. |
| `eafcb7b4e` | 2024-05-22 | Lain Soykaf | Webfinger: Fix test | pending |  | Review against local BE/FE behavior, then update this row. |
| `275fdb26c` | 2024-05-22 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `2212287b0` | 2024-05-22 | Lain Soykaf | Changelog: Adjust changelog type | pending |  | Review against local BE/FE behavior, then update this row. |
| `20fa40008` | 2024-05-22 | Lain Soykaf | Webfinger: Allow managing account for subdomain | pending |  | Review against local BE/FE behavior, then update this row. |
| `239c9c3f1` | 2024-05-22 | Lain Soykaf | Mix: Update version | pending |  | Review against local BE/FE behavior, then update this row. |
| `7b4e6d4c1` | 2024-05-22 | Lain Soykaf | Collect changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `50ffbd980` | 2024-05-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Revert "Webfinger: Allow managing account for subdomain" | pending |  | Review against local BE/FE behavior, then update this row. |
| `b245a5c8c` | 2024-05-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix validate_webfinger when running a different domain for Webfinger | pending |  | Review against local BE/FE behavior, then update this row. |
| `45b5e6ecd` | 2024-05-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `c42527dc2` | 2024-05-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `53a3176d2` | 2024-05-22 | Lain Soykaf | WebFingerControllerTest: Restore host after test. | pending |  | Review against local BE/FE behavior, then update this row. |
| `7566b4a34` | 2024-05-22 | lain | Merge branch 'release-2.6.3' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3f0e9fd47` | 2024-05-22 | Lain Soykaf | Merge branch 'stable' into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `05b9805bf` | 2024-05-22 | lain | Merge branch 'mergeback-2.6.3' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7e3bbdded` | 2023-12-20 | Mark Felder | Elixir 1.13 is the minimum required version | pending |  | Review against local BE/FE behavior, then update this row. |
| `ddb9e90c4` | 2023-12-28 | Mark Felder | Update minimum elixir version found in various docs | pending |  | Review against local BE/FE behavior, then update this row. |
| `ad26b6d59` | 2024-05-20 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into bump-elixir | pending |  | Review against local BE/FE behavior, then update this row. |
| `226874c9d` | 2024-05-20 | Lain Soykaf | CI: Add new builders for base images | pending |  | Review against local BE/FE behavior, then update this row. |
| `f8411a351` | 2024-05-20 | Lain Soykaf | CI: Specify version fully in base image tag | pending |  | Review against local BE/FE behavior, then update this row. |
| `f5c029524` | 2024-05-20 | Lain Soykaf | CI: Specify correct image name. | pending |  | Review against local BE/FE behavior, then update this row. |
| `134f3bff6` | 2024-05-24 | lain | Merge branch 'bump-elixir' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `818712f99` | 2024-05-23 | Haelwenn (lanodan) Monnier | pleroma_ctl: Use realpath(1) instead of readlink(1) | pending |  | Review against local BE/FE behavior, then update this row. |
| `19b2637c5` | 2024-05-25 | tusooa | Merge branch 'bugfix/realpath-over-readlink' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `618b77071` | 2024-05-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update pleroma_api.md | pending |  | Review against local BE/FE behavior, then update this row. |
| `895eea5c7` | 2024-05-25 | lain | Merge branch 'api-docs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d4769b076` | 2024-05-26 | Mark Felder | Return a 422 when trying to reply to a deleted status | pending |  | Review against local BE/FE behavior, then update this row. |
| `354b700be` | 2024-05-26 | Mark Felder | Assert that AWS URLs without query parameters do not crash | pending |  | Review against local BE/FE behavior, then update this row. |
| `807782b7f` | 2024-05-26 | Mark Felder | Fix rich media parsing some Amazon URLs | pending |  | Review against local BE/FE behavior, then update this row. |
| `c3c804b71` | 2024-05-26 | feld | Merge branch 'fix/rich-media-ttl' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `61a3b7931` | 2024-05-25 | Mark Felder | Search backend healthcheck process | pending |  | Review against local BE/FE behavior, then update this row. |
| `3474b42ce` | 2024-05-25 | Mark Felder | Drop TTL to 5 seconds | pending |  | Review against local BE/FE behavior, then update this row. |
| `f2b0d5f1d` | 2024-05-26 | Mark Felder | Make it easier to read the state for debugging purposes and expose functions for testing | pending |  | Review against local BE/FE behavior, then update this row. |
| `03f4b4618` | 2024-05-26 | Mark Felder | Test that healthchecks behave correctly for the expected HTTP responses | pending |  | Review against local BE/FE behavior, then update this row. |
| `d9b82255b` | 2024-05-26 | Mark Felder | Add an HTTP timeout for the healthcheck | pending |  | Review against local BE/FE behavior, then update this row. |
| `d35b69d26` | 2024-05-27 | Lain Soykaf | Pleroma.Search: Remove wrong (but irrelevant) results | pending |  | Review against local BE/FE behavior, then update this row. |
| `5e4306012` | 2024-05-27 | lain | Merge branch 'search-healthcheck' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4d6316b48` | 2024-05-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into reject-replies-to-deleted | pending |  | Review against local BE/FE behavior, then update this row. |
| `f214c2cda` | 2024-05-27 | Lain Soykaf | NotificationTest: Remove impossible case. | pending |  | Review against local BE/FE behavior, then update this row. |
| `6757382ab` | 2024-05-27 | lain | Merge branch 'reject-replies-to-deleted' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `825b4122a` | 2024-05-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-ipfs_uploader | pending |  | Review against local BE/FE behavior, then update this row. |
| `3055c1598` | 2024-05-27 | Lain Soykaf | IPFSTest: Fix configuration mocking | pending |  | Review against local BE/FE behavior, then update this row. |
| `d11ba9e85` | 2024-05-27 | lain | Merge branch 'ipfs_uploader' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `718e8e1ed` | 2021-06-16 | Alex Gleason | Create NsfwApiPolicy | implemented | `lib/pleroma/web/activity_pub/mrf/nsfw_api_policy.ex`, `config/config.exs` | Optional NSFW API MRF policy is present locally. |
| `f15d41906` | 2021-06-16 | Alex Gleason | NsfwApiPolicy: raise if can't fetch user | implemented | `lib/pleroma/web/activity_pub/mrf/nsfw_api_policy.ex` | Local unlist path fails closed when the actor cannot be resolved. |
| `2b3dfbb42` | 2021-06-17 | Alex Gleason | NsfwApiPolicy: add tests | implemented | `lib/pleroma/web/activity_pub/mrf/nsfw_api_policy.ex` | Runtime behavior is present; local test layout has diverged from this old topic branch. |
| `b293c14a1` | 2021-06-17 | Alex Gleason | NsfwApiPolicy: add describe/0 and config_description/0 | implemented | `lib/pleroma/web/activity_pub/mrf/nsfw_api_policy.ex` | Policy exposes describe/config metadata locally. |
| `c802c3055` | 2021-06-17 | Alex Gleason | NsfwApiPolicy: add systemd example file | not-applicable | `lib/pleroma/web/activity_pub/mrf/nsfw_api_policy.ex` | Upstream service-file sample is documentation-only; local module documentation keeps the container setup guidance. |
| `a704d5499` | 2021-06-17 | Alex Gleason | NsfwApiPolicy: Fall back more generously when functions don't match | implemented | `lib/pleroma/web/activity_pub/mrf/nsfw_api_policy.ex` | Local policy treats unsupported attachment/object shapes as safe instead of crashing. |
| `3a03d9b65` | 2021-06-17 | Alex Gleason | Merge remote-tracking branch 'pleroma/develop' into nsfw-api-mrf | not-applicable |  | Topic-branch merge bookkeeping; no standalone runtime change to backport. |
| `4325b1aec` | 2024-05-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into nsfw-api-mrf | pending |  | Review against local BE/FE behavior, then update this row. |
| `ed93af64e` | 2024-05-27 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `e93ae96e1` | 2024-05-27 | lain | Merge branch 'nsfw-api-mrf' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b6a9d87f1` | 2023-10-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Display reposted replies with exclude_replies: true | pending |  | Review against local BE/FE behavior, then update this row. |
| `7798fdc71` | 2024-05-27 | lain | Merge branch 'show-reposted-replies' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f4693dc67` | 2024-05-27 | Mark Felder | Update Prometheus/Grafana docs for PromEx | pending |  | Review against local BE/FE behavior, then update this row. |
| `7258ab1ae` | 2024-05-27 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `6291bf22b` | 2024-05-27 | feld | Merge branch 'prometheus-docs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0bddca361` | 2024-05-27 | Mark Felder | DNSRBL in an MRF | implemented | `lib/pleroma/web/activity_pub/mrf/dnsrbl_policy.ex`, `config/config.exs` | Backported as a disabled-by-default MRF policy with safer fail-open DNS config handling. |
| `10713fa91` | 2024-05-27 | feld | Merge branch 'feat/mrf-dnsrbl' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `5e963736c` | 2024-05-27 | Alex Gleason | Add AntiMentionSpamPolicy | pending |  | Review against local BE/FE behavior, then update this row. |
| `64cacc369` | 2024-05-27 | Alex Gleason | AntiMentionSpamPolicy: fix user age check | pending |  | Review against local BE/FE behavior, then update this row. |
| `02d8ce8f0` | 2024-05-27 | Alex Gleason | AntiMentionSpamPolicy: remove followers check | pending |  | Review against local BE/FE behavior, then update this row. |
| `0d092a3d4` | 2024-05-27 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `cab6372d7` | 2024-05-27 | Mark Felder | Make user age limit configurable | pending |  | Review against local BE/FE behavior, then update this row. |
| `10b7efa98` | 2024-05-27 | feld | Merge branch 'anti-mention-spam-mrf' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2ae1b802f` | 2023-03-09 | Haelwenn (lanodan) Monnier | AttachmentValidator: Add support for Honk "summary" + "name" | pending |  | Review against local BE/FE behavior, then update this row. |
| `197647a04` | 2023-03-09 | Haelwenn (lanodan) Monnier | MastoAPI Attachment: Use "summary" for descriptions if present | pending |  | Review against local BE/FE behavior, then update this row. |
| `f4c0a01f0` | 2024-05-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into image-description-summary | pending |  | Review against local BE/FE behavior, then update this row. |
| `284cd0abe` | 2024-05-27 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `07b7a8d69` | 2024-05-27 | lain | Merge branch 'image-description-summary' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1ab4ab8d3` | 2023-07-18 | tusooa | Extract translatable strings | pending |  | Review against local BE/FE behavior, then update this row. |
| `03d0c5abf` | 2024-05-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into tusooa/extract-fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1fec8594` | 2024-05-27 | lain | Merge branch 'tusooa/extract-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7dfd148ff` | 2024-03-19 | Mark Felder | Logger metadata for inbound federation requests | pending |  | Review against local BE/FE behavior, then update this row. |
| `40823462e` | 2024-03-19 | Mark Felder | Logger metadata for request path and authenticated user | pending |  | Review against local BE/FE behavior, then update this row. |
| `99cee755d` | 2024-03-19 | Mark Felder | Show Logger metadata in dev | pending |  | Review against local BE/FE behavior, then update this row. |
| `462d5aa5c` | 2024-03-19 | Mark Felder | logger: remove request_id metadata which is not useful | pending |  | Review against local BE/FE behavior, then update this row. |
| `29eac86dc` | 2024-05-27 | Mark Felder | Logger metadata changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `42150d558` | 2024-05-27 | feld | Merge branch 'logger-metadata' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `cd7e2138d` | 2024-05-14 | Lain Soykaf | Search: Basic Qdrant/Ollama search | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb08a766f` | 2024-05-14 | Lain Soykaf | QdrantSearch: Remove debugging stuff | pending |  | Review against local BE/FE behavior, then update this row. |
| `1490ff30a` | 2024-05-14 | Lain Soykaf | QdrantSearch: Add query prefix. | pending |  | Review against local BE/FE behavior, then update this row. |
| `c50f0f31f` | 2024-05-14 | Lain Soykaf | Docs/Search: Add basic documentation of the qdrant search | pending |  | Review against local BE/FE behavior, then update this row. |
| `1261c43a7` | 2024-05-14 | Lain Soykaf | SearchBackend: Add create_index | pending |  | Review against local BE/FE behavior, then update this row. |
| `a9be4907c` | 2024-05-16 | Lain Soykaf | SearchBackend: Add drop_index | pending |  | Review against local BE/FE behavior, then update this row. |
| `069ce4448` | 2024-05-18 | Lain Soykaf | Add basic fastembed server | pending |  | Review against local BE/FE behavior, then update this row. |
| `769773a50` | 2024-05-18 | Lain Soykaf | Add dockerfile | pending |  | Review against local BE/FE behavior, then update this row. |
| `61e902713` | 2024-05-18 | Lain Soykaf | Add docker compose file for fastembed server | pending |  | Review against local BE/FE behavior, then update this row. |
| `933117785` | 2024-05-18 | Lain Soykaf | QdrantSearch: Add basic test | pending |  | Review against local BE/FE behavior, then update this row. |
| `e3933a067` | 2024-05-18 | Lain Soykaf | QdrantSearch: Implement post deletion | pending |  | Review against local BE/FE behavior, then update this row. |
| `39525bcec` | 2024-05-18 | Lain Soykaf | Add qdrant changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `7923ede8b` | 2024-05-18 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into qdrant-search-2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `3345ddd2d` | 2024-05-18 | Lain Soykaf | Linting | pending |  | Review against local BE/FE behavior, then update this row. |
| `cc1321ea2` | 2024-05-19 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into qdrant-search-2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `72ec261a6` | 2024-05-19 | Lain Soykaf | B QdrantSearch: Switch to OpenAI api | pending |  | Review against local BE/FE behavior, then update this row. |
| `b9af017a4` | 2024-05-19 | Lain Soykaf | B FastembedServer: Switch to OpenAI api, support changing models | pending |  | Review against local BE/FE behavior, then update this row. |
| `c139a9f38` | 2024-05-19 | Lain Soykaf | B Config: Set default Qdrant embedder to our fastembed-api server | pending |  | Review against local BE/FE behavior, then update this row. |
| `e142ea400` | 2024-05-19 | Lain Soykaf | Docs: Switch docs from Ollama to OpenAI. | pending |  | Review against local BE/FE behavior, then update this row. |
| `dd4881018` | 2024-05-19 | Lain Soykaf | B FastembedAPI: Move to more appropriate folder | pending |  | Review against local BE/FE behavior, then update this row. |
| `8329ad521` | 2024-05-19 | Lain Soykaf | B FastembedAPI: Add requirements.txt | pending |  | Review against local BE/FE behavior, then update this row. |
| `23881842a` | 2024-05-19 | Lain Soykaf | B FastembedAPI: Add readme | pending |  | Review against local BE/FE behavior, then update this row. |
| `6a3a0cc0f` | 2024-05-19 | Lain Soykaf | Docs: Write docs for the QdrantSearch | pending |  | Review against local BE/FE behavior, then update this row. |
| `6ec306d06` | 2024-05-19 | Lain Soykaf | Docs: Add more information about index memory consumption. | pending |  | Review against local BE/FE behavior, then update this row. |
| `dbaab6f54` | 2024-05-19 | Lain Soykaf | Docs: Mention running the Qdrant server | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b4f1db9b` | 2024-05-19 | Lain Soykaf | QdrantSearch: Support pagination. | pending |  | Review against local BE/FE behavior, then update this row. |
| `f726e5fbb` | 2024-05-22 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into qdrant-search-2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `94e4f2158` | 2024-05-23 | Lain Soykaf | QdrantSearch: Deal with actor restrictions | pending |  | Review against local BE/FE behavior, then update this row. |
| `a566ad56e` | 2024-05-23 | Lain Soykaf | QdrantSearch: Fix actor / author restriction | pending |  | Review against local BE/FE behavior, then update this row. |
| `08e9d995f` | 2024-05-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into qdrant-search-2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `8b76f5605` | 2024-05-27 | Lain Soykaf | QdrantSearch: Add healthcheck for qdrant | pending |  | Review against local BE/FE behavior, then update this row. |
| `ec3f3fef7` | 2024-05-27 | Lain Soykaf | Fastembed Server: Add health check endpoint | pending |  | Review against local BE/FE behavior, then update this row. |
| `f4c04e6b2` | 2024-05-27 | Lain Soykaf | QdrantSearch: Add health checks. | pending |  | Review against local BE/FE behavior, then update this row. |
| `ddf103eca` | 2024-05-27 | Lain Soykaf | QdrantSearch: Fetch a post in search if possible. | pending |  | Review against local BE/FE behavior, then update this row. |
| `3316a7ab7` | 2024-05-27 | lain | Merge branch 'qdrant-search-2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1c699144d` | 2024-05-27 | Lain Soykaf | HttpSecurityPlug: Don't allow unsafe-eval by default | pending |  | Review against local BE/FE behavior, then update this row. |
| `fc7ce339e` | 2024-05-27 | Lain Soykaf | Cheatsheet: Add allow_unsafe_eval | pending |  | Review against local BE/FE behavior, then update this row. |
| `c67b41415` | 2024-05-27 | Lain Soykaf | Changelog: Add changelog entry. | pending |  | Review against local BE/FE behavior, then update this row. |
| `81e44ced0` | 2024-05-27 | Lain Soykaf | HTTPSecurityPlug: Fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `121791882` | 2024-05-27 | lain | Merge branch 'explicitly-allow-unsafe-2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0847d9eba` | 2024-05-27 | Mark Felder | Oban queue simplification | pending |  | Review against local BE/FE behavior, then update this row. |
| `f63e44b8b` | 2024-05-27 | Mark Felder | Fix Oban related tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `38db406ce` | 2024-05-27 | feld | Merge branch 'simpler-oban-queues' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb86a01b9` | 2024-05-27 | Mark Felder | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `cdde3afb5` | 2024-05-27 | feld | Merge branch 'credo' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a50c65742` | 2024-05-27 | Mark Felder | Add a dedicated connection pool for Rich Media | pending |  | Review against local BE/FE behavior, then update this row. |
| `6708f154a` | 2024-05-27 | Mark Felder | Rework Gun connection pool sizes to make better use of the default 250 connections | pending |  | Review against local BE/FE behavior, then update this row. |
| `d272eb62c` | 2024-05-27 | Mark Felder | Trust the connection pools to enforce the concurrency limitations | pending |  | Review against local BE/FE behavior, then update this row. |
| `37d79b76b` | 2024-05-27 | Mark Felder | Use the configured http client options for mediaproxy | pending |  | Review against local BE/FE behavior, then update this row. |
| `8b61d4e3e` | 2024-05-27 | Mark Felder | Changelogs | pending |  | Review against local BE/FE behavior, then update this row. |
| `6b8c15a4a` | 2024-05-27 | Mark Felder | Remove MediaProxyWarmingPolicy config for ConcurrentLimiter as we are not using it | pending |  | Review against local BE/FE behavior, then update this row. |
| `ba511a30b` | 2024-05-27 | Mark Felder | RichMedia use of ConcurrentLimiter was removed in the refactor | pending |  | Review against local BE/FE behavior, then update this row. |
| `8ff0c3290` | 2024-05-28 | lain | Merge branch 'httpfixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f271ea6e4` | 2023-12-16 | Haelwenn (lanodan) Monnier | Move Plugs.RemoteIP.maybe_add_cidr/1 to InetHelper.parse_cidr/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `086ba59d0` | 2023-12-16 | Haelwenn (lanodan) Monnier | HTTPSignaturePlug: Add :authorized_fetch_mode_exceptions | pending |  | Review against local BE/FE behavior, then update this row. |
| `c67506ba6` | 2024-05-20 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into auth-fetch-exception | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3e85da0f` | 2024-05-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into auth-fetch-exception | pending |  | Review against local BE/FE behavior, then update this row. |
| `e4f1325f7` | 2024-05-27 | Lain Soykaf | InetHelper: Don't use deprecated function. | pending |  | Review against local BE/FE behavior, then update this row. |
| `687ac4a85` | 2024-05-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into auth-fetch-exception | pending |  | Review against local BE/FE behavior, then update this row. |
| `73d58c22d` | 2024-05-28 | Lain Soykaf | Linting | pending |  | Review against local BE/FE behavior, then update this row. |
| `25903a499` | 2024-05-28 | lain | Merge branch 'auth-fetch-exception' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3b4be5daa` | 2024-05-28 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-secure-mode | pending |  | Review against local BE/FE behavior, then update this row. |
| `f5978da67` | 2024-05-28 | Lain Soykaf | HTTPSignaturePlugTest: Rewrite to use mox. | pending |  | Review against local BE/FE behavior, then update this row. |
| `8066645f7` | 2024-05-28 | Lain Soykaf | Linting | pending |  | Review against local BE/FE behavior, then update this row. |
| `335691bae` | 2024-05-28 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `bef15cde6` | 2024-05-28 | lain | Merge branch 'secure-mode' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `cc42b50c5` | 2024-05-28 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-feature/akkoma-prune-old-posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `a041879ea` | 2024-05-28 | Lain Soykaf | Linting | pending |  | Review against local BE/FE behavior, then update this row. |
| `f66313572` | 2024-05-28 | Lain Soykaf | DatabaseTest: Fix test. | pending |  | Review against local BE/FE behavior, then update this row. |
| `41d3c14ba` | 2024-05-28 | lain | Merge branch 'feature/akkoma-prune-old-posts' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0b864c369` | 2024-05-28 | Mark Felder | Dialyzer: fix invalid @spec | pending |  | Review against local BE/FE behavior, then update this row. |
| `42c5f7c74` | 2024-05-28 | Mark Felder | Dialyzer: fix invalid @spec | pending |  | Review against local BE/FE behavior, then update this row. |
| `f8ce639e3` | 2024-05-28 | Mark Felder | Dialyzer: guard clause can never succeed | pending |  | Review against local BE/FE behavior, then update this row. |
| `18835bf70` | 2024-05-28 | Mark Felder | Use the configured http client options for mediaproxy | pending |  | Review against local BE/FE behavior, then update this row. |
| `17ebb2df8` | 2024-05-28 | Mark Felder | Dialyzer: fix pattern matches preventing video thumbnailing from working | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b3c84e24` | 2024-05-28 | Mark Felder | Dialyzer: no_local_return | pending |  | Review against local BE/FE behavior, then update this row. |
| `8743c6c64` | 2024-05-28 | Mark Felder | Dialyzer: The pattern can never match the type | pending |  | Review against local BE/FE behavior, then update this row. |
| `6551ca2db` | 2024-05-28 | Mark Felder | Dialyzer: overlapping_contract | pending |  | Review against local BE/FE behavior, then update this row. |
| `6b6a2adb0` | 2024-05-28 | Mark Felder | Dialyzer: The function call will not succeed. | pending |  | Review against local BE/FE behavior, then update this row. |
| `79c418bcb` | 2024-05-28 | Mark Felder | Dialyzer: fix invalid @spec | pending |  | Review against local BE/FE behavior, then update this row. |
| `3b639b467` | 2024-05-28 | feld | Merge branch 'dialyzer-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `14b4bd69a` | 2024-05-29 | Mark Felder | Add additional flags to the Pleroma.Search.Indexer Mix task | pending |  | Review against local BE/FE behavior, then update this row. |
| `b4332b47d` | 2024-05-29 | feld | Merge branch 'mix-indexer' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `36b440d9b` | 2024-05-29 | Mark Felder | Update Bandit to 1.5.2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `bc4d6adbe` | 2024-05-30 | lain | Merge branch 'bandit-update' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b5fcb82bf` | 2024-05-30 | Mark Felder | Test for missing FK indexes | pending |  | Review against local BE/FE behavior, then update this row. |
| `c20ac6d1a` | 2024-05-30 | Mark Felder | Add missing foreign key indexes | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f6e477ec` | 2024-05-30 | Mark Felder | Missing FKs changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `6feb536e7` | 2024-05-30 | lain | Merge branch 'missing-fks' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f5065eaf9` | 2024-05-30 | Mark Felder | Fix Logger.warn deprecation error on OTP25 | pending |  | Review against local BE/FE behavior, then update this row. |
| `ff6f5a417` | 2024-05-30 | feld | Merge branch 'mrf-nsfw-otp25' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `030243188` | 2024-05-31 | Floatingghost | Use proper workers for fetching pins instead of an ad-hoc task | pending |  | Review against local BE/FE behavior, then update this row. |
| `cdeeb4dcc` | 2024-06-01 | lain | Merge branch '3276-pinned-collection-fetch' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `cfc8d7aad` | 2024-05-30 | Mark Felder | IPFS uploader: dialyzer fixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `acde8d0e0` | 2024-06-01 | lain | Merge branch 'ipfs-dialyzer-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `858d528cc` | 2024-06-04 | Mark Felder | Allow Cowboy to stream the response instead of chunk it | pending |  | Review against local BE/FE behavior, then update this row. |
| `bf8b251dc` | 2024-06-05 | feld | Merge branch 'cowboy-streaming' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c16ef40f1` | 2024-05-29 | Haelwenn (lanodan) Monnier | RichMedia: Respect configuration on status previews | pending |  | Review against local BE/FE behavior, then update this row. |
| `65c876390` | 2024-05-29 | Haelwenn (lanodan) Monnier | RichMedia: Add extra checks on configuration | pending |  | Review against local BE/FE behavior, then update this row. |
| `49156f018` | 2024-06-07 | Mark Felder | Fixes for default disabled rich media in test environment | pending |  | Review against local BE/FE behavior, then update this row. |
| `f44987bd0` | 2024-06-07 | feld | Merge branch 'bugfix/rich_media_config' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `591506287` | 2024-06-07 | Mark Felder | Add missing notification types to the api spec | pending |  | Review against local BE/FE behavior, then update this row. |
| `b52d772a6` | 2024-06-07 | Mark Felder | Add some useful logging for ApiSpec errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `a4bd89c77` | 2024-06-07 | feld | Merge branch 'spex/notification-types' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6ded017de` | 2024-06-07 | Mark Felder | Do not start unused ConcurrentLimiter processes | pending |  | Review against local BE/FE behavior, then update this row. |
| `5ed07aba7` | 2024-06-07 | Mark Felder | Add missing pool to the type | pending |  | Review against local BE/FE behavior, then update this row. |
| `d98b1c275` | 2024-06-07 | Mark Felder | Small cleanup / fixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `b23b007d0` | 2024-06-07 | feld | Merge branch 'feld/cleanup' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `dbf29cbae` | 2024-06-08 | Pleroma User | Bump deps | pending |  | Review against local BE/FE behavior, then update this row. |
| `c24e22288` | 2024-06-08 | feld | Merge branch 'bump-deps' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a5424c368` | 2024-06-08 | Mark Felder | Test that end of poll notifications are streamed over websockets | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1c52c306` | 2024-06-08 | Mark Felder | Rename Notification.send/1 to Notification.stream/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `471412ad3` | 2024-06-08 | Mark Felder | Stream end of poll notification over websockets and web push | pending |  | Review against local BE/FE behavior, then update this row. |
| `9d6782761` | 2024-06-08 | feld | Merge branch 'stream-poll-end' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `84319dbca` | 2024-06-08 | Mark Felder | OTP updates | pending |  | Review against local BE/FE behavior, then update this row. |
| `0641a1058` | 2024-06-08 | Mark Felder | Update job names | pending |  | Review against local BE/FE behavior, then update this row. |
| `de80a7e89` | 2024-06-09 | lain | Merge branch 'otp-bumps' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `5313255b1` | 2024-06-11 | Mark Felder | Use conn.request_path for more legible error log | pending |  | Review against local BE/FE behavior, then update this row. |
| `61506f8d9` | 2024-06-11 | feld | Merge branch 'api-spex-error' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `07cb89823` | 2024-06-08 | Mark Felder | More robust validation the vapid config is set | pending |  | Review against local BE/FE behavior, then update this row. |
| `db88bf30d` | 2024-06-08 | Mark Felder | Add spec for send/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `86fa0889b` | 2024-06-08 | Mark Felder | Remove unnecessary mastodon_type hack | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1ef6e5e9` | 2024-06-08 | Mark Felder | Cleanup to make the code easier to follow | pending |  | Review against local BE/FE behavior, then update this row. |
| `3211557f7` | 2024-06-08 | Mark Felder | Render nice web push notifications for polls | pending |  | Review against local BE/FE behavior, then update this row. |
| `dcc50da40` | 2024-06-08 | Mark Felder | Stream the notifications as part of the job | pending |  | Review against local BE/FE behavior, then update this row. |
| `c1b84edef` | 2024-06-08 | Mark Felder | Increase web push character limit for the body | pending |  | Review against local BE/FE behavior, then update this row. |
| `8468d7888` | 2024-06-08 | Mark Felder | Increase web push character limit for the body | pending |  | Review against local BE/FE behavior, then update this row. |
| `f000dab37` | 2024-06-08 | Mark Felder | Switch test case to Impl.build_content/3 | pending |  | Review against local BE/FE behavior, then update this row. |
| `51eeb8082` | 2024-06-09 | Mark Felder | Merge remote-tracking branch 'origin/develop' into webpush-polls | pending |  | Review against local BE/FE behavior, then update this row. |
| `2fd155fb9` | 2024-06-11 | Mark Felder | Add PollWorker test; move the streaming notification test to it | pending |  | Review against local BE/FE behavior, then update this row. |
| `f47a12469` | 2024-06-11 | feld | Merge branch 'webpush-polls' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `cb91dab75` | 2024-06-12 | Haelwenn (lanodan) Monnier | Switch formatting checks to Elixir 1.15 | pending |  | Review against local BE/FE behavior, then update this row. |
| `8757c5e35` | 2024-06-12 | Haelwenn (lanodan) Monnier | Logger.warn ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ Logger.warning | pending |  | Review against local BE/FE behavior, then update this row. |
| `3e7f05d0b` | 2024-06-12 | Haelwenn (lanodan) Monnier | Add changelog entry (elixir-1.15) | pending |  | Review against local BE/FE behavior, then update this row. |
| `66ac2e9b8` | 2024-06-12 | Haelwenn (lanodan) Monnier | Upload.base_url: Don't pass nil to Path.join(), don't return nil | pending |  | Review against local BE/FE behavior, then update this row. |
| `2180537a2` | 2024-06-12 | Haelwenn (lanodan) Monnier | MediaProxy: :whitelist config fallback to [] | pending |  | Review against local BE/FE behavior, then update this row. |
| `3d0d2a451` | 2024-06-12 | Haelwenn (lanodan) Monnier | media_controller_test: Make sure uploader is the Local one | pending |  | Review against local BE/FE behavior, then update this row. |
| `ba6afdb44` | 2024-06-12 | Haelwenn (lanodan) Monnier | mix: Turn off prune_code_path | pending |  | Review against local BE/FE behavior, then update this row. |
| `c389ea0f4` | 2024-06-12 | Haelwenn (lanodan) Monnier | Fix compatibility with Loggers in Elixir 1.15+ | pending |  | Review against local BE/FE behavior, then update this row. |
| `cf9a058fa` | 2024-06-12 | Haelwenn (lanodan) Monnier | CI: Disallow failures for Elixir 1.15 | pending |  | Review against local BE/FE behavior, then update this row. |
| `6774ff15d` | 2024-06-12 | Haelwenn (lanodan) Monnier | docs: Bump elixir requirement up to 1.16 | pending |  | Review against local BE/FE behavior, then update this row. |
| `41434ffce` | 2024-06-12 | Lain Soykaf | Tests: Don't spawn processes in tests. | pending |  | Review against local BE/FE behavior, then update this row. |
| `a734efeff` | 2024-06-12 | Mark Felder | Formatting | pending |  | Review against local BE/FE behavior, then update this row. |
| `cbf8f8ac0` | 2024-06-13 | Mark Felder | Fix mix pleroma.config dump on Elixir 1.15 | pending |  | Review against local BE/FE behavior, then update this row. |
| `3aed111a4` | 2024-06-18 | Mark Felder | Enable capture_log globally | pending |  | Review against local BE/FE behavior, then update this row. |
| `e628d00a8` | 2024-06-18 | Mark Felder | Disable Ecto logging in tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `568819c08` | 2024-06-11 | Mark Felder | WebPush refactoring: separate build and deliver steps | pending |  | Review against local BE/FE behavior, then update this row. |
| `603a57576` | 2024-06-11 | Mark Felder | The user is not always preloaded into the notification | pending |  | Review against local BE/FE behavior, then update this row. |
| `a291a6b8c` | 2024-06-11 | Mark Felder | Ensure the webpush notification for e.g., mentions start with the nickname of the actor it originates from | pending |  | Review against local BE/FE behavior, then update this row. |
| `6a9d9da26` | 2024-06-11 | Mark Felder | Cyclical complexity | pending |  | Review against local BE/FE behavior, then update this row. |
| `5c8afbe64` | 2024-06-11 | Mark Felder | Fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `4a28b81b5` | 2024-06-11 | feld | Merge branch 'fix-webpush-actor' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1ae5c2b02` | 2024-06-12 | Lain Soykaf | Transmogrifier: Encode Emoji id to be valid. | pending |  | Review against local BE/FE behavior, then update this row. |
| `38e6166d9` | 2024-06-12 | lain | Merge branch '3280-emoji' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e37845cd3` | 2024-06-16 | Mark Felder | Stale user refreshing should be done async to prevent blocking of rendering activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `825541b27` | 2024-06-17 | lain | Merge branch 'async-user-refresh' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9c6763725` | 2024-06-17 | Mark Felder | Refactor the async user refreshing to use Oban | pending |  | Review against local BE/FE behavior, then update this row. |
| `3c1db78a6` | 2024-06-18 | feld | Merge branch 'oban/user-refresh' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e43e09a04` | 2024-06-18 | Mark Felder | Merge remote-tracking branch 'origin/develop' into bugfix/elixir-1.15 | pending |  | Review against local BE/FE behavior, then update this row. |
| `c11c35cf8` | 2024-06-18 | Mark Felder | Enable :logger_backends application on < Elixir 1.15 | pending |  | Review against local BE/FE behavior, then update this row. |
| `febf9d268` | 2024-06-19 | Mark Felder | Remove Logger from ConfigDB | pending |  | Review against local BE/FE behavior, then update this row. |
| `85b81cc93` | 2024-06-19 | Mark Felder | Remove Logger from ConfigDB descriptions | pending |  | Review against local BE/FE behavior, then update this row. |
| `e0afb2c09` | 2024-06-19 | Mark Felder | Elixir Logger configuration is now longer permitted through AdminFE and ConfigDB | pending |  | Review against local BE/FE behavior, then update this row. |
| `3a8420b14` | 2024-06-19 | Mark Felder | Remove remaining vestiges of Logger support in ConfigDB/TransferTask | pending |  | Review against local BE/FE behavior, then update this row. |
| `ed2976b23` | 2024-06-19 | Mark Felder | Custom mix task to retry failed tests once in CI pipeline | pending |  | Review against local BE/FE behavior, then update this row. |
| `9a4cdde5c` | 2024-06-20 | feld | Merge branch 'bugfix/elixir-1.15' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e1e099d3b` | 2024-06-19 | Mark Felder | Set console logs to :info for Elixir 1.15+ | pending |  | Review against local BE/FE behavior, then update this row. |
| `4dfa50f25` | 2024-06-19 | Mark Felder | Rename RichMediaExpirationWorker to RichMediaWorker | pending |  | Review against local BE/FE behavior, then update this row. |
| `17d04ccc8` | 2024-06-19 | Mark Felder | RichMedia backfill processing through Oban | pending |  | Review against local BE/FE behavior, then update this row. |
| `d4563f67e` | 2024-06-20 | feld | Merge branch 'oban/rich-media-backfill' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f00a681cc` | 2024-06-20 | Mark Felder | Change CI caching strategy | pending |  | Review against local BE/FE behavior, then update this row. |
| `4a881ba36` | 2024-06-20 | feld | Merge branch 'ci/cache' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `655ac9847` | 2024-06-20 | Mark Felder | Merge remote-tracking branch 'origin/develop' into fix/debug-logs | pending |  | Review against local BE/FE behavior, then update this row. |
| `1071632a5` | 2024-06-20 | feld | Merge branch 'fix/debug-logs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c765fcbe7` | 2024-06-20 | Mark Felder | Gun Connection Pool: successfully retry after reclaiming the pool | pending |  | Review against local BE/FE behavior, then update this row. |
| `9ef021e2d` | 2024-06-20 | Mark Felder | Switch the reclaimer to GenServer.start so it is not linked | pending |  | Review against local BE/FE behavior, then update this row. |
| `fee1e17d8` | 2024-06-20 | feld | Merge branch 'erratic/gun' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7d5065819` | 2024-06-20 | Mark Felder | Enable erratic tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `73916dbea` | 2024-06-20 | feld | Merge branch 'enable-erratic' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `af53efa9e` | 2024-06-20 | pleromian | docs: update docs for NetBSD | pending |  | Review against local BE/FE behavior, then update this row. |
| `b33b1b725` | 2024-06-20 | pleromian | docs: update nginx and rcscript path for NetBSD | pending |  | Review against local BE/FE behavior, then update this row. |
| `93eb458c2` | 2024-06-21 | feld | Merge branch 'netbsd-wip' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `634e3d415` | 2024-06-23 | Mark Felder | Add test validating the activity_id is correctly present in the Oban job | pending |  | Review against local BE/FE behavior, then update this row. |
| `a9bea02fe` | 2024-06-24 | feld | Merge branch 'oban/richmedia-stream' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b135fa35a` | 2024-06-24 | Mark Felder | RichMedia: test that activity is streamed out | pending |  | Review against local BE/FE behavior, then update this row. |
| `9953b0da5` | 2024-06-24 | feld | Merge branch 'oban/richmedia-stream' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f0334dce3` | 2024-06-27 | Mark Felder | Add 1.16.3 ci image | pending |  | Review against local BE/FE behavior, then update this row. |
| `6e932495d` | 2024-06-27 | Mark Felder | Change CI jobs to Elixir 1.16.3 | pending |  | Review against local BE/FE behavior, then update this row. |
| `01ed270db` | 2024-06-27 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `394cb1e0f` | 2024-06-28 | feld | Merge branch 'ci/elixir-1.16' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9e5adf31c` | 2024-06-28 | Mark Felder | Change Gun connection pool logs to debug | pending |  | Review against local BE/FE behavior, then update this row. |
| `01fb4776f` | 2024-06-28 | feld | Merge branch 'gun-pool-logs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `51a36bc9b` | 2024-06-28 | Mark Felder | Oban Jobs for refreshing users were not respecting the uniqueness setting | pending |  | Review against local BE/FE behavior, then update this row. |
| `801a9367d` | 2024-06-28 | feld | Merge branch 'fix/oban-user-refresh-unique' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ba88c5078` | 2024-06-28 | Lain Soykaf | StripLocationTest: Add failing test for PNGs | pending |  | Review against local BE/FE behavior, then update this row. |
| `6d4fb5320` | 2024-06-28 | Lain Soykaf | StripLocation: Remove all PNG extra info to make sure that GPS data is gone. | pending |  | Review against local BE/FE behavior, then update this row. |
| `abbc5b6e4` | 2024-06-30 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `ccbbee796` | 2024-06-30 | lain | Merge branch 'exif' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3cccce9f` | 2024-07-01 | Mark Felder | Elixir 1.17 warnings for parens | pending |  | Review against local BE/FE behavior, then update this row. |
| `6e1aa8aee` | 2024-07-01 | Mark Felder | Elixir 1.17 undefined module warning | pending |  | Review against local BE/FE behavior, then update this row. |
| `fb52099a1` | 2024-07-01 | Mark Felder | Elixir 1.17 single quote charlist warning | pending |  | Review against local BE/FE behavior, then update this row. |
| `436286c93` | 2024-07-01 | Mark Felder | Update Tesla to 1.11.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `71c8030e6` | 2024-07-01 | Mark Felder | Update Phoenix to 1.7.14 | pending |  | Review against local BE/FE behavior, then update this row. |
| `33fa035c3` | 2024-07-01 | Mark Felder | Update elixir-captcha to fix the compile warning | pending |  | Review against local BE/FE behavior, then update this row. |
| `69482004f` | 2024-07-01 | Mark Felder | Dialyzer: pattern can never match the type because it is covered by previous clauses. | pending |  | Review against local BE/FE behavior, then update this row. |
| `a008005bd` | 2024-07-01 | Mark Felder | Dialyzer: fix typespec | pending |  | Review against local BE/FE behavior, then update this row. |
| `fd62969dc` | 2024-07-01 | Mark Felder | Dialyzer: pattern can never match the type | pending |  | Review against local BE/FE behavior, then update this row. |
| `7955cd90e` | 2024-07-01 | Mark Felder | Dialyzer: The guard clause can never succeed. | pending |  | Review against local BE/FE behavior, then update this row. |
| `b283b686c` | 2024-07-01 | Mark Felder | Dialyzer: Function application with args (_ :: map()) will not succeed. | pending |  | Review against local BE/FE behavior, then update this row. |
| `940278943` | 2024-07-01 | Mark Felder | Dialyzer: fix typespec | pending |  | Review against local BE/FE behavior, then update this row. |
| `da05e2137` | 2024-07-01 | Mark Felder | Fix cycles job name | pending |  | Review against local BE/FE behavior, then update this row. |
| `62d9333eb` | 2024-07-01 | Mark Felder | CI: Switch to Elixir 1.17 | pending |  | Review against local BE/FE behavior, then update this row. |
| `e1981264a` | 2024-07-01 | feld | Merge branch 'warnings/elixir-1.17' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3127c5f0a` | 2024-07-01 | Mark Felder | Fix automatic LDAP account registration on OTP 24.3+ | pending |  | Review against local BE/FE behavior, then update this row. |
| `eb419b7ff` | 2024-07-01 | Mark Felder | Add eldap back to applications as the module functions were unavailable | pending |  | Review against local BE/FE behavior, then update this row. |
| `2fe1e96f2` | 2024-07-01 | Mark Felder | Fix LDAP support | pending |  | Review against local BE/FE behavior, then update this row. |
| `7a4687562` | 2024-07-01 | feld | Merge branch 'fix/ldap' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `35d64a8b6` | 2024-07-01 | Pleroma User | Added translation using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `ad10750ba` | 2024-07-01 | Pleroma User | Added translation using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `6c3df7929` | 2024-07-01 | Pleroma User | Added translation using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `740689294` | 2024-07-01 | Pleroma User | Translated using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `ee528296e` | 2024-07-01 | Pleroma User | Translated using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `245f92400` | 2024-07-01 | Pleroma User | Translated using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `4d07b82f3` | 2024-07-01 | Pleroma User | Translated using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `a8ad40dfd` | 2024-07-01 | Pleroma User | Translated using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `4b7be135f` | 2024-07-01 | Pleroma User | Translated using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `2967e5fa4` | 2024-07-01 | Pleroma User | Translated using Weblate (Ukrainian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `9e3633501` | 2024-07-03 | tusooa | Merge branch 'weblate' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `272aae157` | 2024-07-06 | Mark Felder | Refactor maybe_handle_group_posts/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `ef2ada59e` | 2024-07-06 | feld | Merge branch 'refactor/group-posts' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `03c3c58d7` | 2024-07-10 | Taylan Kammer | LDAP Authenticator: Improve error reporting. | pending |  | Review against local BE/FE behavior, then update this row. |
| `19eeea7c1` | 2024-07-12 | feld | Merge branch 'develop' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `47c6f3ddc` | 2024-06-21 | pleromian | poison is used only in tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `56927ffd2` | 2024-06-22 | pleromian | add changelog for poison | pending |  | Review against local BE/FE behavior, then update this row. |
| `e4ba5777e` | 2024-07-06 | Pleroma User | Merge branch 'develop' into 'move-poison' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2e7258caf` | 2024-07-12 | feld | Merge branch 'move-poison' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d790df73f` | 2024-07-12 | Mark Felder | Remove the unused ingestion queue | pending |  | Review against local BE/FE behavior, then update this row. |
| `680da772e` | 2024-07-12 | feld | Merge branch 'oban/remove-ingestion' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b051e68bb` | 2024-07-12 | Mark Felder | Discard Remote Fetcher jobs which errored due to an MRF rejection | pending |  | Review against local BE/FE behavior, then update this row. |
| `375471359` | 2024-07-12 | feld | Merge branch 'oban/fetcher-discard-rejected' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f52b229ba` | 2024-07-12 | Mark Felder | Oban: change :discard return values to :cancel | pending |  | Review against local BE/FE behavior, then update this row. |
| `0ea63d824` | 2024-07-12 | feld | Merge branch 'oban/deprecate-discards' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1e8d1904e` | 2024-07-15 | Mark Felder | Define missing Oban timeouts | pending |  | Review against local BE/FE behavior, then update this row. |
| `6278af209` | 2024-07-15 | Mark Felder | Bump Oban to 2.17.12 | pending |  | Review against local BE/FE behavior, then update this row. |
| `2e2caad28` | 2024-07-15 | Mark Felder | Fix Oban jobs exiting with :error instead of :cancel | pending |  | Review against local BE/FE behavior, then update this row. |
| `2f14990c5` | 2024-07-15 | Mark Felder | Change PurgeExpiredActivity to use the background queue | pending |  | Review against local BE/FE behavior, then update this row. |
| `52b6dd8bf` | 2024-07-15 | Mark Felder | Increase background job concurrency to 20 | pending |  | Review against local BE/FE behavior, then update this row. |
| `30defb167` | 2024-07-15 | Mark Felder | Create a DeleteWorker and change user and instance deletion jobs to use it | pending |  | Review against local BE/FE behavior, then update this row. |
| `80e16de3b` | 2024-07-15 | Mark Felder | Increase slow job queue parallelization | pending |  | Review against local BE/FE behavior, then update this row. |
| `cd535861e` | 2024-07-15 | feld | Merge branch 'oban/improvements' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c9203f125` | 2024-07-15 | Mark Felder | Added a Mix task "pleroma.config fix_mrf_policies" which will remove erroneous MRF policies from ConfigDB | pending |  | Review against local BE/FE behavior, then update this row. |
| `683c4f086` | 2024-07-15 | feld | Merge branch 'fix-mrfs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4cbb59c8f` | 2024-07-17 | Mark Felder | Add Oban Live Dashboard | pending |  | Review against local BE/FE behavior, then update this row. |
| `b4c5cc39f` | 2024-07-17 | feld | Merge branch 'oban/live_dashboard' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d124d8645` | 2024-07-17 | Mark Felder | Rework some Rich Media functionality for better error handling | pending |  | Review against local BE/FE behavior, then update this row. |
| `1e0d5934d` | 2024-07-17 | Mark Felder | Fix return for cancelling job | pending |  | Review against local BE/FE behavior, then update this row. |
| `f753bd338` | 2024-07-17 | Mark Felder | Explicitly handle the GET and HEAD errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `454450576` | 2024-07-17 | feld | Merge branch 'oban/rich-media-invalid' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6cd3f9042` | 2024-07-17 | Mark Felder | Add docs for fix_mrf_policies | pending |  | Review against local BE/FE behavior, then update this row. |
| `89d22ac68` | 2024-07-17 | feld | Merge branch 'docs/fix_mrfs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c05cbaa93` | 2024-07-17 | Mark Felder | Dialyzer fix for RemoteFetcherWorker | pending |  | Review against local BE/FE behavior, then update this row. |
| `c45ee5fc8` | 2024-07-17 | feld | Merge branch 'oban/fetcher-rejected' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `62280a3b9` | 2024-07-20 | Mark Felder | Cancel queued (undelivered) publishing jobs for an activity when deleting that activity. | pending |  | Review against local BE/FE behavior, then update this row. |
| `3f5c9f003` | 2024-07-20 | Mark Felder | Reorganize test group to have shared a shared setup | pending |  | Review against local BE/FE behavior, then update this row. |
| `86ae00f9d` | 2024-07-20 | Mark Felder | Support cancelling jobs when Unfavoriting | pending |  | Review against local BE/FE behavior, then update this row. |
| `304b7f509` | 2024-07-20 | Mark Felder | Support cancelling jobs when Unrepeating | pending |  | Review against local BE/FE behavior, then update this row. |
| `d44765bc1` | 2024-07-20 | Mark Felder |  Support cancelling jobs when Unreacting | pending |  | Review against local BE/FE behavior, then update this row. |
| `776b069a0` | 2024-07-20 | feld | Merge branch 'oban/cancel-federation' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1f3ac6684` | 2024-07-18 | Mint | Transmogrifier: handle non-validate errors on incoming Delete activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3c218018` | 2024-07-18 | Mark Felder | Formatting | pending |  | Review against local BE/FE behavior, then update this row. |
| `e4a6973e0` | 2024-07-21 | feld | Merge branch 'transmogrifier/handle-non-validate-delete-errors' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `fb654acfa` | 2024-07-20 | Mark Felder | Fix OpenGraph and Twitter metadata providers when parsing objects with no content or summary fields. | pending |  | Review against local BE/FE behavior, then update this row. |
| `058f8acb5` | 2024-07-21 | feld | Merge branch 'metadata/parsing-empty' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e509519db` | 2024-07-20 | Mark Felder | Publisher jobs will not retry if the error received is a 400 | pending |  | Review against local BE/FE behavior, then update this row. |
| `b8503f1ad` | 2024-07-20 | Mark Felder | PollWorker jobs will not retry if the activity no longer exists. | pending |  | Review against local BE/FE behavior, then update this row. |
| `d62a9afed` | 2024-07-20 | Mark Felder | Improved detecting unrecoverable errors for incoming federation jobs | pending |  | Review against local BE/FE behavior, then update this row. |
| `fdeb8616e` | 2024-07-20 | Mark Felder | Increase timeout for background, remote fetcher, and user refresh jobs | pending |  | Review against local BE/FE behavior, then update this row. |
| `cf70656d1` | 2024-07-20 | Mark Felder | Fix test now that the reject error has more detail | pending |  | Review against local BE/FE behavior, then update this row. |
| `f9647a86e` | 2024-07-21 | Mark Felder | Fix the ObjectValidator error matching | pending |  | Review against local BE/FE behavior, then update this row. |
| `f77911f05` | 2024-07-22 | feld | Merge branch 'oban/more-improvements' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3a79f060b` | 2024-07-22 | Mark Felder | Add missing type | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1d334833` | 2024-07-22 | Mark Felder | Annotate public functions with typespecs and mark some functions as private | pending |  | Review against local BE/FE behavior, then update this row. |
| `7e37882cf` | 2024-07-22 | Mark Felder | Fix order of args for favorite/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `f602813d3` | 2024-07-22 | Mark Felder | Fix order of args for update/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `d27ad36ce` | 2024-07-22 | Mark Felder | Fix order of args for remove_mute/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `4601473aa` | 2024-07-22 | Mark Felder | Fix order of args for add_mute/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `8127e0d8c` | 2024-07-22 | Mark Felder | Fix order of args for thread_muted?/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `1cccc0fc2` | 2024-07-22 | Mark Felder | Fix order of args for vote/3 | pending |  | Review against local BE/FE behavior, then update this row. |
| `cbc5e4841` | 2024-07-22 | Mark Felder | Fix order of args for block/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `082319ff4` | 2024-07-22 | Mark Felder | Fix order of args for unblock/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `f79a16c06` | 2024-07-22 | Mark Felder | Fix order of args for follow/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `adb93f7e5` | 2024-07-22 | Mark Felder | Fix order of args for unfollow/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `3f4f567c9` | 2024-07-22 | Mark Felder | Fix order of args for hide_reblogs/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `12f498bc0` | 2024-07-22 | Mark Felder | Fix order of args for show_reblogs/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `c700c5db4` | 2024-07-22 | Mark Felder | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `ff663c0ae` | 2024-07-22 | feld | Merge branch 'commonapi-cleanup' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2ee8f4f06` | 2024-07-23 | Mark Felder | Fix dialyzer error | pending |  | Review against local BE/FE behavior, then update this row. |
| `f32a837af` | 2024-07-23 | feld | Merge branch 'dialyzer' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `858fd01c0` | 2024-07-24 | Mark Felder | Pleroma.HTTP: permit passing through custom Tesla Middlware for requests | pending |  | Review against local BE/FE behavior, then update this row. |
| `731f7b87d` | 2024-07-24 | Mark Felder | Pad RichMediaWorker timeout to be 2s longer than the Rich Media HTTP timeout | pending |  | Review against local BE/FE behavior, then update this row. |
| `5a6286810` | 2024-07-24 | Mark Felder | Consider errors during HTTP GET and HEAD to be unrecoverable and insert a negative cache entry | pending |  | Review against local BE/FE behavior, then update this row. |
| `97d488aea` | 2024-07-24 | Mark Felder | Fix RichMedia negative cache entries | pending |  | Review against local BE/FE behavior, then update this row. |
| `8c5a68a62` | 2024-07-24 | Mark Felder | Increase Oban.Pruner max_age to 15 mins | pending |  | Review against local BE/FE behavior, then update this row. |
| `2314ff598` | 2024-07-24 | Mark Felder | Harden Rich Media parsing against very slow or malicious URLs | pending |  | Review against local BE/FE behavior, then update this row. |
| `659891921` | 2024-07-24 | Mark Felder | Document the new timeout setting | pending |  | Review against local BE/FE behavior, then update this row. |
| `700c10668` | 2024-07-24 | feld | Merge branch 'oban/rich-media-hardening' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1a482a73c` | 2024-07-25 | Mark Felder | Fix Optimistic Inbox for failed signatures | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b9c887db` | 2024-07-25 | Mark Felder | Extract validate_signature/2 from the HTTPSignaturePlug | pending |  | Review against local BE/FE behavior, then update this row. |
| `a964368e3` | 2024-07-25 | Mark Felder | Add test to fetch and validate an activity that originally failed signature | pending |  | Review against local BE/FE behavior, then update this row. |
| `84b15ac11` | 2024-07-25 | Mark Felder | Improve specs and matching | pending |  | Review against local BE/FE behavior, then update this row. |
| `c19d55cab` | 2024-07-25 | Mark Felder | Safer string concatenation | pending |  | Review against local BE/FE behavior, then update this row. |
| `21cf321f7` | 2024-07-25 | Mark Felder | Quiet Dialyzer | pending |  | Review against local BE/FE behavior, then update this row. |
| `687676183` | 2024-07-25 | feld | Merge branch 'fix/optimistic-inbox' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8f285a787` | 2024-07-23 | Mark Felder | Refactor backups to be fully controlled by Oban | pending |  | Review against local BE/FE behavior, then update this row. |
| `e5a738d46` | 2024-07-23 | Mark Felder | Refactor tests for Backups | pending |  | Review against local BE/FE behavior, then update this row. |
| `ece063586` | 2024-07-23 | Mark Felder | Limit backup jobs to 5 minutes | pending |  | Review against local BE/FE behavior, then update this row. |
| `3f60d7bf6` | 2024-07-23 | Mark Felder | Better random tempdir format | pending |  | Review against local BE/FE behavior, then update this row. |
| `e5cbbaf3f` | 2024-07-23 | Mark Felder | Extend the backup job time limit to 30 minutes | pending |  | Review against local BE/FE behavior, then update this row. |
| `187897874` | 2024-07-23 | Mark Felder | Make backup timeout configurable | pending |  | Review against local BE/FE behavior, then update this row. |
| `775f45cfe` | 2024-07-25 | Mark Felder | Merge remote-tracking branch 'origin/develop' into oban/backup | pending |  | Review against local BE/FE behavior, then update this row. |
| `c9042763b` | 2024-07-29 | feld | Merge branch 'oban/backup' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `66649e1dc` | 2024-07-30 | Mark Felder | Remove unused Oban queue | pending |  | Review against local BE/FE behavior, then update this row. |
| `4e24445b5` | 2024-07-30 | feld | Merge branch 'oban/transmog' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `59309a9ef` | 2024-07-28 | Mark Felder | Publisher job simplification | pending |  | Review against local BE/FE behavior, then update this row. |
| `74072622e` | 2024-07-29 | Mark Felder | Remove actor and actor_id from the job as it can be inferred by the activity | pending |  | Review against local BE/FE behavior, then update this row. |
| `8893ad989` | 2024-07-29 | Mark Felder | Fix cancelling jobs | pending |  | Review against local BE/FE behavior, then update this row. |
| `b48fd89a4` | 2024-07-29 | Mark Felder | Revert unintended change to the Logger metadata tag name | pending |  | Review against local BE/FE behavior, then update this row. |
| `05d498979` | 2024-07-29 | Mark Felder | Insert replacement jobs in the new format if any remain undelivered | pending |  | Review against local BE/FE behavior, then update this row. |
| `1bce582f0` | 2024-07-30 | Mark Felder | Fix migration crashing due to Oban not running | pending |  | Review against local BE/FE behavior, then update this row. |
| `18469f3b1` | 2024-07-30 | feld | Merge branch 'oban/simpler-publish' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a6119210b` | 2024-07-30 | Mark Felder | Increase federator outgoing job parallelism | pending |  | Review against local BE/FE behavior, then update this row. |
| `a90838acc` | 2024-07-30 | feld | Merge branch 'federation/increase' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `49f46220f` | 2024-07-30 | Mark Felder | Align Hackney and Gun connection pool timeouts | pending |  | Review against local BE/FE behavior, then update this row. |
| `355b028c2` | 2024-07-30 | feld | Merge branch 'hackney-pool-timeout' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b50261262` | 2024-07-30 | Mark Felder | Fix publisher job migration error | pending |  | Review against local BE/FE behavior, then update this row. |
| `f646b0554` | 2024-07-30 | feld | Merge branch 'fix-migration' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e6951e7e4` | 2024-07-31 | Mark Felder | Fix User.disclose_client never working correctly | pending |  | Review against local BE/FE behavior, then update this row. |
| `f2dc706f6` | 2024-07-31 | feld | Merge branch 'fix/disclose_client' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2e6ddc499` | 2024-08-01 | Lain Soykaf | Prepare changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `574bc1fa5` | 2024-08-01 | Lain Soykaf | Frontend: Update to 2.7.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `a5d32aab5` | 2024-08-01 | Lain Soykaf | Mix: Update version to 2.7.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `36d469cf0` | 2024-08-01 | lain | Merge branch 'release/2.7.0' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8f1866e3a` | 2024-08-02 | lain | Merge branch 'stable' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1f986ec71` | 2024-08-02 | Mark Felder | Gun: Publisher job behavior improvement | pending |  | Review against local BE/FE behavior, then update this row. |
| `b389b85d7` | 2024-08-02 | feld | Merge branch 'gun/snooze' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `de9194893` | 2024-08-03 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Support `id` param in `GET /api/v1/statuses` | pending |  | Review against local BE/FE behavior, then update this row. |
| `9cf684d66` | 2024-08-05 | Haelwenn | Merge branch 'get-statuses-param' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `16ba2742b` | 2024-08-06 | Mark Felder | Use the normal Oban test assertions | pending |  | Review against local BE/FE behavior, then update this row. |
| `f8bdcaa16` | 2024-08-06 | Mark Felder | Split Federator.publish_one/1 into a second function called prepare_one/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `0319d1ad3` | 2024-08-06 | Mark Felder | Remove test, logic was flawed | pending |  | Review against local BE/FE behavior, then update this row. |
| `21fee4215` | 2024-08-06 | Mark Felder | Test Factory: ensure remote users have a valid inbox | pending |  | Review against local BE/FE behavior, then update this row. |
| `30eef434a` | 2024-08-06 | Mark Felder | Test that cc on a published Follow is an empty list | pending |  | Review against local BE/FE behavior, then update this row. |
| `83fcf42c7` | 2024-08-06 | Mark Felder | Force cc to an empty list if undefined | pending |  | Review against local BE/FE behavior, then update this row. |
| `9ae9e2fc5` | 2024-08-06 | Mark Felder | Use a struct to hold the prepared data passed to publish_one/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `a01f0f0f0` | 2024-08-06 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `706fc7e1e` | 2024-08-06 | Mark Felder | Remove unused mocks | pending |  | Review against local BE/FE behavior, then update this row. |
| `0bfe59204` | 2024-08-06 | Mark Felder | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `c0195895d` | 2024-08-06 | feld | Merge branch 'publisher-cc-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `52e9bec15` | 2024-07-30 | Mark Felder | Remove WorkerHelper | pending |  | Review against local BE/FE behavior, then update this row. |
| `1d3a92be1` | 2024-07-30 | Mark Felder | Remove :workers config from ConfigDB | pending |  | Review against local BE/FE behavior, then update this row. |
| `d56b889cf` | 2024-07-30 | Mark Felder | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `a2490ddd9` | 2024-08-07 | feld | Merge branch 'remove/workerhelper' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `52f7033f7` | 2024-08-04 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | StreamerView: Do not leak follows count if hidden | pending |  | Review against local BE/FE behavior, then update this row. |
| `c284c4e3e` | 2024-08-07 | Mark Felder | Extract the logic from the map | pending |  | Review against local BE/FE behavior, then update this row. |
| `7d33b5390` | 2024-08-07 | Mark Felder | Improve the variable naming | pending |  | Review against local BE/FE behavior, then update this row. |
| `ad7fe4e95` | 2024-08-07 | Mark Felder | Tests to confirm wanted behavior | pending |  | Review against local BE/FE behavior, then update this row. |
| `351a306d4` | 2024-08-07 | feld | Merge branch 'stream-follow-relationships-count' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9d27a074c` | 2024-08-07 | Mark Felder | Merge branch 'stream-follow-relationships-count' into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `06e8ece4c` | 2024-08-07 | Mark Felder | Fix CommonAPI.follow/2 which returned users in the reverse order they were provided to the function | pending |  | Review against local BE/FE behavior, then update this row. |
| `c81c663db` | 2024-08-07 | feld | Merge branch 'commonapi-consistency' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `721005b31` | 2024-08-07 | Mark Felder | Fix WebPush notifications not generating jobs | pending |  | Review against local BE/FE behavior, then update this row. |
| `6900040fd` | 2024-08-07 | Mark Felder | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `45611ed32` | 2024-08-07 | feld | Merge branch 'workerhelper-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d2d07bfe4` | 2024-08-07 | Mark Felder | Add test for Follow objects with a cc | pending |  | Review against local BE/FE behavior, then update this row. |
| `8f15000c0` | 2024-08-07 | Mark Felder | Do not require a cc field when validating an incoming Follow activity | pending |  | Review against local BE/FE behavior, then update this row. |
| `b25f67372` | 2024-08-07 | Mark Felder | Improve the FollowValidator | pending |  | Review against local BE/FE behavior, then update this row. |
| `fcda1b5e2` | 2024-08-07 | Mark Felder | Improve variable name | pending |  | Review against local BE/FE behavior, then update this row. |
| `526a57ff9` | 2024-08-07 | Mark Felder | Remove validation for cc fields on Follow Accept/Reject | pending |  | Review against local BE/FE behavior, then update this row. |
| `ca934b744` | 2024-08-07 | Mark Felder | Remove validation for cc fields on Blocks | pending |  | Review against local BE/FE behavior, then update this row. |
| `72b5974f8` | 2024-08-08 | lain | Merge branch 'follow-validator' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `253178538` | 2024-08-07 | Mark Felder | Do not allow committing tests with a .ex extension | pending |  | Review against local BE/FE behavior, then update this row. |
| `9e42c6b6a` | 2024-08-07 | Mark Felder | Merge remote-tracking branch 'origin/develop' into inactive-test | pending |  | Review against local BE/FE behavior, then update this row. |
| `540e62c5f` | 2024-08-08 | feld | Merge branch 'inactive-test' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c116024bb` | 2024-08-12 | Mark Felder | Fix Swoosh Mailgun support | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3fbbfb39` | 2024-08-12 | feld | Merge branch 'swoosh-mailgun' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6e53e94bd` | 2024-08-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Remove stub for /api/v1/accounts/:id/identity_proofs (deprecated by Mastodon 3.5.0) | pending |  | Review against local BE/FE behavior, then update this row. |
| `29f7ab711` | 2024-08-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update test as /api/v1/endorsements is not a stub | pending |  | Review against local BE/FE behavior, then update this row. |
| `34715b858` | 2024-08-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | remove unused alias | pending |  | Review against local BE/FE behavior, then update this row. |
| `b76dfd814` | 2024-08-12 | Mark Felder | Revert accidental removal of test unrelated to identity proofs | pending |  | Review against local BE/FE behavior, then update this row. |
| `aa4f5428d` | 2024-08-12 | feld | Merge branch 'identity-proofs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a0af6cba0` | 2024-08-08 | Mark Felder | Added MRF.QuietReply which prevents replies to public posts from being published to the timelines | pending |  | Review against local BE/FE behavior, then update this row. |
| `d6cc6aff9` | 2024-08-08 | Mark Felder | Unintended commit | pending |  | Review against local BE/FE behavior, then update this row. |
| `5a134a46f` | 2024-08-08 | Mark Felder | We must change to/cc in the activity and inner object | pending |  | Review against local BE/FE behavior, then update this row. |
| `471f5c81f` | 2024-08-12 | Mark Felder | Add module documentation | pending |  | Review against local BE/FE behavior, then update this row. |
| `c29441f30` | 2024-08-12 | feld | Merge branch 'mrf-quietreply' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c1c0f0b14` | 2024-08-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Mark `/api/v1/pleroma/accounts/:id/subscribe`/`unsubscribe` as deprecated | pending |  | Review against local BE/FE behavior, then update this row. |
| `f87aa8b83` | 2024-08-12 | feld | Merge branch 'deprecate-subscribe' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c0ca7a4ec` | 2024-08-12 | Mark Felder | User Factory: include the nickname in the generated URLs | pending |  | Review against local BE/FE behavior, then update this row. |
| `fe2ed3fbc` | 2024-08-12 | feld | Merge branch 'user-factory' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `488c4b8b9` | 2024-08-12 | Mark Felder | MRF.FODirectReply | pending |  | Review against local BE/FE behavior, then update this row. |
| `4e7928c98` | 2024-08-12 | feld | Merge branch 'followers-only-reply-direct-mrf' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8c978727c` | 2024-08-12 | Mark Felder | MRF.QuietReply: add test for replies to unlisted posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `b0c64945c` | 2024-08-12 | Mark Felder | MRF.FODirectReply: use Visibility module to verify the scope | pending |  | Review against local BE/FE behavior, then update this row. |
| `7388c4b5c` | 2024-08-13 | feld | Merge branch 'mrf-tests' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2ba5ad8eb` | 2024-08-13 | Mark Felder | MRF cleanup | pending |  | Review against local BE/FE behavior, then update this row. |
| `ccf476a4c` | 2024-08-13 | feld | Merge branch 'mrf-cleanup' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `648e94b36` | 2024-08-13 | Mark Felder | Fix the uploads migration mix task test which leaked a change to the configured Uploader | pending |  | Review against local BE/FE behavior, then update this row. |
| `b281ad06d` | 2024-08-13 | Mark Felder | Revert "Custom mix task to retry failed tests once in CI pipeline" | pending |  | Review against local BE/FE behavior, then update this row. |
| `5174c29d4` | 2024-08-13 | feld | Merge branch 'fix-random-test-errors' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b0e3a8631` | 2024-08-15 | Haelwenn (lanodan) Monnier | CI: GIT_STRATEGY: fetch | pending |  | Review against local BE/FE behavior, then update this row. |
| `3119ed364` | 2024-08-16 | feld | Merge branch 'ci-git-fetch' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8cd8cea3f` | 2024-08-14 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix 'Setting a marker should mark notifications as read' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c91fc03e6` | 2024-08-16 | feld | Merge branch 'norifications-marker' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3b1e6ac8f` | 2024-08-14 | Haelwenn (lanodan) Monnier | User: truncate remote user fields instead of rejecting | pending |  | Review against local BE/FE behavior, then update this row. |
| `fcf9ad557` | 2024-08-16 | feld | Merge branch 'bugfix-truncate-remote-user-fields' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e1333c4fa` | 2024-08-16 | Mark Felder | Update mogrify | pending |  | Review against local BE/FE behavior, then update this row. |
| `7537c22b2` | 2024-08-17 | Mark Felder | Update Oban to 2.18 | pending |  | Review against local BE/FE behavior, then update this row. |
| `ee26d8557` | 2024-08-17 | feld | Merge branch 'bump-oban' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `190a505ad` | 2024-08-17 | Mark Felder | Merge remote-tracking branch 'origin/develop' into mogrify | pending |  | Review against local BE/FE behavior, then update this row. |
| `2f5a1db56` | 2024-08-18 | feld | Merge branch 'mogrify' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `089fa4d14` | 2024-08-17 | Mark Felder | Improve Remote Object Fetcher error handling, Oban | pending |  | Review against local BE/FE behavior, then update this row. |
| `12d682c62` | 2024-08-19 | feld | Merge branch 'remote-fetcher-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `55cc1ba50` | 2024-08-19 | Mark Felder | Fix test cases for validating instance reachability based on results of publishing attempts | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b8141b50` | 2024-08-19 | Mark Felder | Address case where instance reachability status couldn't be updated | pending |  | Review against local BE/FE behavior, then update this row. |
| `08a444f6c` | 2024-08-19 | feld | Merge branch 'reachability' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `649e51b58` | 2024-08-22 | Mark Felder | Fix Oban jobs for imports | pending |  | Review against local BE/FE behavior, then update this row. |
| `a9aa810d3` | 2024-08-22 | Mark Felder | Change imports to generate an Oban job per each task | pending |  | Review against local BE/FE behavior, then update this row. |
| `39108c5f1` | 2024-08-22 | Mark Felder | Remove unnecessary re-fetch of the actor | pending |  | Review against local BE/FE behavior, then update this row. |
| `0f3920f79` | 2024-08-22 | feld | Merge branch 'fix-imports' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `99ace19ca` | 2024-08-22 | Eric Zhang | Added translation using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `743c4f2f5` | 2024-08-22 | Eric Zhang | Translated using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `1902323e9` | 2024-08-22 | Yating Zhan | Translated using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `6ba1b7925` | 2024-08-22 | Eric Zhang | Translated using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `73c6d7eae` | 2024-08-22 | Eric Zhang | Translated using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `030be7130` | 2024-08-22 | Eric Zhang | Translated using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `914fdc508` | 2024-08-22 | Eric Zhang | Translated using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `7b979ac09` | 2024-08-22 | Eric Zhang | Translated using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `9e3fa8924` | 2024-08-22 | Eric Zhang | Translated using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `16c6942df` | 2024-08-22 | Eric Zhang | Translated using Weblate (Chinese (Simplified)) | pending |  | Review against local BE/FE behavior, then update this row. |
| `58f646bcd` | 2024-08-23 | tusooa | Merge branch 'weblate' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3419e2cbd` | 2024-08-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Correct response in AdminAPI docs | pending |  | Review against local BE/FE behavior, then update this row. |
| `1e8b79956` | 2024-08-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'docs-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `fc450fdef` | 2024-08-28 | Mark Felder | ReceiverWorker: cancel job if user fetch is forbidden | pending |  | Review against local BE/FE behavior, then update this row. |
| `60101e240` | 2024-08-28 | Mark Felder | Add test confirming cancellation for activity by a deleted user | pending |  | Review against local BE/FE behavior, then update this row. |
| `66e1b4089` | 2024-08-28 | Mark Felder | Cancel if the User fetch resulted in a 410 | pending |  | Review against local BE/FE behavior, then update this row. |
| `48a466188` | 2024-08-28 | Mark Felder | Simplify test, move data into a json fixture | pending |  | Review against local BE/FE behavior, then update this row. |
| `3dadb9ed0` | 2024-08-28 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb2f4a76b` | 2024-08-28 | Mark Felder | Add test for origin containment failures | pending |  | Review against local BE/FE behavior, then update this row. |
| `6ae629cfe` | 2024-08-28 | Mark Felder | Cancel ReceiverWorker jobs if the user account has been disabled / deactivated | pending |  | Review against local BE/FE behavior, then update this row. |
| `2e9515578` | 2024-08-28 | Mark Felder | ReceiverWorker job canceled due to deleted object | pending |  | Review against local BE/FE behavior, then update this row. |
| `2346807ac` | 2024-08-28 | Mark Felder | Annotate error cases | pending |  | Review against local BE/FE behavior, then update this row. |
| `380a6a6df` | 2024-08-28 | Mark Felder | :validate_object is not a real error returned from anywhere | pending |  | Review against local BE/FE behavior, then update this row. |
| `c5ca806aa` | 2024-08-28 | Mark Felder | Add back one of the duplicate checks to fix a test, document where it comes from | pending |  | Review against local BE/FE behavior, then update this row. |
| `8a3efa715` | 2024-08-28 | Mark Felder | More error annotations | pending |  | Review against local BE/FE behavior, then update this row. |
| `e498d252e` | 2024-08-28 | Mark Felder | Changelog update | pending |  | Review against local BE/FE behavior, then update this row. |
| `1821ef4f1` | 2024-08-28 | Mark Felder | Move user active check into Federator.perform/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `7910b235c` | 2024-08-28 | feld | Merge branch 'user-refresh-oban-tests' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f6506d86` | 2024-08-27 | Mark Felder | Pleroma.HTTP: option stream: true will return a stream as the body for Gun adapter | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb279c280` | 2024-08-27 | Mark Felder | Pleroma.HTTP add AdapterHelper.can_stream? to assist with discovering if the current adapter supports returning a Stream body | pending |  | Review against local BE/FE behavior, then update this row. |
| `ec8db9d4e` | 2024-08-27 | Mark Felder | RichMedia: skip the HTTP HEAD request for adapters that support streaming the response body | pending |  | Review against local BE/FE behavior, then update this row. |
| `0a86d2b3a` | 2024-08-27 | Mark Felder | Handle streaming response errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `116fe77b7` | 2024-08-27 | Mark Felder | Tesla.Middleware.Timeout breaks streaming bodies | pending |  | Review against local BE/FE behavior, then update this row. |
| `44901502f` | 2024-08-27 | Mark Felder | Fix incorrect identifier for the with statement | pending |  | Review against local BE/FE behavior, then update this row. |
| `0804b73c0` | 2024-08-27 | Mark Felder | This error is not returned by Tesla | pending |  | Review against local BE/FE behavior, then update this row. |
| `0bf82a174` | 2024-08-28 | Mark Felder | Add an AdapterHelper for Finch so we can support streaming request bodies | pending |  | Review against local BE/FE behavior, then update this row. |
| `8ab4dd20d` | 2024-08-28 | Mark Felder | Update comments, remove solved TODO | pending |  | Review against local BE/FE behavior, then update this row. |
| `d01569822` | 2024-08-28 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `c17a78c55` | 2024-08-29 | Mark Felder | Rich Media: add stream byte counting as an extra protection against malicious URLs | pending |  | Review against local BE/FE behavior, then update this row. |
| `8d0703460` | 2024-08-29 | feld | Merge branch 'pleroma-http-stream' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `010edcbcb` | 2024-08-21 | Mark Felder | Use Map.filter now that minimum Elixir version is 1.13 | pending |  | Review against local BE/FE behavior, then update this row. |
| `e65555e8c` | 2024-08-21 | Mark Felder | Remove workaround for URI.merge bug on nil fields before Elixir 1.13 | pending |  | Review against local BE/FE behavior, then update this row. |
| `5138a4984` | 2024-08-21 | Mark Felder | Skip changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `b5814dc9b` | 2024-08-29 | Mark Felder | Merge remote-tracking branch 'origin/develop' into todo-fixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `62856ab18` | 2024-08-29 | feld | Merge branch 'todo-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ceffb8a89` | 2024-08-29 | Mark Felder | Drop incoming Delete activities from unknown actors | pending |  | Review against local BE/FE behavior, then update this row. |
| `4bc6f334f` | 2024-08-29 | Mark Felder | Revert unintentional change | pending |  | Review against local BE/FE behavior, then update this row. |
| `1c394dd18` | 2024-08-29 | Mark Felder | Move the check to the inbox | pending |  | Review against local BE/FE behavior, then update this row. |
| `27fcc4217` | 2024-08-29 | feld | Use Pleroma.Object.Containment.get_actor/1 to reliably find the actor of an incoming activity or object | pending |  | Review against local BE/FE behavior, then update this row. |
| `7bcc21ad6` | 2024-08-29 | Mark Felder | Switch test to the inbox | pending |  | Review against local BE/FE behavior, then update this row. |
| `06deacd58` | 2024-08-29 | Mark Felder | Formatting | pending |  | Review against local BE/FE behavior, then update this row. |
| `16a9b3487` | 2024-08-29 | Mark Felder | Convert to an Plug called InboxGuard | pending |  | Review against local BE/FE behavior, then update this row. |
| `e2cdae2c8` | 2024-08-29 | Mark Felder | Change relay inbox response when not federating to a 403 for consistency | pending |  | Review against local BE/FE behavior, then update this row. |
| `990b2058d` | 2024-08-29 | Mark Felder | Remove unnecessary error match in ReceiverWorker | pending |  | Review against local BE/FE behavior, then update this row. |
| `2b39956ac` | 2024-08-29 | Mark Felder | Fix test title to be more specific as it has a broader but incorrect meaning | pending |  | Review against local BE/FE behavior, then update this row. |
| `012132303` | 2024-08-29 | Mark Felder | Test more types we do not want to receive from strangers | pending |  | Review against local BE/FE behavior, then update this row. |
| `094da5d63` | 2024-08-29 | Mark Felder | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `5205e846e` | 2024-08-30 | feld | Update allowed activity types from strangers | pending |  | Review against local BE/FE behavior, then update this row. |
| `e38f5f1a8` | 2024-08-30 | Mark Felder | Add recognized activity types to a constant and use it in the test | pending |  | Review against local BE/FE behavior, then update this row. |
| `11ee94ae1` | 2024-08-30 | Mark Felder | InboxGuardPlug: Add early rejection of unknown activity types | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb235f913` | 2024-08-30 | Mark Felder | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `61e4be396` | 2024-09-01 | feld | Merge branch 'drop-unknown-deletes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `5a1144208` | 2024-09-01 | Mark Felder | Prevent OAuth App flow from creating duplicate entries | pending |  | Review against local BE/FE behavior, then update this row. |
| `e3a7c1d90` | 2024-09-01 | Mark Felder | Test that app scopes can be updated | pending |  | Review against local BE/FE behavior, then update this row. |
| `751d63d4b` | 2024-09-01 | Mark Felder | Support OAuth App updating the website URL | pending |  | Review against local BE/FE behavior, then update this row. |
| `9077d0925` | 2024-09-01 | feld | Merge branch 'oauth-app-spam' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `37397a43b` | 2024-09-02 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | scrubbers/default: Allow "mention hashtag" classes used by Mastodon | pending |  | Review against local BE/FE behavior, then update this row. |
| `fecfe8bf8` | 2024-09-02 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'scrubbers-allow-mention-hashtag' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `92d5f0ac1` | 2024-09-04 | feld | Revert "Merge branch 'oauth-app-spam' into 'develop'" | pending |  | Review against local BE/FE behavior, then update this row. |
| `fbcfbde83` | 2024-09-04 | feld | Merge branch 'revert-9077d092' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `427da7a99` | 2024-09-04 | Mark Felder | Rate Limit the OAuth App spam | pending |  | Review against local BE/FE behavior, then update this row. |
| `7bd075078` | 2024-09-04 | Mark Felder | Ensure apps are assigned to users | pending |  | Review against local BE/FE behavior, then update this row. |
| `a1951f3af` | 2024-09-04 | Mark Felder | Add Cron worker to clean up orphaned apps hourly | pending |  | Review against local BE/FE behavior, then update this row. |
| `53744bf14` | 2024-09-04 | Mark Felder | Limit the number of orphaned to delete at 100 every 10 mins due to the cascading queries that have to check oauth_authorizations and oauth_tokens tables. | pending |  | Review against local BE/FE behavior, then update this row. |
| `1797f5958` | 2024-09-05 | Mark Felder | App orphans should only be removed if they are older than 15 mins | pending |  | Review against local BE/FE behavior, then update this row. |
| `25db1a5d6` | 2024-09-05 | feld | Merge branch 'oauth-app-spam2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `fb376ce00` | 2024-09-05 | Mark Felder | Test Account View does not indicate following if a FollowingRelationship is missing | pending |  | Review against local BE/FE behavior, then update this row. |
| `4d76692db` | 2024-09-05 | Mark Felder | Fix Following status bug | pending |  | Review against local BE/FE behavior, then update this row. |
| `e51cd31a5` | 2024-09-05 | Mark Felder | Bump credo to prevent it from crashing | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f573b409` | 2024-09-05 | Mark Felder | Credo: comment line length | pending |  | Review against local BE/FE behavior, then update this row. |
| `2c916ccd8` | 2024-09-06 | feld | Merge branch 'following-state-bug' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1afcfd484` | 2024-09-06 | Mark Felder | Add tests for Mastodon mention hashtag class | pending |  | Review against local BE/FE behavior, then update this row. |
| `7f3600fdd` | 2024-09-06 | feld | Merge branch 'scrubber-mention-hashtag' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a88718889` | 2024-09-06 | Mark Felder | Oban: more unique job constraints | pending |  | Review against local BE/FE behavior, then update this row. |
| `b871551d9` | 2024-09-06 | feld | Merge branch 'oban-uniques' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `fc3ea94a1` | 2024-09-06 | Mark Felder | Dialyzer: the pattern can never match the type | pending |  | Review against local BE/FE behavior, then update this row. |
| `bc16f09d7` | 2024-09-06 | Mark Felder | Dialyzer: the pattern can never match the type | pending |  | Review against local BE/FE behavior, then update this row. |
| `7eb579c19` | 2024-09-06 | Mark Felder | Dialyzer: invalid contract | pending |  | Review against local BE/FE behavior, then update this row. |
| `06d6febff` | 2024-09-06 | Mark Felder | Dialyzer: The pattern variable _e@1 can never match the type, because it is covered by previous clauses. | pending |  | Review against local BE/FE behavior, then update this row. |
| `1d0e3b135` | 2024-09-06 | Mark Felder | Dialyzer: The pattern variable _ can never match the type, because it is covered by previous clauses. | pending |  | Review against local BE/FE behavior, then update this row. |
| `06ce5e3b4` | 2024-09-06 | Mark Felder | Dialyzer: pattern_match The pattern can never match the type {:diff, false}. | pending |  | Review against local BE/FE behavior, then update this row. |
| `5b26c5662` | 2024-09-06 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `80f3e507d` | 2024-09-06 | feld | Merge branch 'dialyzer' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4ae17c629` | 2024-08-30 | Mark Felder | NodeInfo: Accept application/activity+json requests | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb0cb06d8` | 2024-09-06 | feld | Merge branch 'well-known' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c9b28eaf9` | 2024-09-08 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Argon2 password support | pending |  | Review against local BE/FE behavior, then update this row. |
| `9de522ce5` | 2024-09-08 | Mint | Authentication: convert argon2 passwords, add tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `7e91c3a30` | 2024-09-08 | Mint | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `20e82c745` | 2024-09-08 | Haelwenn | Merge branch 'argon2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7def11d7c` | 2024-09-11 | Mark Felder | LDAP Auth: fix TLS certificate verification | pending |  | Review against local BE/FE behavior, then update this row. |
| `360dd34f1` | 2024-09-11 | feld | Merge branch 'ldap-tls' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `affdcdb68` | 2024-09-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Manifest: declare /static/logo.svg as 512x512 to match one provided by pleroma-fe | pending |  | Review against local BE/FE behavior, then update this row. |
| `abf38b405` | 2024-09-14 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'manifest-icon-size' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6d5ae4d2e` | 2024-09-03 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Include list id in StatusView | pending |  | Review against local BE/FE behavior, then update this row. |
| `0111659a1` | 2024-09-14 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'list-id-visibility' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `71ef9f951` | 2024-08-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Allow providing avatar/header descriptions | pending |  | Review against local BE/FE behavior, then update this row. |
| `681765669` | 2024-08-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add test for avatar description | pending |  | Review against local BE/FE behavior, then update this row. |
| `071452a5d` | 2024-08-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `855c5a234` | 2024-08-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update docs | pending |  | Review against local BE/FE behavior, then update this row. |
| `c802f3b7f` | 2024-08-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Validate media description length | pending |  | Review against local BE/FE behavior, then update this row. |
| `349866271` | 2024-08-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Move new fields to pleroma object | pending |  | Review against local BE/FE behavior, then update this row. |
| `917ac89b4` | 2024-08-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `c1a115088` | 2024-09-14 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'profile-image-descriptions' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `17b69c43d` | 2024-09-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add `group_key` to notifications | pending |  | Review against local BE/FE behavior, then update this row. |
| `8250a9764` | 2024-09-15 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'notifications-group-key' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e59706c20` | 2024-09-16 | Mark Felder | Reapply "Custom mix task to retry failed tests once in CI pipeline" | pending |  | Review against local BE/FE behavior, then update this row. |
| `5539fea3b` | 2024-09-14 | Mark Felder | LDAP: permit overriding the CA root | pending |  | Review against local BE/FE behavior, then update this row. |
| `af3bf8a46` | 2024-09-15 | Mark Felder | Support implicit TLS connections | pending |  | Review against local BE/FE behavior, then update this row. |
| `91d1d7260` | 2024-09-15 | Mark Felder | Retain the try do so an LDAP failure can fall back to local database. | pending |  | Review against local BE/FE behavior, then update this row. |
| `3a0d4e983` | 2024-09-16 | feld | Merge branch 'ldap-tls' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e24e107f3` | 2024-09-16 | Mark Felder | Merge remote-tracking branch 'origin/develop' into retry-tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `e7176bb99` | 2024-09-16 | feld | Merge branch 'retry-tests' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9264b2190` | 2024-09-17 | Mark Felder | Pleroma.LDAP | pending |  | Review against local BE/FE behavior, then update this row. |
| `ead287d62` | 2024-09-17 | Mark Felder | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `7c04098dd` | 2024-09-17 | Mark Felder | Catchall for when LDAP is not enabled | pending |  | Review against local BE/FE behavior, then update this row. |
| `44b836c94` | 2024-09-17 | Mark Felder | Fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `d82abf925` | 2024-09-17 | Mark Felder | Ensure :cacertfile is configurable in ConfigDB | pending |  | Review against local BE/FE behavior, then update this row. |
| `65a7b387c` | 2024-09-17 | Mark Felder | Require a reboot if LDAP configuration changes | pending |  | Review against local BE/FE behavior, then update this row. |
| `123093a18` | 2024-09-17 | Mark Felder | Ensure :ssl is started before we attempt to make the LDAP connection | pending |  | Review against local BE/FE behavior, then update this row. |
| `d0ee899ab` | 2024-09-17 | Mark Felder | Only close connection if it is not nil | pending |  | Review against local BE/FE behavior, then update this row. |
| `164ffbcab` | 2024-09-17 | Mark Felder | Fix return value when not doing STARTTLS | pending |  | Review against local BE/FE behavior, then update this row. |
| `a1972d57e` | 2024-09-17 | Mark Felder | Link the eldap connection process | pending |  | Review against local BE/FE behavior, then update this row. |
| `14a9663f1` | 2024-09-17 | Mark Felder | Remove cacertfile as child of SSL and TLS options | pending |  | Review against local BE/FE behavior, then update this row. |
| `363b462c5` | 2024-09-17 | Mark Felder | Make the email attribute configurable | pending |  | Review against local BE/FE behavior, then update this row. |
| `21bf22973` | 2024-09-17 | Mark Felder | Reduce LDAP timeouts | pending |  | Review against local BE/FE behavior, then update this row. |
| `1d123832d` | 2024-09-17 | Mark Felder | Formatting | pending |  | Review against local BE/FE behavior, then update this row. |
| `ea63533cf` | 2024-09-17 | Mark Felder | Change :connection to :handle to match upstream nomenclature | pending |  | Review against local BE/FE behavior, then update this row. |
| `2b482e34e` | 2024-09-17 | Mark Felder | Improve matching on bind errors | pending |  | Review against local BE/FE behavior, then update this row. |
| `35ddb1d2c` | 2024-09-17 | Mark Felder | LDAP genserver changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `f423534ef` | 2024-09-17 | feld | Merge branch 'ldap-tls' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e10db52e0` | 2024-09-13 | Mint | Add dependencies for Swoosh's Mua mail adapter | pending |  | Review against local BE/FE behavior, then update this row. |
| `1de5208a9` | 2024-09-17 | Mint | Cheatsheet: add Mua mail adapter config | pending |  | Review against local BE/FE behavior, then update this row. |
| `8776d3179` | 2024-09-17 | feld | Merge branch 'swoosh-mua' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ecd1b8393` | 2024-09-18 | Mark Felder | Oban: update to 2.18.3 | pending |  | Review against local BE/FE behavior, then update this row. |
| `73204c1bc` | 2024-09-18 | Mark Felder | LDAP: fix compile warning | pending |  | Review against local BE/FE behavior, then update this row. |
| `635829494` | 2024-09-18 | feld | Merge branch 'ldap-call' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f00545d85` | 2024-09-18 | Mark Felder | Elixir 1.14 and Erlang/OTP 23 is now the minimum supported release | pending |  | Review against local BE/FE behavior, then update this row. |
| `7e303600f` | 2024-09-18 | Mark Felder | Remove old elixir 1.12 build image generation script | pending |  | Review against local BE/FE behavior, then update this row. |
| `1bd28e7d5` | 2024-09-18 | Mark Felder | CI script to build and publish an image for Elixir 1.14 | pending |  | Review against local BE/FE behavior, then update this row. |
| `7c37fc6a7` | 2024-09-19 | feld | Merge branch 'elixir-1.14' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d6a364dad` | 2024-09-19 | Mark Felder | Merge remote-tracking branch 'origin/develop' into oban-bump | pending |  | Review against local BE/FE behavior, then update this row. |
| `196f10882` | 2024-09-19 | feld | Merge branch 'oban-bump' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `03e14e759` | 2024-09-21 | Haelwenn (lanodan) Monnier | MRF: Add filtering against AP id | pending |  | Review against local BE/FE behavior, then update this row. |
| `3dd6f6585` | 2024-09-21 | Haelwenn (lanodan) Monnier | Object.Fetcher: Hook to MRF.id_filter | pending |  | Review against local BE/FE behavior, then update this row. |
| `30063c591` | 2024-09-21 | Haelwenn (lanodan) Monnier | MRF.DropPolicy: Add id_filter/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `0fa13c553` | 2024-09-21 | Haelwenn (lanodan) Monnier | MRF.SimplePolicy: Add id_filter/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `bc1b4f0be` | 2024-09-21 | Haelwenn | Merge branch 'features/mrf-id_filter' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a1e3fb506` | 2024-09-21 | Haelwenn (lanodan) Monnier | Dockerfile: Elixir 1.14 | pending |  | Review against local BE/FE behavior, then update this row. |
| `d2eb4992e` | 2024-09-21 | Haelwenn | Merge branch 'elixir-1.14-docker' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1a120d013` | 2024-09-14 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Federate avatar/header descriptions | pending |  | Review against local BE/FE behavior, then update this row. |
| `07cfbe4ae` | 2024-10-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'profile-image-descriptions' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e74e0089b` | 2024-09-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Repesct :restrict_unauthenticated for hashtag rss/atom feeds | pending |  | Review against local BE/FE behavior, then update this row. |
| `ddedc575e` | 2024-10-09 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'hashtag-feeds-restricted' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `382426e03` | 2024-09-30 | Mark Felder | Remove Object.get_by_id_and_maybe_refetch/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `2380ae6dc` | 2024-09-30 | Mark Felder | Validate an Oban job is inserted for poll refreshes | pending |  | Review against local BE/FE behavior, then update this row. |
| `c077a14ce` | 2024-09-30 | Mark Felder | Add Oban job to handle poll refreshing and stream out the update | pending |  | Review against local BE/FE behavior, then update this row. |
| `4b3f604f9` | 2024-09-30 | Mark Felder | Skip refetching poll results if the object's updated_at is newer than the poll closed timestamp | pending |  | Review against local BE/FE behavior, then update this row. |
| `47ce3a4a9` | 2024-09-30 | Mark Felder | Schedule a final poll refresh before streaming out the notifications | pending |  | Review against local BE/FE behavior, then update this row. |
| `a2e7db43a` | 2024-09-30 | Mark Felder | Rename assignment for consistency | pending |  | Review against local BE/FE behavior, then update this row. |
| `766edfe5b` | 2024-09-30 | Mark Felder | Test Poll refresh jobs stream out updates after refetching the object | pending |  | Review against local BE/FE behavior, then update this row. |
| `b2340b5b7` | 2024-09-30 | Mark Felder | Permit backdating the poll closed timestamp | pending |  | Review against local BE/FE behavior, then update this row. |
| `a1b384f63` | 2024-09-30 | Mark Felder | Test that a poll refresh is cancelled if updated_at on the object is newer than the poll closing time | pending |  | Review against local BE/FE behavior, then update this row. |
| `2ab404950` | 2024-09-30 | Mark Felder | Poll refreshing changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `b735d9e6e` | 2024-09-30 | Mark Felder | Improve assertion | pending |  | Review against local BE/FE behavior, then update this row. |
| `9ff57946e` | 2024-09-30 | Mark Felder | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `0a42a3f2e` | 2024-10-02 | Mark Felder | Do not attempt to schedule poll refresh jobs for local activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `ba2ae5e40` | 2024-10-03 | Mark Felder | Check if a refresh is permitted by comparing timestamps before attempting to insert an Oban job | pending |  | Review against local BE/FE behavior, then update this row. |
| `fa8de790d` | 2024-10-03 | Mark Felder | Remove test superceded by logic change | pending |  | Review against local BE/FE behavior, then update this row. |
| `b854e3836` | 2024-10-03 | Mark Felder | Remove pattern that can never match | pending |  | Review against local BE/FE behavior, then update this row. |
| `a3038aa6a` | 2024-10-03 | Mark Felder | Increase poll refresh interval to 120 seconds | pending |  | Review against local BE/FE behavior, then update this row. |
| `03a6e33b8` | 2024-10-09 | Mark Felder | Skip the final refresh job if the activity is local | pending |  | Review against local BE/FE behavior, then update this row. |
| `5b04c2bf1` | 2024-10-09 | Mark Felder | Test the final refresh behavior of a PollWorker poll_end job | pending |  | Review against local BE/FE behavior, then update this row. |
| `3f3f8bc57` | 2024-10-10 | feld | Merge branch 'poll-refresh' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f758b6e37` | 2024-10-08 | tusooa | Fix incoming Blocks being rejected | pending |  | Review against local BE/FE behavior, then update this row. |
| `dd7f699d4` | 2024-10-11 | feld | Merge branch 'tusooa/3331-fix-incoming-block' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4533f171a` | 2024-10-03 | Alex Gleason | Add RemoteReportPolicy to reject reports without enough information | pending |  | Review against local BE/FE behavior, then update this row. |
| `b7c91876d` | 2024-10-03 | Alex Gleason | RemoteReportPolicy: add `:reject_all` option, fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `fd83b86b9` | 2024-10-03 | Mint | RemoteReportPolicy: add `reject_third_party` option | pending |  | Review against local BE/FE behavior, then update this row. |
| `55612cb8e` | 2024-10-03 | Alex Gleason | mix format | pending |  | Review against local BE/FE behavior, then update this row. |
| `48af6850f` | 2024-10-03 | Mint | RemoteReportPolicy: Fix third-party report detection | pending |  | Review against local BE/FE behavior, then update this row. |
| `eb971aa02` | 2024-10-03 | Mint | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `4557cd960` | 2024-10-11 | feld | Merge branch 'remote-report-policy' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `23f78c757` | 2024-10-11 | Mark Felder | Refactor password changes to go through Pleroma.Web.Auth so they can be supported by the different auth backends | pending |  | Review against local BE/FE behavior, then update this row. |
| `67cc38b5a` | 2024-10-11 | Mark Felder | Support password changes for LDAP auth backend | pending |  | Review against local BE/FE behavior, then update this row. |
| `ff039f953` | 2024-10-11 | Mark Felder | Add example OpenLDAP ldif to enable users to change their own passwords | pending |  | Review against local BE/FE behavior, then update this row. |
| `6bc70b8b2` | 2024-10-11 | Mark Felder | Add change_password/3 to LDAP module | pending |  | Review against local BE/FE behavior, then update this row. |
| `1da057e6a` | 2024-10-11 | Mark Felder | Reorganize the LDAP module | pending |  | Review against local BE/FE behavior, then update this row. |
| `b6a951cfb` | 2024-10-11 | Mark Felder | LDAP password changing changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `639016bde` | 2024-10-11 | feld | Merge branch 'refactor-change-password' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f048637b4` | 2024-10-21 | Mark Jaroski | Some tidying and grammer improvements for these installation docs, based on my experience installing Pleroma on Ubuntu 24.04 a few minutes ago. | pending |  | Review against local BE/FE behavior, then update this row. |
| `78dc59269` | 2024-10-21 | tusooa | Merge branch 'develop' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e1296737a` | 2024-10-25 | Mark Felder | Disable busywaits in releases | pending |  | Review against local BE/FE behavior, then update this row. |
| `7e3532a07` | 2024-10-25 | feld | Merge branch 'release-tuning' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `37b1192b7` | 2024-10-09 | fzorb fzorbius | Should probably also include vips in the media/graphics packages section, as you need it to compile some library | pending |  | Review against local BE/FE behavior, then update this row. |
| `dc6362f71` | 2024-10-25 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb3403abd` | 2024-10-25 | feld | Merge branch 'fzdevelop' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `63c6dacfc` | 2024-10-25 | Mark Felder | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `00b6a586a` | 2024-10-25 | Mark Felder | OpenBSD needs libvips | pending |  | Review against local BE/FE behavior, then update this row. |
| `2d591aeda` | 2024-10-25 | feld | Merge branch 'fzdevelop' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7d5ef8173` | 2024-10-27 | Mark Felder | Fix /api/v2/media returning the wrong status code for media processed synchronously | pending |  | Review against local BE/FE behavior, then update this row. |
| `6099a94db` | 2024-10-28 | feld | Merge branch 'mediav2-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8d2410948` | 2024-10-31 | Lain Soykaf | Mix: Update version | pending |  | Review against local BE/FE behavior, then update this row. |
| `d2de251c4` | 2024-10-29 | Mark Felder | Pleroma.Upload.Filter.Dedupe: sharding directory structure | pending |  | Review against local BE/FE behavior, then update this row. |
| `ebea518c8` | 2024-11-12 | Lain Soykaf | B DedupeTest: Add explicit test for the sharding structure | pending |  | Review against local BE/FE behavior, then update this row. |
| `f7bf9a8c8` | 2024-11-12 | lain | Merge branch 'dedupe-sharding' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0c41d986d` | 2024-10-06 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Metadata: Do not include .atom feed links for remote accounts | pending |  | Review against local BE/FE behavior, then update this row. |
| `ee3ab8b62` | 2024-11-12 | lain | Merge branch 'atom-tag' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7dd3a4d86` | 2024-09-24 | Haelwenn (lanodan) Monnier | push: make vapid_config fallback to empty array | pending |  | Review against local BE/FE behavior, then update this row. |
| `91b26c683` | 2024-11-12 | lain | Merge branch 'fix/vapid_keyword_fallback' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1e9edccab` | 2024-11-12 | Codimp | Translated using Weblate (French) | pending |  | Review against local BE/FE behavior, then update this row. |
| `a815feb29` | 2024-11-12 | lain | Merge branch 'weblate' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `35bd19773` | 2024-10-02 | tusooa | Fix nonexisting user will not generate metadata for search engine opt-out | pending |  | Review against local BE/FE behavior, then update this row. |
| `6941c47ac` | 2024-11-12 | lain | Merge branch 'develop' into 'tusooa/se-opt-out' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8b31316d2` | 2024-11-12 | lain | Merge branch 'tusooa/se-opt-out' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `60ec42cb9` | 2024-10-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add metadata provider for ActivityPub alternate links | pending |  | Review against local BE/FE behavior, then update this row. |
| `5b3e4cf49` | 2024-11-12 | Lain Soykaf | B Providers/ActivityPub: Ensure that nothing explodes on unexpected input. | pending |  | Review against local BE/FE behavior, then update this row. |
| `4626a9280` | 2024-11-12 | lain | Merge branch 'activity-pub-metadata' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `23e5eed4e` | 2024-09-19 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Include session scopes in TokenView | pending |  | Review against local BE/FE behavior, then update this row. |
| `2baa9b007` | 2024-11-12 | Lain Soykaf | Merge branch 'develop' into pleroma-token-view-scopes | pending |  | Review against local BE/FE behavior, then update this row. |
| `29b048d35` | 2024-11-12 | Lain Soykaf | B TwitterAPI/ControllerTest: Actually test the keys | pending |  | Review against local BE/FE behavior, then update this row. |
| `62bbed1e5` | 2024-11-12 | lain | Merge branch 'token-view-scopes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0c3b71e1c` | 2024-11-13 | Haelwenn (lanodan) Monnier | mix.lock: bump fast_html to 2.3.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `83b866b25` | 2024-11-13 | lain | Merge branch 'bump-lexbor' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3e4768efc` | 2024-08-04 | Mark Felder | Revert "Remove invalid test" | pending |  | Review against local BE/FE behavior, then update this row. |
| `8c91fd878` | 2024-08-04 | Mark Felder | Fix Mastodon WebSocket authentication | pending |  | Review against local BE/FE behavior, then update this row. |
| `dcb0c4777` | 2024-11-13 | lain | Merge branch 'mastodon-websocket-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0d8c2827e` | 2024-11-13 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into release/2.8.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `551534f3e` | 2024-11-21 | Lain Soykaf | B ReleaseTasks: Fix task module finding. | pending |  | Review against local BE/FE behavior, then update this row. |
| `14dbf789b` | 2024-11-21 | Lain Soykaf | Linting | pending |  | Review against local BE/FE behavior, then update this row. |
| `2482d5615` | 2024-11-21 | lain | Merge branch 'fix-module-search-in-pleroma-ctl' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c9f9ec04c` | 2024-11-21 | Mint | Meilisearch: use PUT method for indexing Mix task | pending |  | Review against local BE/FE behavior, then update this row. |
| `d65f768b5` | 2024-11-21 | Mint | Meilisearch: stop attempting to index posts with nil date | pending |  | Review against local BE/FE behavior, then update this row. |
| `3a82a51a6` | 2024-11-21 | Mint | Docs: fix OTP mix task command for Meilisearch | pending |  | Review against local BE/FE behavior, then update this row. |
| `af7de4c17` | 2024-11-21 | Mint | Changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `da7132cab` | 2024-11-21 | Mint | Remove unused import | pending |  | Review against local BE/FE behavior, then update this row. |
| `462a6a200` | 2024-11-21 | Mint | Revert "Docs: fix OTP mix task command for Meilisearch" | pending |  | Review against local BE/FE behavior, then update this row. |
| `d92d6132f` | 2024-11-21 | lain | Merge branch 'meilisearch/misc-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ced6b10c7` | 2024-11-26 | feld | Merge branch 'swoosh-mailgun' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2977779e9` | 2024-11-26 | feld | Merge branch 'well-known' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a6e97c497` | 2024-11-26 | feld | Merge branch 'following-state-bug' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f45f17b5f` | 2024-11-26 | lain | Merge branch 'follow-validator' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `53c2d2cd8` | 2024-11-26 | lain | Merge branch 'mastodon-websocket-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6a0883e5d` | 2024-11-26 | feld | Merge branch 'bugfix-truncate-remote-user-fields' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7bb2dccc0` | 2024-11-26 | Haelwenn (lanodan) Monnier | Version 2.7.1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `31487e5be` | 2024-11-26 | Haelwenn | Merge branch 'release/2.7.1' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3a8e24fed` | 2024-11-26 | Haelwenn (lanodan) Monnier | Merge remote-tracking branch 'pleroma/stable' into mergeback/2.7.1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `36f8b924a` | 2024-11-27 | lain | Merge branch 'mergeback/2.7.1' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3f98c8bd1` | 2024-11-27 | kPherox | fix: skip directory entries | pending |  | Review against local BE/FE behavior, then update this row. |
| `16027b769` | 2024-11-27 | Haelwenn | Merge branch 'fix/install-frontend-in-otp27' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8c6b3d3ce` | 2024-11-28 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into release/2.8.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `b51f5a84e` | 2024-12-09 | tusooa | Verify a local Update sent through AP C2S so users can only update their own objects | pending |  | Review against local BE/FE behavior, then update this row. |
| `c0fdd0e2c` | 2024-12-09 | Lain Soykaf | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `1170dfdd4` | 2024-12-19 | lain | Merge branch 'release/2.8.0' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `64660423c` | 2024-12-19 | lain | Merge branch 'mergeback/2.8.0' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `89e92121c` | 2024-12-20 | Lain Soykaf | CI: Allow failure for non-musl arm for now | pending |  | Review against local BE/FE behavior, then update this row. |
| `a902b53b2` | 2024-12-20 | lain | Merge branch '2.8.0-release-fix' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7dc90f5ea` | 2024-12-20 | Lain Soykaf | Switch release builder to hexpm images (mostly) | pending |  | Review against local BE/FE behavior, then update this row. |
| `6f3d82e2a` | 2024-12-20 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `fe3e61f6e` | 2024-12-21 | lain | Merge branch 'maint/hexpm-images' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `138ead985` | 2024-12-21 | lain | Merge branch 'mergeback/2.8.0-image-fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `855294bb3` | 2025-01-09 | mkljczk | Link to exported outbox/followers/following collections in backup actor.json | pending |  | Review against local BE/FE behavior, then update this row. |
| `1bebc900e` | 2025-01-18 | mkljczk | Merge branch 'backup-links' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `222617189` | 2025-01-21 | Lain Soykaf | MediaProxyController: Use 301 for permanent redirects | pending |  | Review against local BE/FE behavior, then update this row. |
| `4461cc984` | 2025-01-21 | Haelwenn | Merge branch 'proxy-redirect' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `38b17933e` | 2025-01-19 | mkljczk | Include "published" in actor view | pending |  | Review against local BE/FE behavior, then update this row. |
| `f2c612d4a` | 2025-01-21 | mkljczk | Merge branch 'actor-published' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4128ea394` | 2025-01-21 | mkljczk | description.exs: Remove suggestion referencing a deleted module | pending |  | Review against local BE/FE behavior, then update this row. |
| `acced73e5` | 2025-01-21 | lain | Merge branch 'description' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8cd771687` | 2025-01-28 | mkljczk | Fix Mastodon incoming edits with inlined "likes" | pending |  | Review against local BE/FE behavior, then update this row. |
| `011d70df7` | 2025-01-28 | mkljczk | Merge branch 'fix-mastodon-edits' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `81ab90646` | 2025-01-30 | Lain Soykaf | AnalyzeMetadata: Don't crash on grayscale image blurhash | pending |  | Review against local BE/FE behavior, then update this row. |
| `ebd827891` | 2025-01-30 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `a1f4da7ae` | 2025-01-30 | lain | Merge branch '3355-vips-blurhash' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d905fa0ad` | 2025-02-17 | mkljczk | Allow incoming "Listen" activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `31e3b9864` | 2025-02-17 | mkljczk | Merge branch 'fix-incoming-scrobbles' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f26509bf1` | 2025-02-21 | Mark Felder | Fix missing check for domain presence in rich media ignore_host configuration | pending |  | Review against local BE/FE behavior, then update this row. |
| `ce3a2b49f` | 2025-02-22 | feld | Merge branch 'feld/emailed-patch' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0d7d6ebeb` | 2025-02-22 | Lain Soykaf | Cheatsheet: Use the correct section | pending |  | Review against local BE/FE behavior, then update this row. |
| `fe3c72f7a` | 2025-02-22 | lain | Merge branch 'docs-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c94c6eac2` | 2024-12-30 | floatingghost | Remerge of hashtag following (#341) | pending |  | Review against local BE/FE behavior, then update this row. |
| `bdb9f888d` | 2024-12-30 | FloatingGhost | Add /api/v1/followed_tags | pending |  | Review against local BE/FE behavior, then update this row. |
| `ddf5bfc99` | 2024-12-30 | mkljczk | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `f565cf2b5` | 2024-12-30 | mkljczk | update spec | pending |  | Review against local BE/FE behavior, then update this row. |
| `36b71733a` | 2024-12-30 | mkljczk | fix alias ordering | pending |  | Review against local BE/FE behavior, then update this row. |
| `aa74c8744` | 2024-12-30 | mkljczk | fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `801a2256f` | 2025-02-22 | lain | Merge branch 'follow-hashtags' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4745a4139` | 2023-08-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Allow to specify post language | pending |  | Review against local BE/FE behavior, then update this row. |
| `049045cf2` | 2023-08-11 | Haelwenn | Apply lanodan's suggestion | pending |  | Review against local BE/FE behavior, then update this row. |
| `04c8f6b4d` | 2023-08-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add ObjectValidators.LanguageCode type | pending |  | Review against local BE/FE behavior, then update this row. |
| `366559c5a` | 2023-08-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Make status.language == nil for 'und' value | pending |  | Review against local BE/FE behavior, then update this row. |
| `b430b805c` | 2023-08-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Lint | pending |  | Review against local BE/FE behavior, then update this row. |
| `69d53a623` | 2023-08-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Rename test | pending |  | Review against local BE/FE behavior, then update this row. |
| `47ba7d346` | 2023-08-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Remove test | pending |  | Review against local BE/FE behavior, then update this row. |
| `edc8689d9` | 2023-08-19 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Move `maybe_add_language` to CommonFixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `62340b50b` | 2023-08-19 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Move maybe_add_content_map out of Transmogrifier, use code from tusooa's branch for MapOfString | pending |  | Review against local BE/FE behavior, then update this row. |
| `c160ef7b6` | 2023-08-20 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Remove test | pending |  | Review against local BE/FE behavior, then update this row. |
| `b52d189fc` | 2023-08-31 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Move is_good_locale_code? to object validator | pending |  | Review against local BE/FE behavior, then update this row. |
| `c5ed68427` | 2023-09-07 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Rename MapOfString to ContentLanguageMap | pending |  | Review against local BE/FE behavior, then update this row. |
| `a3b17dac0` | 2023-09-11 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Rename test | pending |  | Review against local BE/FE behavior, then update this row. |
| `b6bae2d31` | 2023-12-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into post-languages | pending |  | Review against local BE/FE behavior, then update this row. |
| `51aef6b78` | 2023-12-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add language from activity context in ObjectValidator | pending |  | Review against local BE/FE behavior, then update this row. |
| `250a4873a` | 2024-01-19 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'develop' into 'post-languages' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e798be90a` | 2024-02-02 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'develop' into 'post-languages' | pending |  | Review against local BE/FE behavior, then update this row. |
| `05cb931e4` | 2024-02-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into post-languages | pending |  | Review against local BE/FE behavior, then update this row. |
| `a6e066a77` | 2024-03-07 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix adding language to json ld header, add transmogrifier test | pending |  | Review against local BE/FE behavior, then update this row. |
| `03d4e7eec` | 2024-03-07 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into post-languages | pending |  | Review against local BE/FE behavior, then update this row. |
| `7620b520c` | 2024-05-18 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into post-languages | pending |  | Review against local BE/FE behavior, then update this row. |
| `ad8c26f6c` | 2024-07-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into post-languages | pending |  | Review against local BE/FE behavior, then update this row. |
| `a40bf5d24` | 2024-07-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix good_locale_code?/1 regex | pending |  | Review against local BE/FE behavior, then update this row. |
| `3e5517e7b` | 2024-08-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into post-languages | pending |  | Review against local BE/FE behavior, then update this row. |
| `ea01b5934` | 2025-02-17 | mkljczk | Merge remote-tracking branch 'origin/develop' into post-languages | pending |  | Review against local BE/FE behavior, then update this row. |
| `120fbbc97` | 2025-02-17 | mkljczk | Include contentMap in outgoing posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `04af8bfd9` | 2025-02-17 | mkljczk | credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `ce4c07cc2` | 2025-02-17 | mkljczk | update test | pending |  | Review against local BE/FE behavior, then update this row. |
| `6f48ade41` | 2025-02-22 | lain | Merge branch 'post-languages' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7bdeb9a1e` | 2025-02-28 | Mark Felder | Fix OpenGraph/TwitterCard meta tag ordering for posts with multiple attachments | pending |  | Review against local BE/FE behavior, then update this row. |
| `63663ac88` | 2025-02-28 | feld | Merge branch 'twittercard-image-order' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2c9d071aa` | 2025-02-28 | Mark Felder | Retire MRFs DNSRBL, FODirectReply, and QuietReply | pending |  | Review against local BE/FE behavior, then update this row. |
| `b77085090` | 2025-03-01 | feld | Merge branch 'retire-mrfs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `cb073a9cd` | 2025-02-28 | Mark Felder | Rich Media Parser should use first og:image | pending |  | Review against local BE/FE behavior, then update this row. |
| `2137b681d` | 2025-02-28 | Mark Felder | Fix image URLs in TwitterCard parser test | pending |  | Review against local BE/FE behavior, then update this row. |
| `ac0882e34` | 2025-02-28 | Mark Felder | Filter the parsed OpenGraph/Twittercard tags and only retain the ones we intend to use. | pending |  | Review against local BE/FE behavior, then update this row. |
| `a8e863e0d` | 2025-03-01 | feld | Merge branch 'rich-media-ordering' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0f5ac7e86` | 2025-02-27 | Oneric | Add SafeZip module | pending |  | Review against local BE/FE behavior, then update this row. |
| `b89070a6a` | 2025-02-27 | Lain Soykaf | SafeZip: Add tests. | pending |  | Review against local BE/FE behavior, then update this row. |
| `2fcb90f36` | 2025-02-27 | Lain Soykaf | Emoji, Pack, Backup, Frontend: Use SafeZip | pending |  | Review against local BE/FE behavior, then update this row. |
| `bf134664b` | 2025-02-28 | Lain Soykaf | PackTest: Add test for skipping emoji | pending |  | Review against local BE/FE behavior, then update this row. |
| `ca3c2a4ff` | 2025-02-28 | tusooa | Verify a local Update sent through AP C2S so users can only update their own objects | pending |  | Review against local BE/FE behavior, then update this row. |
| `ad953143b` | 2024-09-15 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Require HTTP signatures (if enabled) for routes used by both C2S and S2S AP API | pending |  | Review against local BE/FE behavior, then update this row. |
| `309d22aca` | 2024-09-16 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Allow disabling C2S ActivityPub API | pending |  | Review against local BE/FE behavior, then update this row. |
| `76cfc6127` | 2024-09-17 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into ensure-authorized-fetch | pending |  | Review against local BE/FE behavior, then update this row. |
| `4604f2944` | 2025-03-01 | Lain Soykaf | Merge branch 'pleroma-ensure-authorized-fetch' into security-2.9 | pending |  | Review against local BE/FE behavior, then update this row. |
| `d6a136f82` | 2025-03-01 | Lain Soykaf | Config: Deactivate client api by default | pending |  | Review against local BE/FE behavior, then update this row. |
| `88ee38530` | 2025-03-01 | Lain Soykaf | Transmogrifier: Strip internal fields | pending |  | Review against local BE/FE behavior, then update this row. |
| `706bfffcd` | 2025-03-01 | Lain Soykaf | Linting | pending |  | Review against local BE/FE behavior, then update this row. |
| `13a88bd1a` | 2025-03-01 | Oneric | Register APNG MIME type | pending |  | Review against local BE/FE behavior, then update this row. |
| `32acdf093` | 2025-03-01 | Lain Soykaf | Merge branch 'security-2.9' into release/2.9.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `e88eb2444` | 2025-03-01 | Lain Soykaf | Mix: Bump version to 2.9.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `a24e894b2` | 2025-03-01 | Lain Soykaf | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `79cbc74aa` | 2025-03-01 | Lain Soykaf | Linting | pending |  | Review against local BE/FE behavior, then update this row. |
| `cd5f01820` | 2025-03-01 | Lain Soykaf | SafeZip Test: Skip failing CI tests for the release (tests work fine locally) | pending |  | Review against local BE/FE behavior, then update this row. |
| `af6d5470d` | 2025-03-01 | lain | Merge branch 'release/2.9.0' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `16944eb9d` | 2025-03-01 | lain | Merge branch 'stable' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `bc722623b` | 2025-03-02 | mkljczk | remove changelog entries from changelog.d | pending |  | Review against local BE/FE behavior, then update this row. |
| `a7b6d3c1d` | 2025-03-02 | lain | Merge branch 'changelog' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7bfa3bf28` | 2025-03-02 | mkljczk | Include my frontend in available frontends | pending |  | Review against local BE/FE behavior, then update this row. |
| `b2640f0dc` | 2025-03-02 | lain | Merge branch 'pl-fe' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a184eccde` | 2025-03-02 | Lain Soykaf | Safezip: Fix test (issue was a difference in file ordering between otp26 and otp27) | pending |  | Review against local BE/FE behavior, then update this row. |
| `906c3ab30` | 2025-03-02 | lain | Merge branch 'fix-safezip' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `be3bbe586` | 2025-03-08 | Mikka van der Velde | Edit debian_based_en.md | pending |  | Review against local BE/FE behavior, then update this row. |
| `5cf0321bc` | 2025-03-08 | Mikka van der Velde | Add new file | pending |  | Review against local BE/FE behavior, then update this row. |
| `35033b6f3` | 2025-03-08 | Mikka van der Velde | Edit debian-distro-docs-pleromaBE.fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `5ffc7d8c9` | 2025-03-08 | lain | Merge branch 'develop' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a92b1fbde` | 2025-02-23 | Lain Soykaf | UserRelationshipTest: Don't use Mock. | pending |  | Review against local BE/FE behavior, then update this row. |
| `263b02ffc` | 2025-02-23 | Lain Soykaf | Tests: Use StaticConfig when possible. | pending |  | Review against local BE/FE behavior, then update this row. |
| `229ce66a8` | 2025-02-23 | Lain Soykaf | DataCase: By default, stub DateTime. | pending |  | Review against local BE/FE behavior, then update this row. |
| `4b3a98566` | 2025-02-24 | Lain Soykaf | PackTest: Make test more resilient | pending |  | Review against local BE/FE behavior, then update this row. |
| `1ebbab161` | 2025-02-24 | Lain Soykaf | AppTest: Make test more resilient. | pending |  | Review against local BE/FE behavior, then update this row. |
| `bee027e51` | 2025-02-25 | Lain Soykaf | DatabaseTest: Include user_follows_hashtag in expected tables | pending |  | Review against local BE/FE behavior, then update this row. |
| `5851d787b` | 2025-02-25 | Lain Soykaf | Merge branch and resolve conflict in database_test.exs | pending |  | Review against local BE/FE behavior, then update this row. |
| `ee291f08e` | 2025-02-25 | Lain Soykaf | AnonymizeFilename: Asyncify | pending |  | Review against local BE/FE behavior, then update this row. |
| `c31fabdeb` | 2025-02-25 | Lain Soykaf | Mogrify/Mogrifun: Asyncify | pending |  | Review against local BE/FE behavior, then update this row. |
| `fd128ec7c` | 2025-02-25 | Lain Soykaf | ConfigControllerTest: Fix it! | pending |  | Review against local BE/FE behavior, then update this row. |
| `70a784e16` | 2025-02-25 | Lain Soykaf | AutolinkerToLinkifyTest: Asyncify | pending |  | Review against local BE/FE behavior, then update this row. |
| `edcd81673` | 2025-03-10 | Lain Soykaf | Merge branch 'assorted-test-fixes' into secfix | pending |  | Review against local BE/FE behavior, then update this row. |
| `b469b9d9d` | 2025-03-10 | Lain Soykaf | . | pending |  | Review against local BE/FE behavior, then update this row. |
| `1dd9ba5d6` | 2025-03-10 | Lain Soykaf | Sanitize media uploads. | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1309bdb4` | 2025-03-10 | Lain Soykaf | More fixes for InstanceStatic | pending |  | Review against local BE/FE behavior, then update this row. |
| `d9ae9b676` | 2025-03-11 | Lain Soykaf | InstanceStatic: Extra-sanitize emoji | pending |  | Review against local BE/FE behavior, then update this row. |
| `c14365336` | 2025-03-11 | Lain Soykaf | ReverseProxy: Sanitize content. | pending |  | Review against local BE/FE behavior, then update this row. |
| `577b7cb06` | 2025-03-11 | Lain Soykaf | StealEmojiPolicy: Sanitise emoji names. | pending |  | Review against local BE/FE behavior, then update this row. |
| `adb5cb96d` | 2025-03-11 | Lain Soykaf | Object.Fetcher: Don't do cross-site redirects. | pending |  | Review against local BE/FE behavior, then update this row. |
| `b0c2ec5fb` | 2025-03-11 | Lain Soykaf | Fetcher Tests: Add tests validating the content-type | pending |  | Review against local BE/FE behavior, then update this row. |
| `51c1d6fb2` | 2025-03-11 | Lain Soykaf | Containment: Never fetch locally | pending |  | Review against local BE/FE behavior, then update this row. |
| `2293d0826` | 2025-03-11 | Lain Soykaf | Tests: Fix tests. | pending |  | Review against local BE/FE behavior, then update this row. |
| `3c2b51c7c` | 2025-03-11 | Lain Soykaf | Changelog: Add missing changelog entries | pending |  | Review against local BE/FE behavior, then update this row. |
| `0a93a7b0c` | 2025-03-11 | Lain Soykaf | Mix: Update version | pending |  | Review against local BE/FE behavior, then update this row. |
| `4c8a8a4b6` | 2025-03-11 | Lain Soykaf | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `5ce612b27` | 2025-03-11 | Lain Soykaf | Linting | pending |  | Review against local BE/FE behavior, then update this row. |
| `66687bedd` | 2025-03-11 | lain | Merge branch 'release/2.9.1' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f25ef1aa7` | 2025-03-11 | lain | Merge branch 'stable' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `bee8b64fa` | 2025-03-14 | Lain Soykaf | Migrations: Add activities_actor_type index | pending |  | Review against local BE/FE behavior, then update this row. |
| `ad79912a0` | 2025-03-14 | Lain Soykaf | Create the index concurrently | pending |  | Review against local BE/FE behavior, then update this row. |
| `016df5093` | 2025-03-16 | Lain Soykaf | Config: Use advisory lock | pending |  | Review against local BE/FE behavior, then update this row. |
| `7328235c6` | 2025-03-18 | lain | Merge branch 'speed-improvement' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `32994bb9c` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Language detection | pending |  | Review against local BE/FE behavior, then update this row. |
| `9932aeffc` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add test | pending |  | Review against local BE/FE behavior, then update this row. |
| `80dbbd550` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Detect language for incoming posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `17d885fed` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix fasttext for multiline posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `8bec926be` | 2024-04-25 | Alex Gleason | LanguageDetector: strip non-language text to (hopefully) improve accuracy | pending |  | Review against local BE/FE behavior, then update this row. |
| `91f42781d` | 2024-04-25 | Alex Gleason | ActivityDraft: detect language from content_html so it can strip links | pending |  | Review against local BE/FE behavior, then update this row. |
| `df0d84833` | 2024-04-25 | Alex Gleason | mix format | pending |  | Review against local BE/FE behavior, then update this row. |
| `fa24e0ff2` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `799dc1773` | 2024-05-18 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into language-detection | pending |  | Review against local BE/FE behavior, then update this row. |
| `9d9bc74e9` | 2024-08-27 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Expose language detection in features | pending |  | Review against local BE/FE behavior, then update this row. |
| `2b1ef1bbd` | 2025-02-22 | mkljczk | Merge remote-tracking branch 'origin/develop' into language-detection | pending |  | Review against local BE/FE behavior, then update this row. |
| `d7f9d30b2` | 2025-02-22 | mkljczk | Merge downstream changes | pending |  | Review against local BE/FE behavior, then update this row. |
| `3b74d1314` | 2025-02-22 | mkljczk | Do not call LanguageDetector when not language is provided | pending |  | Review against local BE/FE behavior, then update this row. |
| `ccc6f2b28` | 2025-02-25 | Lain Soykaf | Docs: Add mox testing info | pending |  | Review against local BE/FE behavior, then update this row. |
| `edfb1deb1` | 2025-02-25 | Lain Soykaf | Application: Don't verify requirements during test at startup. | pending |  | Review against local BE/FE behavior, then update this row. |
| `35814de0d` | 2025-02-25 | Lain Soykaf | LanguageDetectorTests: Switch to mox | pending |  | Review against local BE/FE behavior, then update this row. |
| `1e35ea785` | 2025-02-25 | Lain Soykaf | LanguageDetector: Use StaticStubbedConfigMock. | pending |  | Review against local BE/FE behavior, then update this row. |
| `584e4efaa` | 2025-02-25 | Lain Soykaf | mox_testing.md: Update with more information | pending |  | Review against local BE/FE behavior, then update this row. |
| `7ccf33952` | 2025-02-25 | Lain Soykaf | LanguageDetectorTest: Rename | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3e310d76` | 2025-02-25 | mkljczk | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `fa76bb66f` | 2025-03-11 | mkljczk | Merge remote-tracking branch 'origin/develop' into language-detection | pending |  | Review against local BE/FE behavior, then update this row. |
| `6e1223a1e` | 2025-03-19 | lain | Merge branch 'language-detection' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7763b9a87` | 2025-03-19 | Mark Felder | Truncate the length of Rich Media title and description fields | pending |  | Review against local BE/FE behavior, then update this row. |
| `7107901f6` | 2025-03-19 | feld | Merge branch 'truncate-rich-media' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `638d047a5` | 2025-03-19 | Mark Felder | Fix releases by not relying on Mix | pending |  | Review against local BE/FE behavior, then update this row. |
| `3e802240b` | 2025-03-19 | feld | Merge branch 'fix-releases' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `557a7d736` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | WIP Translation backends support | implemented | `lib/pleroma/language/translation.ex`, `lib/pleroma/language/translation/*` | Local BE has translation-provider infrastructure plus DeepL, LibreTranslate, OpenTranslate, Mozhi, and translateLocally support. |
| `90f91168f` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Expose translation service availability | implemented | `lib/pleroma/web/mastodon_api/views/instance_view.ex`, `config/description.exs` | Local instance metadata exposes translation availability/configuration. |
| `90f590788` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add tests | not-applicable | `test/pleroma/web/mastodon_api/controllers/status_controller_test.exs` | Upstream test-only commit; local translation behavior has diverged with additional providers. |
| `aa429f6e6` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Do not translate non-public statuses | implemented | `lib/pleroma/web/mastodon_api/controllers/status_controller.ex` | Local translation access is scoped by status visibility. |
| `066ec8fe9` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Update description.exs | implemented | `config/description.exs` | Translation and related provider settings are described in local config metadata. |
| `2b739faa7` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Rename | superseded | `lib/pleroma/language/translation.ex` | Local translation modules use the current Unfathomably/Pleroma naming after provider expansion. |
| `fedae008c` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Deepl: use :base_url | pending |  | Review against local BE/FE behavior, then update this row. |
| `f0eb8e0b0` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `28f8bb00d` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Add supported languages list to /api/v2/instance | pending |  | Review against local BE/FE behavior, then update this row. |
| `4696487f1` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Fix instance view | pending |  | Review against local BE/FE behavior, then update this row. |
| `7fca35f4f` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | InstanceView: Move supported languages to pleroma.metadata | pending |  | Review against local BE/FE behavior, then update this row. |
| `010c23e72` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Include unspecified variants in target languages list for DeepL | pending |  | Review against local BE/FE behavior, then update this row. |
| `f954f98fb` | 2024-04-25 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Implement /api/v1/instance/translation_languages | pending |  | Review against local BE/FE behavior, then update this row. |
| `b53abd9d7` | 2024-04-26 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `3893311bd` | 2024-04-27 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into translate-posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `d667049ca` | 2024-05-18 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into translate-posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `b07fd324f` | 2024-06-12 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into translate-posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `b430093ca` | 2024-08-02 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Translation: Rename target language param | pending |  | Review against local BE/FE behavior, then update this row. |
| `f7a751729` | 2024-08-02 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge remote-tracking branch 'origin/develop' into translate-posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `3ee8d0eea` | 2024-08-22 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Merge branch 'post-languages' into translate-posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `d818a3d76` | 2024-12-30 | mkljczk | Merge remote-tracking branch 'origin/develop' into translate-posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `013c60e13` | 2025-02-22 | mkljczk | Merge remote-tracking branch 'origin/develop' into translate-posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `d0dac30ac` | 2025-02-22 | mkljczk | Merge downstream changes | pending |  | Review against local BE/FE behavior, then update this row. |
| `22bbe55b5` | 2025-02-22 | mkljczk | fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `08de5f94e` | 2025-03-19 | mkljczk | Merge remote-tracking branch 'origin/develop' into translate-posts | pending |  | Review against local BE/FE behavior, then update this row. |
| `25a3ee225` | 2025-03-19 | mkljczk | InstanceView: do not repeat information | pending |  | Review against local BE/FE behavior, then update this row. |
| `81960dccf` | 2025-03-20 | lain | Merge branch 'translate-posts' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `fc7ca2ccf` | 2025-03-18 | Lain Soykaf | Federator: More specific logging for rejections | pending |  | Review against local BE/FE behavior, then update this row. |
| `e19ca7606` | 2025-03-18 | Lain Soykaf | Transmogrifier: Also accept mitra emoji likes. | pending |  | Review against local BE/FE behavior, then update this row. |
| `ef216c922` | 2025-03-18 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `950bf6076` | 2025-03-19 | Lain Soykaf | LikeHandlingTest: Add test for invalid content | pending |  | Review against local BE/FE behavior, then update this row. |
| `f9bff8f5e` | 2025-03-19 | Lain Soykaf | Transmogrifier: Keep likes as likes if the content is obviously wrong | pending |  | Review against local BE/FE behavior, then update this row. |
| `254b31bf1` | 2025-03-20 | lain | Merge branch 'more-emoji-likes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f60a1e7d4` | 2025-03-31 | Mark Felder | Set PATH in the FreeBSD rc script to avoid failures starting the service | pending |  | Review against local BE/FE behavior, then update this row. |
| `2651058fa` | 2025-04-01 | feld | Merge branch 'fix-freebsd-rc' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4d4174c33` | 2025-03-28 | Nicole MikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | fix a few typos | pending |  | Review against local BE/FE behavior, then update this row. |
| `4f78a9142` | 2025-04-02 | mkljczk | Merge branch 'typo' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `93aa563cf` | 2025-04-02 | Moon Man | implemented | pending |  | Review against local BE/FE behavior, then update this row. |
| `8322134a2` | 2025-04-02 | lain | Edit siteinfo-baseurls.add | pending |  | Review against local BE/FE behavior, then update this row. |
| `1775a4db0` | 2025-04-02 | lain | Merge branch 'siteinfo-baseurls' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1266b180b` | 2025-04-10 | Mark Felder | Improved performance of status search queries using the default GIN index | pending |  | Review against local BE/FE behavior, then update this row. |
| `99fbe0418` | 2025-04-10 | feld | Merge branch 'gins-tonic' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ded40182b` | 2025-05-05 | Lain Soykaf | Public getting stripped from unlisted activity CC: Add possible tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `63afd9a22` | 2025-05-07 | mkljczk | Fix condition for moderation log force_password_reset action | pending |  | Review against local BE/FE behavior, then update this row. |
| `69c80cf90` | 2025-05-18 | mkljczk | Merge branch 'admin-api-log-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6b38ec310` | 2025-05-22 | Nicole MikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Fix 'Create a user' description in admin api docs | pending |  | Review against local BE/FE behavior, then update this row. |
| `25a283160` | 2025-05-23 | mkljczk | Merge branch 'admin-api-docs-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `31071973b` | 2025-05-06 | mkljczk | Fix typo in account_status function doc | pending |  | Review against local BE/FE behavior, then update this row. |
| `ccb5b8117` | 2025-05-06 | mkljczk | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `68a5c6011` | 2025-05-08 | mkljczk | another doc update | pending |  | Review against local BE/FE behavior, then update this row. |
| `4960e040c` | 2025-05-23 | mkljczk | Merge branch 'doc-typo' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `51a0cee40` | 2025-04-15 | Ekaterina Vaartis | Add expiring blocks | pending |  | Review against local BE/FE behavior, then update this row. |
| `36be0d32a` | 2025-05-29 | lain | Merge branch 'expiring-blocks' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3af969235` | 2025-03-20 | Moon Man | return json if no accept is specified | pending |  | Review against local BE/FE behavior, then update this row. |
| `edfa372fd` | 2025-03-20 | Moon Man | changelog update | pending |  | Review against local BE/FE behavior, then update this row. |
| `7624af92c` | 2025-03-20 | Moon Man | tests for webfinger | pending |  | Review against local BE/FE behavior, then update this row. |
| `43a124bb1` | 2025-03-20 | Moon Man | formatting | pending |  | Review against local BE/FE behavior, then update this row. |
| `374e8c85a` | 2025-05-29 | lain | Apply lambadalambda's suggestion(s) to 1 file(s) | pending |  | Review against local BE/FE behavior, then update this row. |
| `93ce56418` | 2025-05-29 | lain | Merge branch 'permissive-webfinger' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `53d7b205e` | 2025-05-12 | Phantasm | Elixir 1.18 <%# deprecated syntax warning | pending |  | Review against local BE/FE behavior, then update this row. |
| `25e7b12a6` | 2025-05-13 | Phantasm | Elixir 1.18 Remove seemingly unneeded cond | pending |  | Review against local BE/FE behavior, then update this row. |
| `59d17a5b2` | 2025-05-13 | Phantasm | Elixir 1.18 Move Update activity validation to separate function | pending |  | Review against local BE/FE behavior, then update this row. |
| `63cbc1208` | 2025-05-13 | Phantasm | Elixir 1.18 Replace Tuple.append/2 with Tuple.insert_at/3 | pending |  | Review against local BE/FE behavior, then update this row. |
| `5addbf39f` | 2025-05-13 | Phantasm | Elixir 1.18 Deal with :warnings_as_errors deprecation in compiler_options/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `7c13abb3d` | 2025-05-14 | Phantasm | Elixir 1.18 Use NaiveDateTime.compare/2 instead of <>= comparisons | pending |  | Review against local BE/FE behavior, then update this row. |
| `af81f7bf8` | 2025-05-14 | Phantasm | Don't use deprecated function invocation syntax | pending |  | Review against local BE/FE behavior, then update this row. |
| `a0dfa12b7` | 2025-05-24 | Phantasm | Elixir 1.18 Update supported versions for Erlang OTP and Elixir | pending |  | Review against local BE/FE behavior, then update this row. |
| `2b513fd45` | 2025-05-24 | Phantasm | Elixir 1.18 add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `286204913` | 2025-05-24 | Phantasm | Replace Elixir 1.17 with 1.18 for build unit-testing pipelines | pending |  | Review against local BE/FE behavior, then update this row. |
| `9710063fd` | 2025-06-03 | Phantasm | Apply suggestions to 2 files. | pending |  | Review against local BE/FE behavior, then update this row. |
| `0e53cb494` | 2025-06-03 | Phantasm | Remove unreachable checks for OTP < 22.2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `1be8deda7` | 2025-06-03 | Phantasm | Remove Pleroma.OTPVersion module | pending |  | Review against local BE/FE behavior, then update this row. |
| `6fa4f08e6` | 2025-06-04 | Ekaterina Vaartis | Add back String.downcase that was accidentally removed from tag_validator | pending |  | Review against local BE/FE behavior, then update this row. |
| `d95e1066b` | 2025-06-04 | Ekaterina Vaartis | Fix formatting | pending |  | Review against local BE/FE behavior, then update this row. |
| `7ddae6141` | 2025-06-04 | Ekaterina Vaartis | Change the test that assumes that a hashtag with # will remain as-is | pending |  | Review against local BE/FE behavior, then update this row. |
| `dc26f7496` | 2025-06-04 | Phantasm | Revert to previous tag_validator behavior | pending |  | Review against local BE/FE behavior, then update this row. |
| `ff69b00ea` | 2025-06-04 | Phantasm | Elixir 1.18 Update credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `8484e0942` | 2025-06-05 | vaartis | Merge branch 'elixir-1.18' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a2ad2d8d2` | 2025-06-05 | Mark Felder | Remove unused import | pending |  | Review against local BE/FE behavior, then update this row. |
| `48316d168` | 2025-06-05 | Mark Felder | Fix failing tests due to Builder.block/2 becoming Builder.block/3 with no default value | pending |  | Review against local BE/FE behavior, then update this row. |
| `db65b35ca` | 2025-06-05 | Mark Felder | Fix test Returns JSON when format is not supported (Pleroma.Web.WebFinger.WebFingerControllerTest) | pending |  | Review against local BE/FE behavior, then update this row. |
| `922696376` | 2025-06-05 | Mark Felder | Fix test fallout from most recent merges | pending |  | Review against local BE/FE behavior, then update this row. |
| `7101d8ab1` | 2025-06-06 | feld | Merge branch 'fixes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b2a716fc9` | 2024-11-12 | Phantasm | openbsd rc: replace deprecated flags, renamed to fit other service files | pending |  | Review against local BE/FE behavior, then update this row. |
| `9b71f57e3` | 2024-11-12 | Phantasm | docs openbsd: add missing vips and libmagic depends to required software | pending |  | Review against local BE/FE behavior, then update this row. |
| `cf0296bfd` | 2024-11-12 | Phantasm | docs openbsd: Add differences between otp and src, improved formatting and wording | pending |  | Review against local BE/FE behavior, then update this row. |
| `1fcf73335` | 2024-11-12 | Phantasm | docs openbsd: Add nginx guide, do not recommend httpd/relayd | pending |  | Review against local BE/FE behavior, then update this row. |
| `71c60aa9f` | 2024-11-12 | Phantasm | docs openbsd: specifically install erlang 26 due to a TLSv1.3 bug | pending |  | Review against local BE/FE behavior, then update this row. |
| `3dc2655f5` | 2024-11-12 | Phantasm | openbsd: update relayd and httpd configuration files | pending |  | Review against local BE/FE behavior, then update this row. |
| `9b3906559` | 2024-11-12 | Phantasm | openbsd: add changelogs | pending |  | Review against local BE/FE behavior, then update this row. |
| `427db3260` | 2024-11-12 | Phantasm | openbsd relayd: clarify certificate naming | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3f2d5919` | 2024-11-22 | Phantasm | docs openbsd: update install instructions for httpd/relayd | pending |  | Review against local BE/FE behavior, then update this row. |
| `0bd21084c` | 2024-11-22 | Phantasm | docs openbsd: remove firewall configuation from install instructions | pending |  | Review against local BE/FE behavior, then update this row. |
| `a21e11f58` | 2024-11-22 | Phantasm | openbsd: unify IPvX placeholders in configs | pending |  | Review against local BE/FE behavior, then update this row. |
| `79c5ca05c` | 2024-11-24 | Phantasm | docs openbsd: inherit default daemon limits and tweak them | pending |  | Review against local BE/FE behavior, then update this row. |
| `ee25acea6` | 2024-11-24 | Phantasm | docs openbsd: Fix nginx acme challenges, automatic certificate renewals in proper places | pending |  | Review against local BE/FE behavior, then update this row. |
| `df492669e` | 2024-11-24 | Phantasm | docs openbsd: proper permission for Pleroma service file | pending |  | Review against local BE/FE behavior, then update this row. |
| `b0721ddbf` | 2024-11-25 | Phantasm | docs openbsd: recommend changing pgsql auth method, remove redundant service check | pending |  | Review against local BE/FE behavior, then update this row. |
| `e0ba132bc` | 2024-11-27 | Phantasm | docs openbsd: ensure db has UTF-8 enconding | pending |  | Review against local BE/FE behavior, then update this row. |
| `3b5b3ba4f` | 2024-11-27 | Phantasm | openbsd: properly set daemon workdir, use default rc_start, set MIX_ENV in login.conf | pending |  | Review against local BE/FE behavior, then update this row. |
| `accdefb8d` | 2024-11-27 | Phantasm | openbsd httpd: use more appropriate HTTP response code for redirect | pending |  | Review against local BE/FE behavior, then update this row. |
| `49c35f8d9` | 2024-11-27 | Phantasm | dosc openbsd: add missing acquire certificate instruction for httpd | pending |  | Review against local BE/FE behavior, then update this row. |
| `a323701c3` | 2024-11-27 | Phantasm | docs openbsd: spellcheck | pending |  | Review against local BE/FE behavior, then update this row. |
| `047916445` | 2024-11-29 | Phantasm | docs openbsd: No need to switch users when creating DB | pending |  | Review against local BE/FE behavior, then update this row. |
| `0a34e3956` | 2025-02-05 | Phantasm | docs openbsd: fix certificate acquisition on nginx | pending |  | Review against local BE/FE behavior, then update this row. |
| `938686301` | 2025-06-03 | Phantasm | openbsd: update install docs for 7.7 | pending |  | Review against local BE/FE behavior, then update this row. |
| `f38123ad2` | 2025-06-06 | feld | Merge branch 'openbsd-docs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4c8a93a06` | 2025-05-19 | mkljczk | Pleroma.User: Mark some functions as private | pending |  | Review against local BE/FE behavior, then update this row. |
| `711463599` | 2025-06-06 | feld | Merge branch 'private-functions' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a817f1800` | 2025-06-05 | Phantasm | Remove forgotten Pleroma.OTPVersion usage in mix.exs | pending |  | Review against local BE/FE behavior, then update this row. |
| `8ae4ed080` | 2025-06-05 | Ekaterina Vaartis | Make the opts in ActivityPub.Builder.block optional | pending |  | Review against local BE/FE behavior, then update this row. |
| `5cd8c2363` | 2025-06-06 | feld | Merge branch 'mix-otpver' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7b69e5256` | 2025-02-23 | tusooa | Fix AssignAppUser migration OOM | pending |  | Review against local BE/FE behavior, then update this row. |
| `f38e9228e` | 2025-06-07 | feld | Merge branch 'tusooa/assign-app-user-oom' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `848836224` | 2025-06-12 | Mark Felder | Merge remote-tracking branch 'origin/develop' into unlisted-fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `27ec46814` | 2025-06-12 | Mark Felder | Revert "Public getting stripped from unlisted activity CC: Add possible tests" | pending |  | Review against local BE/FE behavior, then update this row. |
| `9f79df750` | 2025-06-12 | Mark Felder | Add test demonstrating public getting stripped from unlisted activity CC | pending |  | Review against local BE/FE behavior, then update this row. |
| `23be24b92` | 2025-06-12 | Mark Felder | Fix federation issue where Public visibility information in cc field was lost when sent to remote servers, causing posts to appear with inconsistent visibility across instances | pending |  | Review against local BE/FE behavior, then update this row. |
| `d3adc3e05` | 2025-06-12 | Mark Felder | Split this cc test into two individual cases | pending |  | Review against local BE/FE behavior, then update this row. |
| `fe6d2ecc9` | 2025-06-12 | Mark Felder | Test for unlisted but Publisher param_cc is not empty | pending |  | Review against local BE/FE behavior, then update this row. |
| `7c64bfaac` | 2025-06-12 | Mark Felder | Include public address in cc if original activity specified it and Publisher param_cc also has values | pending |  | Review against local BE/FE behavior, then update this row. |
| `774e0cb17` | 2025-06-13 | feld | Merge branch 'unlisted-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a361b84fc` | 2025-06-11 | Ekaterina Vaartis | Relax alsoKnownAs requirements to just being a URI | pending |  | Review against local BE/FE behavior, then update this row. |
| `bc75bb35f` | 2025-06-14 | lain | Merge branch 'relaxed-also-known-as' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `00d536d9e` | 2025-06-16 | Haelwenn (lanodan) Monnier | backports: Copy mkdir_p TOCTOU fix from elixir PR 14242 | pending |  | Review against local BE/FE behavior, then update this row. |
| `a69e41702` | 2025-06-16 | Haelwenn (lanodan) Monnier | File.mkdir_p -> Pleroma.Backports.mkdir_p | pending |  | Review against local BE/FE behavior, then update this row. |
| `d50822c31` | 2025-06-16 | vaartis | Merge branch 'bugfix/toctou-mkdir' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e35e84228` | 2024-09-01 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Change scrobble external link param name to use snake case | pending |  | Review against local BE/FE behavior, then update this row. |
| `cda7cbf2a` | 2025-06-18 | vaartis | Merge branch 'scrobbles' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `890ac8ff8` | 2025-03-28 | marcin mikoÃƒâ€¦Ã¢â‚¬Å¡ajczak | Expose markup configuration in InstanceView | pending |  | Review against local BE/FE behavior, then update this row. |
| `d1b9d0330` | 2025-03-28 | Nicole MikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `7234aa8c1` | 2025-04-03 | Nicole MikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge remote-tracking branch 'origin/develop' into instance-markup-info | pending |  | Review against local BE/FE behavior, then update this row. |
| `ca7dd87e2` | 2025-06-18 | vaartis | Merge branch 'instance-markup-info' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ae2c97fad` | 2025-06-04 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Use JSON for DeepL API requests | pending |  | Review against local BE/FE behavior, then update this row. |
| `490a273dc` | 2025-06-18 | vaartis | Merge branch 'deepl-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0151d9920` | 2025-06-18 | Ekaterina Vaartis | Use manually created variables for CI instead of CI_JOB_TOKEN | pending |  | Review against local BE/FE behavior, then update this row. |
| `29be5018b` | 2025-06-18 | vaartis | Merge branch 'ci-variables' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `27d271b4e` | 2025-06-18 | tusooa | Add maybe_anonymize_reporter/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `58ec4fd1e` | 2025-06-18 | tusooa | Anonymize reporter before federating | pending |  | Review against local BE/FE behavior, then update this row. |
| `1121f099e` | 2025-06-18 | tusooa | Ensure actor in Activity is also anonymized | pending |  | Review against local BE/FE behavior, then update this row. |
| `b5c97e9ee` | 2025-06-18 | tusooa | Put strip and anonymize process in prepare_outgoing | pending |  | Review against local BE/FE behavior, then update this row. |
| `58afb15ea` | 2025-06-18 | tusooa | Make ActivityPub.Publisher aware of the actor change by Transmogrifier | pending |  | Review against local BE/FE behavior, then update this row. |
| `9d62fca31` | 2025-06-18 | tusooa | Add changelog for anonymizing reports | pending |  | Review against local BE/FE behavior, then update this row. |
| `1df7d428b` | 2025-06-18 | Ekaterina Vaartis | Update preparing and tests for current codebase | pending |  | Review against local BE/FE behavior, then update this row. |
| `871e9e849` | 2025-06-19 | Ekaterina Vaartis | Make unaddressed_message? condsider [] as empty | pending |  | Review against local BE/FE behavior, then update this row. |
| `2c2de55b0` | 2024-09-17 | Mark Felder | Add Oban.Plugins.Lazarus | pending |  | Review against local BE/FE behavior, then update this row. |
| `9d6f201e5` | 2025-06-20 | Pleroma User | Add tos setting | pending |  | Review against local BE/FE behavior, then update this row. |
| `a708bf494` | 2025-06-20 | vaartis | Merge branch 'add-tos-setting' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7ecfb9533` | 2025-06-16 | Ekaterina Vaartis | Handle the Dislike activity by transforming into a thumbs-down emote | pending |  | Review against local BE/FE behavior, then update this row. |
| `9be542e27` | 2025-06-21 | vaartis | Merge branch 'handle-dislike' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `33cf49e86` | 2025-06-13 | Mark Felder | Resurrect MRF.QuietReply | pending |  | Review against local BE/FE behavior, then update this row. |
| `37d4ed883` | 2025-06-19 | Mark Felder | Change MRF logic to match when there is an inReplyTo and the public address is in the "to" field | pending |  | Review against local BE/FE behavior, then update this row. |
| `81155a229` | 2025-06-27 | Mark Felder | changelog for MRF.QuietReply | pending |  | Review against local BE/FE behavior, then update this row. |
| `f6c9b003f` | 2025-06-27 | feld | Merge branch 'resurrect-mrf-quietreply' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `56aab905e` | 2025-06-27 | Mark Felder | Queue individual jobs for each user that needs to be deleted when deleting an instance. | pending |  | Review against local BE/FE behavior, then update this row. |
| `ca616e9e7` | 2025-06-27 | Mark Felder | Fix Instance and Admin API controller tests for deleting instances | pending |  | Review against local BE/FE behavior, then update this row. |
| `cf6587d34` | 2025-06-27 | feld | Merge branch 'delete-instance-improvement' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `122ad4603` | 2025-07-03 | Mark Felder | Use correct Endpoint host and WebFinger domains in tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `736686b4e` | 2025-07-03 | Mark Felder | Add specific tests for Webfinger aliases / also_known_as | pending |  | Review against local BE/FE behavior, then update this row. |
| `17987e399` | 2025-07-03 | Mark Felder | Enforce an exact domain match for WebFinger resolution | pending |  | Review against local BE/FE behavior, then update this row. |
| `977097e87` | 2025-07-03 | feld | Merge branch 'webfinger-regex' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2d8ad2267` | 2024-11-28 | Haelwenn (lanodan) Monnier | mix: Bump captcha for OpenBSD make fixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `f5a5d354f` | 2025-07-08 | vaartis | Merge branch 'bump-captcha-posix-make' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f031532c4` | 2025-07-08 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Fix endorsement state display in relationship view | pending |  | Review against local BE/FE behavior, then update this row. |
| `b082e1f86` | 2025-07-09 | mkljczk | Merge branch 'endorsement-state-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9ea55a388` | 2025-07-22 | Mark Felder | Fix dialyzer error in API spec: Use then/2 for OpenApiSpex.resolve_schema_modules/1 call | pending |  | Review against local BE/FE behavior, then update this row. |
| `daad35aeb` | 2025-07-22 | Mark Felder | Fix dialyzer error in scopes compiler: Add error handling for extract_all_scopes/0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `47ebbc4d2` | 2025-07-22 | Mark Felder | Fix dialyzer error in status controller: Add catch-all pattern for translate function | pending |  | Review against local BE/FE behavior, then update this row. |
| `1d4482047` | 2025-07-22 | Mark Felder | Fix dialyzer error in translation provider: Change Map.t() to map() in callback spec | pending |  | Review against local BE/FE behavior, then update this row. |
| `e0104132a` | 2025-07-22 | Mark Felder | Fix dialyzer error in object fetcher: Add proper guard clause for check_crossdomain_redirect/2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `28146ee7d` | 2025-07-22 | Mark Felder | Fix dialyzer error in safe_zip: Remove impossible pattern match for {:get_type, _e} | pending |  | Review against local BE/FE behavior, then update this row. |
| `28cff592b` | 2025-07-22 | Mark Felder | Fix dialyzer error in MRF remote report policy: Remove unreachable pattern match | pending |  | Review against local BE/FE behavior, then update this row. |
| `b54b19a0f` | 2025-07-22 | Mark Felder | Fix test for mix task | pending |  | Review against local BE/FE behavior, then update this row. |
| `113261146` | 2025-07-22 | Mark Felder | Fix account endorsements test | pending |  | Review against local BE/FE behavior, then update this row. |
| `28b69f5c0` | 2025-07-22 | Mark Felder | Reset Emoji cache between tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `6da5ca9b2` | 2025-07-22 | Mark Felder | Prevent test crash if it cannot successfully remove the console Logger backend | pending |  | Review against local BE/FE behavior, then update this row. |
| `a504c2810` | 2025-07-23 | Mark Felder | Not changelog worthy | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1c201d1c` | 2025-07-23 | feld | Merge branch 'dialyzer' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8e0f73e45` | 2025-07-28 | Mark Felder | Change Oban Notifier to Oban.Notifiers.PG | pending |  | Review against local BE/FE behavior, then update this row. |
| `adce9f572` | 2025-07-29 | feld | Merge branch 'oban-notifier' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3d422ef32` | 2025-06-06 | Mark Felder | Reachability refactor | pending |  | Review against local BE/FE behavior, then update this row. |
| `b87ec4997` | 2025-06-06 | Mark Felder | Nodeinfo is not universally implemented | pending |  | Review against local BE/FE behavior, then update this row. |
| `0f667761a` | 2025-06-06 | Mark Felder | The ap_id is a URL, so we can just pass that to set_reachable/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `0fe03fc4e` | 2025-06-06 | Mark Felder | Revert "Nodeinfo is not universally implemented" | pending |  | Review against local BE/FE behavior, then update this row. |
| `83c975682` | 2025-06-06 | Mark Felder | Remove unncessary NaiveDateTime call. | pending |  | Review against local BE/FE behavior, then update this row. |
| `3984ba872` | 2025-06-07 | Lain Soykaf | Fix typo in changelog filename | pending |  | Review against local BE/FE behavior, then update this row. |
| `2748891e1` | 2025-06-07 | Mark Felder | Change the inboxes assignment in the Publisher to better indicate it's a list containing two lists | pending |  | Review against local BE/FE behavior, then update this row. |
| `8383584d6` | 2025-06-07 | Mark Felder | Reapply "Nodeinfo is not universally implemented" | pending |  | Review against local BE/FE behavior, then update this row. |
| `a46a48fb3` | 2025-06-07 | Mark Felder | PublisherWorker: change max_attempts to 13 which extends the last delivery attempt to ~4.3 days | pending |  | Review against local BE/FE behavior, then update this row. |
| `e58ecd323` | 2025-06-27 | Mark Felder | Merge remote-tracking branch 'origin/develop' into improved-reachability | pending |  | Review against local BE/FE behavior, then update this row. |
| `59bfa83c9` | 2025-06-27 | Mark Felder | Remove daily reachability scheduling for unreachable instances | pending |  | Review against local BE/FE behavior, then update this row. |
| `77dca7c3e` | 2025-06-27 | Mark Felder | Refactor ReachabilityWorker to use a 5-phase reachability testing approach | pending |  | Review against local BE/FE behavior, then update this row. |
| `6e4b5edc2` | 2025-06-27 | Mark Felder | Reduce pruning of history to anything older than 2 days | pending |  | Review against local BE/FE behavior, then update this row. |
| `a5e11ad11` | 2025-06-27 | Mark Felder | Custom pruning is not actually needed because an old job cannot exist in the table due to our use of [replace: true] when retrying jobs or walking it through the different phases | pending |  | Review against local BE/FE behavior, then update this row. |
| `13db73065` | 2025-06-27 | Mark Felder | Update Oban to 2.19 which gives us the delete_all_jobs/1 and delete_job/1 functions | pending |  | Review against local BE/FE behavior, then update this row. |
| `ff5f88aae` | 2025-06-27 | Mark Felder | Instance.set_reachable/1 should delete any existing ReachabilityWorker jobs for that instance | pending |  | Review against local BE/FE behavior, then update this row. |
| `2267ace10` | 2025-06-27 | Mark Felder | Ensure ReachabilityWorker jobs can be scheduled without needing awareness of the phase design | pending |  | Review against local BE/FE behavior, then update this row. |
| `8a0551686` | 2025-06-27 | Mark Felder | Remove changelog entry that leaked in via 3984ba87217e2a9fdc89c22ff2357c49563c5ad2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `29f760791` | 2025-06-28 | Mark Felder | Add Instances.check_all_unreachable/0 and Instance.check_unreachable/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `f06f0bedd` | 2025-06-28 | Mark Felder | Clean up ReachabilityWorker jobs and delete from Instances table when deleting all users and activities for an instance | pending |  | Review against local BE/FE behavior, then update this row. |
| `df0880d8d` | 2025-06-28 | Mark Felder | Add Instances.delete_all_unreachable/0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `59844d020` | 2025-06-28 | Mark Felder | Rename Instance.delete_users_and_activities/1 to Instance.delete/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `ece089aba` | 2025-07-29 | feld | Merge branch 'improved-reachability' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3efb99fdf` | 2025-07-29 | Mark Felder | Postgrex: Update to 0.20.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `d24e6eaf3` | 2025-07-30 | feld | Merge branch 'postgrex' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f66a877af` | 2025-08-01 | Mark Felder | Disable automatic CI jobs for every pushed branch | pending |  | Review against local BE/FE behavior, then update this row. |
| `f6106babf` | 2025-08-01 | feld | Merge branch 'ci-rules-update' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1d8eafc0d` | 2025-07-30 | Mark Felder | Add failing test case for URL encoding issue | pending |  | Review against local BE/FE behavior, then update this row. |
| `11d27349e` | 2025-07-30 | Mark Felder | Fix HTTP client making invalid requests due to no percent encoding processing or validation. | pending |  | Review against local BE/FE behavior, then update this row. |
| `4217ababf` | 2025-07-30 | Mark Felder | Improve design so existing tests do not break | pending |  | Review against local BE/FE behavior, then update this row. |
| `404e09126` | 2025-07-30 | Mark Felder | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `c49dece0d` | 2025-07-30 | Mark Felder | Update test to also cover query encoding | pending |  | Review against local BE/FE behavior, then update this row. |
| `842090945` | 2025-07-30 | Mark Felder | Ensure Hackney and Finch both get the default middleware | pending |  | Review against local BE/FE behavior, then update this row. |
| `49ba6c886` | 2025-07-30 | Mark Felder | Rework the URL encoding so it is a public function: Pleroma.HTTP.encode_url/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `ab4edf793` | 2025-07-30 | Mark Felder | Add proper ReverseProxy test cases | pending |  | Review against local BE/FE behavior, then update this row. |
| `425329bac` | 2025-07-30 | Mark Felder | Add fix to ensure URL is encoded when reverse proxying | pending |  | Review against local BE/FE behavior, then update this row. |
| `4e6f0af4c` | 2025-07-30 | Mark Felder | Better assertion logic | pending |  | Review against local BE/FE behavior, then update this row. |
| `44e56ed75` | 2025-07-30 | Mark Felder | Switch to example domain name | pending |  | Review against local BE/FE behavior, then update this row. |
| `7042495d7` | 2025-08-01 | feld | Merge branch 'http-url-encoding' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `321bd75dc` | 2025-08-06 | Ekaterina Vaartis | Add a way to upload emoji pack from zip/url easily | pending |  | Review against local BE/FE behavior, then update this row. |
| `26ac875bc` | 2025-08-07 | Ekaterina Vaartis | Use path_join_name_safe for pathname joining | pending |  | Review against local BE/FE behavior, then update this row. |
| `8d0b29d71` | 2025-08-07 | Ekaterina Vaartis | Only calculate SHA when there's no pack json | pending |  | Review against local BE/FE behavior, then update this row. |
| `897c1ced5` | 2025-08-07 | Lain Soykaf | EmojiPackControllerDownloadZipTest: Add test. | pending |  | Review against local BE/FE behavior, then update this row. |
| `b249340fc` | 2025-08-07 | Lain Soykaf | Emoji.Pack: Refactor and use safe_unzip. | pending |  | Review against local BE/FE behavior, then update this row. |
| `f203e7bb4` | 2025-08-07 | Lain Soykaf | EmojiPackController: Refactor. | pending |  | Review against local BE/FE behavior, then update this row. |
| `4eeb9c1f2` | 2025-08-08 | Lain Soykaf | EmojiPackControllerDownloadZipTest: Add tests for empty pack name and failing creation. | pending |  | Review against local BE/FE behavior, then update this row. |
| `80e0f0724` | 2025-08-08 | Lain Soykaf | Emoji.Pack: Implement empty name and directory creation failure handling | pending |  | Review against local BE/FE behavior, then update this row. |
| `26fe60494` | 2025-07-31 | Mark Felder | Hashtag searches now return real results from the database | pending |  | Review against local BE/FE behavior, then update this row. |
| `93c144e39` | 2025-07-31 | Mark Felder | Improve hashtag search with multi word queries | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1acc9281` | 2025-07-31 | Mark Felder | Use ranking to improve order of results | pending |  | Review against local BE/FE behavior, then update this row. |
| `97e668f4a` | 2025-07-31 | Mark Felder | Alpha sort the aliases | pending |  | Review against local BE/FE behavior, then update this row. |
| `19f32f7b0` | 2025-07-31 | Mark Felder | Strip hashtag prefixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `eac8ef795` | 2025-08-01 | Mark Felder | Credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `4b01c0f16` | 2025-08-01 | Mark Felder | Update Tesla to 1.15.3 | pending |  | Review against local BE/FE behavior, then update this row. |
| `3c36bcfaa` | 2025-08-01 | Mark Felder | Remove deprecated "use Tesla" macro usage | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f93e85e0` | 2025-08-01 | feld | Merge branch 'tesla-update' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `09eb7dbf8` | 2025-08-01 | Ekaterina Vaartis | Change mailer example to use Mua | pending |  | Review against local BE/FE behavior, then update this row. |
| `88d0a36d0` | 2025-08-01 | feld | Merge branch 'mailer-mua' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9eb3fc2d3` | 2025-07-21 | Phantasm | Docs: Avoid long DB restore times and update few things | pending |  | Review against local BE/FE behavior, then update this row. |
| `d736d3130` | 2025-07-21 | Phantasm | Docs: Add systemctl commands to DB backup/restore | pending |  | Review against local BE/FE behavior, then update this row. |
| `5400102a2` | 2025-08-01 | feld | Merge branch 'db-restore-docs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ee37b2d8c` | 2025-06-18 | Ekaterina Vaartis | Return 404 when an activity is sent to a deactivated user's /inbox | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb78fb5f6` | 2025-08-01 | feld | Merge branch 'deactivated-404-inbox' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `44898845a` | 2025-08-01 | Mark Felder | Update Plug/Cowboy/Gun | pending |  | Review against local BE/FE behavior, then update this row. |
| `7b8d6eca6` | 2025-08-01 | Mark Felder | Remove deprecated "use Plug.Test" | pending |  | Review against local BE/FE behavior, then update this row. |
| `d67ab670b` | 2025-08-01 | Mark Felder | Fix Gopher server to use modern :ranch | pending |  | Review against local BE/FE behavior, then update this row. |
| `9195cfb2b` | 2025-08-01 | Mark Felder | Document Gun, Cowboy, and Plug update | pending |  | Review against local BE/FE behavior, then update this row. |
| `34efff85d` | 2025-08-02 | feld | Merge branch 'gun' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f53538b43` | 2025-08-01 | Mark Felder | Merge remote-tracking branch 'origin/develop' into hashtag-search | pending |  | Review against local BE/FE behavior, then update this row. |
| `c1836c982` | 2025-08-02 | Mark Felder | Fix test that relied on previous fake hashtag behavior | pending |  | Review against local BE/FE behavior, then update this row. |
| `62993871e` | 2025-08-02 | feld | Merge branch 'hashtag-search' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `36b3aa0a9` | 2025-08-08 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into emoji-pack-upload | pending |  | Review against local BE/FE behavior, then update this row. |
| `4ab96bbb9` | 2025-08-09 | Lain Soykaf | EmojiPackControllerDownloadZipTest: Use a unique folder for each test. | pending |  | Review against local BE/FE behavior, then update this row. |
| `20812151a` | 2025-08-10 | Lain Soykaf | Gitlab CI: Don't run as root. | pending |  | Review against local BE/FE behavior, then update this row. |
| `50a962ec6` | 2025-08-10 | lain | Merge branch 'emoji-pack-upload' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c0c4bfd8c` | 2025-01-23 | NPL | clients.md: Update Source Code and Contact links | pending |  | Review against local BE/FE behavior, then update this row. |
| `7071e65a7` | 2025-08-11 | vaartis | Merge branch 'docs/client_link_update' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f78db5aac` | 2025-08-15 | Haelwenn (lanodan) Monnier | mix.lock: mix deps.update --all | pending |  | Review against local BE/FE behavior, then update this row. |
| `c7ac7300b` | 2025-08-27 | lain | Merge branch 'deps-update-2025-08' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `8428a1bed` | 2025-08-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into lazarus | pending |  | Review against local BE/FE behavior, then update this row. |
| `933fe4fcf` | 2025-08-27 | Codimp | [CI] Upgrade Docker images building OTP | pending |  | Review against local BE/FE behavior, then update this row. |
| `91c0746b5` | 2025-08-27 | lain | Merge branch 'update-docker-images-building-otp' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b9f623608` | 2025-08-27 | Lain Soykaf | Dockerfile: Sync with CI, make more resilient | pending |  | Review against local BE/FE behavior, then update this row. |
| `7e770d73c` | 2025-08-27 | lain | Merge branch 'update-dockerfile' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `331f21111` | 2025-07-23 | Lain Soykaf | Add only_reblogs parameter to account statuses API | pending |  | Review against local BE/FE behavior, then update this row. |
| `f1cb334cd` | 2025-07-23 | Lain Soykaf | Document only_reblogs parameter in API differences | pending |  | Review against local BE/FE behavior, then update this row. |
| `991c5e0c4` | 2025-07-23 | Lain Soykaf | Add ActivityPub test for only_reblogs filtering | pending |  | Review against local BE/FE behavior, then update this row. |
| `b13d5c2f8` | 2025-07-23 | Lain Soykaf | Add changelog entry for only_reblogs parameter | pending |  | Review against local BE/FE behavior, then update this row. |
| `49376e6b7` | 2025-08-27 | lain | Merge branch 'repost-repeat-filtering-3391' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `28a2e3650` | 2025-07-20 | Lain Soykaf | AdminAPI: Add (failing) test for admin self-revocation | pending |  | Review against local BE/FE behavior, then update this row. |
| `c38ce20a5` | 2025-07-20 | Lain Soykaf | AdminApiController: Reorder functions to fix admin revocation | pending |  | Review against local BE/FE behavior, then update this row. |
| `606d64ceb` | 2025-07-20 | Lain Soykaf | Add changelog entry for admin self-revocation fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `2980788c8` | 2025-08-27 | lain | Merge branch 'admin-api-revocation' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `bde52824d` | 2025-08-01 | Lain Soykaf | Fix ModerationLog FunctionClauseError for unknown actions | pending |  | Review against local BE/FE behavior, then update this row. |
| `3a1581c94` | 2025-08-01 | Lain Soykaf | add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `14caaa8f2` | 2025-08-27 | feld | Merge branch 'moderation-log-fix-3385' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a5dbf8dea` | 2025-08-27 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into lazarus | pending |  | Review against local BE/FE behavior, then update this row. |
| `0c4b5a925` | 2025-08-30 | Lain Soykaf | Mix, Gitlab, Docs: Require Elixir 1.15 | pending |  | Review against local BE/FE behavior, then update this row. |
| `52323e161` | 2025-08-29 | Mark Felder | Add Oban.Plugins.Lazarus | pending |  | Review against local BE/FE behavior, then update this row. |
| `348291cc3` | 2025-08-30 | Lain Soykaf | Merge branch 'lazarus' of git.pleroma.social:pleroma/pleroma into lazarus | pending |  | Review against local BE/FE behavior, then update this row. |
| `aaaed8789` | 2025-08-30 | lain | Merge branch 'lazarus' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `5bf1a384c` | 2025-09-04 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-from/upstream-develop/tusooa/report-anon | pending |  | Review against local BE/FE behavior, then update this row. |
| `71785d7ff` | 2025-09-05 | Lain Soykaf | PublisherTest: Add test for signature replacement | pending |  | Review against local BE/FE behavior, then update this row. |
| `e2a9a4183` | 2025-09-04 | Lain Soykaf | Update Pleroma-FE version to 2.9.2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `ff580a58c` | 2025-09-04 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `bbf4c6998` | 2025-09-04 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-fe-2.9.2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `ffc93a10a` | 2025-09-04 | Lain Soykaf | Mix: Remove double lazarus | pending |  | Review against local BE/FE behavior, then update this row. |
| `8de659d3f` | 2025-09-05 | lain | Merge branch 'pleroma-fe-2.9.2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ae0c0260f` | 2025-09-05 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-from/upstream-develop/tusooa/report-anon | pending |  | Review against local BE/FE behavior, then update this row. |
| `3de250da2` | 2025-09-05 | Lain Soykaf | PublisherTest: Use mox instead of mock. | pending |  | Review against local BE/FE behavior, then update this row. |
| `b023e1591` | 2025-09-05 | Lain Soykaf | PublisherTest: Mock -> Mox | pending |  | Review against local BE/FE behavior, then update this row. |
| `5503247b1` | 2025-09-05 | Lain Soykaf | PublisherTest: Linting. | pending |  | Review against local BE/FE behavior, then update this row. |
| `d1d7dd182` | 2025-09-05 | lain | Merge branch 'from/upstream-develop/tusooa/report-anon' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1f2d4dd63` | 2025-05-08 | mkljczk | Remove redundant code from register_changeset_ldap | pending |  | Review against local BE/FE behavior, then update this row. |
| `1efe48672` | 2025-09-12 | feld | Merge branch 'ldap-wtf' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `abdb51199` | 2025-09-07 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Fix typo in test name | pending |  | Review against local BE/FE behavior, then update this row. |
| `dccb264c4` | 2025-09-19 | mkljczk | Merge branch 'typo' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a06d09ab1` | 2025-09-27 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Update voters count in remote polls when refreshing | pending |  | Review against local BE/FE behavior, then update this row. |
| `aaaf18c1c` | 2025-09-27 | mkljczk | Merge branch 'update-poll-voters-count' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e666ddc9b` | 2025-09-27 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add `update` to @notification_types | pending |  | Review against local BE/FE behavior, then update this row. |
| `8f9a139ba` | 2025-09-27 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'notification-type-update' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `94188a293` | 2025-09-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Update *Differences in Mastodon API responses from vanilla Mastodon* | pending |  | Review against local BE/FE behavior, then update this row. |
| `9eb923bd4` | 2025-09-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'docs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0b8b98f97` | 2025-10-10 | Nicole MikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add a failing test | pending |  | Review against local BE/FE behavior, then update this row. |
| `f989626ba` | 2025-10-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Fix publisher when publishing to a list of users | pending |  | Review against local BE/FE behavior, then update this row. |
| `606c9ae4b` | 2025-10-21 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'fix-lists-bcc' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4f31cadbc` | 2025-10-22 | Mark Felder | Enable expiration of CICD job artifacts | pending |  | Review against local BE/FE behavior, then update this row. |
| `3ab1c3ae8` | 2025-10-22 | feld | Merge branch 'expire-artifacts' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a07305ca3` | 2025-10-23 | Mark Felder | GitLab support for default artifacts setting is broken | pending |  | Review against local BE/FE behavior, then update this row. |
| `6942244bb` | 2025-10-23 | feld | Merge branch 'expire-artifacts' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `a0225ddc7` | 2025-10-23 | Mark Felder | CI: Allow running pipelines from web or directly for a tag | pending |  | Review against local BE/FE behavior, then update this row. |
| `6026046b1` | 2025-10-23 | feld | Merge branch 'expire-artifacts' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d09ec2545` | 2025-10-23 | Mark Felder | CI: use triggers for docs and api-docs deployments | pending |  | Review against local BE/FE behavior, then update this row. |
| `d54ec3944` | 2025-10-23 | feld | Merge branch 'pipeline-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b6da3f490` | 2025-10-23 | Mark Felder | Fix branch names for pleroma/docs and pleroma/api-docs triggers | pending |  | Review against local BE/FE behavior, then update this row. |
| `6f7e52148` | 2025-10-23 | Mark Felder | CI: pass the variable CI_PIPELINE_ID through to the api-docs build job | pending |  | Review against local BE/FE behavior, then update this row. |
| `d15f98bde` | 2025-10-23 | Mark Felder | CI: Use the dotenv report method to capture the spec-build internal job id and pass it through to the spec-deploy job | pending |  | Review against local BE/FE behavior, then update this row. |
| `cb7086cb1` | 2025-09-07 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Use end-of-string in regex for local `get_by_nickname` | pending |  | Review against local BE/FE behavior, then update this row. |
| `b6e16877e` | 2025-11-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'local-nickname-regex-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1610d39f3` | 2025-10-21 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Revert "User.get_or_fetch_public_key_for_ap_id/1 is no longer required." | pending |  | Review against local BE/FE behavior, then update this row. |
| `b38fedf34` | 2025-10-21 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Fix fetching public keys with authorized fetch enabled | pending |  | Review against local BE/FE behavior, then update this row. |
| `68b4de755` | 2025-11-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'authorized-fetch-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `724cdc44f` | 2025-11-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Fix typo in Pleroma name in docs | pending |  | Review against local BE/FE behavior, then update this row. |
| `09df007ae` | 2025-11-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'plaroma' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `546c03b2c` | 2025-09-19 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | `remote_url` links to unproxied URL | pending |  | Review against local BE/FE behavior, then update this row. |
| `a893c69d2` | 2025-11-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'remote-url-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `9da1875c3` | 2025-11-22 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Send push notifications for statuses from subscribed accounts | pending |  | Review against local BE/FE behavior, then update this row. |
| `79e59cb75` | 2025-11-22 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'status-push-notification' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `dc85b2799` | 2025-11-25 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Minor cleanup and comment fixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `4fc1a6226` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'notification-cleanup' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `7e34d7286` | 2025-10-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Support Mozhi as translation provider | pending |  | Review against local BE/FE behavior, then update this row. |
| `d56433be6` | 2025-10-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | List Mozhi in suggestions for translation providers | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb1e64399` | 2025-10-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `9548c31ef` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'translation-provider-mozhi' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `b975dce9b` | 2025-11-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add `timelines_access` to InstanceView | pending |  | Review against local BE/FE behavior, then update this row. |
| `ec51aadc7` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'instance-view-timeline-access' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `065200e92` | 2025-05-06 | Nicole MikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Support new Mastodon API for endorsed accounts | pending |  | Review against local BE/FE behavior, then update this row. |
| `5ce3c12c2` | 2025-10-08 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'develop' into 'endorsements-api' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e81e0d64c` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'endorsements-api' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `50e3cc67f` | 2025-10-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Redirect /users/:nickname.rss to /users/:nickname/feed.rss instead of .atom | pending |  | Review against local BE/FE behavior, then update this row. |
| `0476cf428` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'rss-redirect' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e458bd953` | 2025-11-28 | mkljczk | Add /api/v1/pleroma/outgoing_follow_requests | pending |  | Review against local BE/FE behavior, then update this row. |
| `367d5c65f` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'outgoing_follow_requests' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `32bc8ec58` | 2025-09-07 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Stream marker updates | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f4c94805` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | fix typo | pending |  | Review against local BE/FE behavior, then update this row. |
| `ba8b5682c` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'stream-marker-updates' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ed1cfd6f5` | 2025-10-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Support translateLocally translation provider | pending |  | Review against local BE/FE behavior, then update this row. |
| `13bc4ba63` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge remote-tracking branch 'origin/develop' into translation-provider-translatelocally | pending |  | Review against local BE/FE behavior, then update this row. |
| `0dfcc24d3` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'translation-provider-translatelocally' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `02edd04cc` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add v1/instance/domain_blocks endpoint | pending |  | Review against local BE/FE behavior, then update this row. |
| `f53c34c5d` | 2024-09-25 | Mark Felder | Move Pleroma cache to /var/tmp | pending |  | Review against local BE/FE behavior, then update this row. |
| `537d4d19c` | 2024-09-25 | Mark Felder | Move to the new method to enable http2 instead of on the listen socket statement | pending |  | Review against local BE/FE behavior, then update this row. |
| `16796c292` | 2024-09-25 | Mark Felder | Provide HTTP/3 config example | pending |  | Review against local BE/FE behavior, then update this row. |
| `887a45488` | 2024-09-25 | Mark Felder | Provide example of configuring a dedicated media and proxy subdomain | pending |  | Review against local BE/FE behavior, then update this row. |
| `f06a7b51e` | 2024-09-25 | Mark Felder | Annotate the Nginx media upload limit | pending |  | Review against local BE/FE behavior, then update this row. |
| `6b596ca8e` | 2024-09-25 | Mark Felder | Update the example Nginx config | pending |  | Review against local BE/FE behavior, then update this row. |
| `90e0911cd` | 2024-09-25 | Mark Felder | Provide full uploads config for a subdomain | pending |  | Review against local BE/FE behavior, then update this row. |
| `2870140db` | 2024-09-25 | Mark Felder | The /media route has not existed for some years now | pending |  | Review against local BE/FE behavior, then update this row. |
| `503e43da5` | 2024-09-25 | Mark Felder | Document the /uploads location more thoroughly | pending |  | Review against local BE/FE behavior, then update this row. |
| `045dfaf2a` | 2024-10-30 | Mark Felder | Fix nginx location for serving media directly | pending |  | Review against local BE/FE behavior, then update this row. |
| `c1699c6e6` | 2025-10-31 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Support `quoted_status_id` parameter in post creation request | pending |  | Review against local BE/FE behavior, then update this row. |
| `c3c57ef6c` | 2025-09-07 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | remove duplicated code from notificationview | pending |  | Review against local BE/FE behavior, then update this row. |
| `428e038c5` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'notification-view-deduplicate' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `32a940b86` | 2025-10-26 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Allow setting custom user-agent for fetching rich media content | pending |  | Review against local BE/FE behavior, then update this row. |
| `6e98c7a1c` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'rich-media-user-agent' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `2012e83e2` | 2025-10-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Allow filtering users with `accepts_chat_messages` capability | pending |  | Review against local BE/FE behavior, then update this row. |
| `26a058935` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'filter-user-capabilities' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `889938d76` | 2025-10-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Scrubber: Allow `quote-inline` class in <p> tags used by Mastodon quotes | pending |  | Review against local BE/FE behavior, then update this row. |
| `e74b6ed34` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'scrubber-inline-quotes-mastodon' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `5cb141a54` | 2025-11-29 | Phantasm | MRF InlineQuotePolicy: Don't inline quoted post URL in Mastodon quotes | pending |  | Review against local BE/FE behavior, then update this row. |
| `2330c5066` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'inlinequotes-mastodon' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ef41378fa` | 2025-11-29 | Atsuko Karagi | Respect restrict_unauthenticated in /api/v1/accounts/lookup | pending |  | Review against local BE/FE behavior, then update this row. |
| `f443b6d1d` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'lookup-restrict-unauthenticated' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d2f6cc144` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Use separate schemas for muted/blocked accounts lists | pending |  | Review against local BE/FE behavior, then update this row. |
| `be0146afb` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Improve example | pending |  | Review against local BE/FE behavior, then update this row. |
| `6b8bc3bb4` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'blocked-muted-swagger' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `f61fad066` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Pin/unpin chats | pending |  | Review against local BE/FE behavior, then update this row. |
| `ca03d94f5` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'pin-chats' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ef9bcb373` | 2025-09-27 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Use Mastodon-compatible route for quotes list and param for quotes count | pending |  | Review against local BE/FE behavior, then update this row. |
| `c5b100a9f` | 2025-10-08 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'develop' into 'mastodon-quotes-updates' | pending |  | Review against local BE/FE behavior, then update this row. |
| `d7b011512` | 2025-12-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'mastodon-quotes-updates' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `aef26a615` | 2025-11-07 | Mint | Fix changelog checker | pending |  | Review against local BE/FE behavior, then update this row. |
| `90686f96d` | 2025-12-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'changelog/fix-checker' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `df1a3b5a7` | 2025-12-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | changelog-checker: Change changelog entry type | pending |  | Review against local BE/FE behavior, then update this row. |
| `40695530a` | 2025-12-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'changelog/fix-checker' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ca098a2be` | 2025-10-29 | HJ | Allow FediIndex | pending |  | Review against local BE/FE behavior, then update this row. |
| `a275ffaca` | 2025-10-29 | HJ | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `cc14a7e33` | 2025-12-08 | HJ | Merge branch 'hj-develop-patch-37634' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0f3b1808f` | 2025-12-10 | Phantasm | Check what chars to encode in the path segment of URIs, add list to Constants | pending |  | Review against local BE/FE behavior, then update this row. |
| `619f247e3` | 2025-12-10 | Phantasm | Add more URL-encoding tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `0a8423fdf` | 2025-12-10 | Phantasm | Add ability to bypass url decode/parse in Pleroma.HTTP, fix encode in Pleroma.Upload | pending |  | Review against local BE/FE behavior, then update this row. |
| `80db6f132` | 2025-12-10 | Phantasm | Fix character escaping test for Pleroma.Upload | pending |  | Review against local BE/FE behavior, then update this row. |
| `99a1c0890` | 2025-12-10 | Phantasm | URI.encode_query needs an enum, add test for this case | pending |  | Review against local BE/FE behavior, then update this row. |
| `9445ab909` | 2025-12-10 | Phantasm | ReverseProxy: Log request after potentional %-encoding | pending |  | Review against local BE/FE behavior, then update this row. |
| `004ea90b2` | 2025-12-10 | Phantasm | MediaProxy: Fix 424 caused by inconsistent %-encoding from remote instances | pending |  | Review against local BE/FE behavior, then update this row. |
| `d413f9bf7` | 2025-12-10 | Phantasm | MediaProxy: fix Pleroma.HTTP.encode_url not being available in test env | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b438fd16` | 2025-12-10 | Phantasm | MediaProxy: fix query params test | pending |  | Review against local BE/FE behavior, then update this row. |
| `a0f73d0e2` | 2025-12-10 | Phantasm | Reimplement URI.encode_query/2 to support quirks, add Guardian quirk | pending |  | Review against local BE/FE behavior, then update this row. |
| `cfd2c08ef` | 2025-12-10 | Phantasm | lint | pending |  | Review against local BE/FE behavior, then update this row. |
| `f36851acb` | 2025-12-10 | Phantasm | credo lint | pending |  | Review against local BE/FE behavior, then update this row. |
| `6487c93c4` | 2025-12-10 | Phantasm | credo lint 2 | pending |  | Review against local BE/FE behavior, then update this row. |
| `f290b1598` | 2025-12-10 | Phantasm | Move custom URI encoding functions to Pleroma.Utils.URIEncoding | pending |  | Review against local BE/FE behavior, then update this row. |
| `c31454fac` | 2025-12-10 | Phantasm | Fix unicode URL encoding test | pending |  | Review against local BE/FE behavior, then update this row. |
| `bfe8372ad` | 2025-12-10 | Phantasm | Remove "preserve ASCII encoding" test in MediaProxy | pending |  | Review against local BE/FE behavior, then update this row. |
| `0935823be` | 2025-12-10 | Phantasm | Add test for mangling incorrect URL in MediaProxy link generation | pending |  | Review against local BE/FE behavior, then update this row. |
| `bcdd78fba` | 2025-12-10 | Phantasm | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `07ba3bb82` | 2025-12-10 | Phantasm | Remove "support" for path encoding quirks | pending |  | Review against local BE/FE behavior, then update this row. |
| `0f7ad318d` | 2025-12-10 | Phantasm | Add encode_url @spec and docs, and a check whether opts are booleans | pending |  | Review against local BE/FE behavior, then update this row. |
| `73b337245` | 2025-12-10 | Phantasm | Make URI encoding query quirks host-aware | pending |  | Review against local BE/FE behavior, then update this row. |
| `7d8a18896` | 2025-12-10 | Phantasm | Disable Hackney URL encoding function | pending |  | Review against local BE/FE behavior, then update this row. |
| `ed931a668` | 2025-12-10 | lain | Merge branch 'url-encode-pt2' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c1aad0f14` | 2025-12-02 | Oneric | Fix NodeInfo content-type | pending |  | Review against local BE/FE behavior, then update this row. |
| `32ab9d628` | 2025-12-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add changelog entry | pending |  | Review against local BE/FE behavior, then update this row. |
| `c8fc821a0` | 2025-12-11 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'nodeinfo-content-type' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `4985902b0` | 2025-12-15 | Phantasm | Add Actor images normalization from array of urls to string | pending |  | Review against local BE/FE behavior, then update this row. |
| `d9baa0980` | 2025-12-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'normalize-actor-image-hrefs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3be0d206b` | 2025-09-07 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Allow "invisible" and "ellipsis" classes for span tags to match Mastodon behavior | pending |  | Review against local BE/FE behavior, then update this row. |
| `de022de4c` | 2025-12-16 | HJ | Merge branch 'scrubber-span-classes' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `27223fc5b` | 2025-10-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add `write:scrobbles` and `read:scrobbles` scope for scrobbling | pending |  | Review against local BE/FE behavior, then update this row. |
| `c6298be9f` | 2025-12-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'scrobbles-scope' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `c05d2d02c` | 2025-12-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Use :list_behaviour_implementations for LanguageDetector and Translation providers | pending |  | Review against local BE/FE behavior, then update this row. |
| `8c9e130cc` | 2025-12-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'description-improvement' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3a5e8e5e0` | 2025-11-28 | FloatingGhost | ensure we send the right files for preferred fe | pending |  | Review against local BE/FE behavior, then update this row. |
| `004f9fa69` | 2025-11-28 | FloatingGhost | add selection UI | pending |  | Review against local BE/FE behavior, then update this row. |
| `bb44501a9` | 2025-11-28 | FloatingGhost | Add frontend preference route | pending |  | Review against local BE/FE behavior, then update this row. |
| `8827e5117` | 2025-11-28 | PaweÃƒâ€¦Ã¢â‚¬Å¡ Ãƒâ€¦Ã…Â¡wiÃƒâ€žÃ¢â‚¬Â¦tkowski | Fix OpenAPI spec for preferred_frontend endpoint | pending |  | Review against local BE/FE behavior, then update this row. |
| `fd177a363` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | cleanup | pending |  | Review against local BE/FE behavior, then update this row. |
| `1fd94ed00` | 2025-11-28 | FloatingGhost | ensure only pickable frontends can be returned | pending |  | Review against local BE/FE behavior, then update this row. |
| `f1586f023` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | im bad at merge conflicts | pending |  | Review against local BE/FE behavior, then update this row. |
| `a80776b26` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | make it work | pending |  | Review against local BE/FE behavior, then update this row. |
| `5c139be42` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `78c433221` | 2025-11-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | spec, changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `cc51ee866` | 2025-11-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | analysis | pending |  | Review against local BE/FE behavior, then update this row. |
| `d41e2fbaa` | 2025-12-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'preferred-frontend' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `21f486c87` | 2025-11-30 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Order favourites and reblogs list from newest to oldest | pending |  | Review against local BE/FE behavior, then update this row. |
| `c06fcc7f5` | 2025-12-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'order-favourites-reblogs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e0ab2c9c9` | 2025-12-17 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge remote-tracking branch 'origin/develop' into mastodon-quote-id-api | pending |  | Review against local BE/FE behavior, then update this row. |
| `45611c988` | 2025-12-17 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'mastodon-quote-id-api' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `ed7ad7d96` | 2025-12-17 | Phantasm | OpenBSD relayd: Fix IPv6 example | pending |  | Review against local BE/FE behavior, then update this row. |
| `1d4464065` | 2025-12-21 | lain | Merge branch 'relayd-ipv6' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `928fb6d2e` | 2025-09-13 | Phantasm | docs rum: Remove warning about lower PostgreSQL now unsupported versions | pending |  | Review against local BE/FE behavior, then update this row. |
| `846e0ae2c` | 2025-09-13 | Phantasm | docs rum: Update idx size, add command for OTP install, recommend vacuum | pending |  | Review against local BE/FE behavior, then update this row. |
| `d1b01ae70` | 2025-10-23 | Phantasm | docs rum: use relative path for optional migrations for OTP installs | pending |  | Review against local BE/FE behavior, then update this row. |
| `985a0a28c` | 2025-12-21 | lain | Merge branch 'docs-rum-idx' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3e2573f1c` | 2025-12-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Fix WebFinger for split-domain set ups | pending |  | Review against local BE/FE behavior, then update this row. |
| `e5be1d04d` | 2025-12-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Update tests, make the mastodon subdomain example not have the /.well-known/host-meta redirect, as the docs don't include it | pending |  | Review against local BE/FE behavior, then update this row. |
| `cacb2ce37` | 2025-12-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `45af48520` | 2025-12-15 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | this shouldn't be available outside the module | pending |  | Review against local BE/FE behavior, then update this row. |
| `f70d1a436` | 2025-12-21 | Lain Soykaf | WebFingerTest: Add test for more webfinger spoofing. | pending |  | Review against local BE/FE behavior, then update this row. |
| `e9d972463` | 2025-12-21 | Lain Soykaf | WebFinger: Tighten the requirements. | pending |  | Review against local BE/FE behavior, then update this row. |
| `d19b99241` | 2025-12-22 | lain | Merge branch 'webfinger-actual-fix' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6ed9d681b` | 2025-11-08 | Mint | Transmogrifier: convert "as:Public" to full w3 URL | pending |  | Review against local BE/FE behavior, then update this row. |
| `4496dc81c` | 2025-12-21 | Lain Soykaf | TransmogrifierTest, CreateGenericValidatorTest: Add regression tests for addressing. | pending |  | Review against local BE/FE behavior, then update this row. |
| `ec58b6a4c` | 2025-12-21 | Lain Soykaf | CommonFixes, Transmogrifier: Fix tests. | pending |  | Review against local BE/FE behavior, then update this row. |
| `1d366c013` | 2025-12-22 | lain | Merge branch 'transmogrifier/handle-as-public' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `0f32134ea` | 2025-12-22 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into nginx-config-update | pending |  | Review against local BE/FE behavior, then update this row. |
| `2b8a366f9` | 2025-12-22 | Lain Soykaf | Nginx example: Add headers and use same paths we use in other places | pending |  | Review against local BE/FE behavior, then update this row. |
| `bd41d1510` | 2025-12-22 | lain | Merge branch 'nginx-config-update' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `59fcb5c96` | 2025-12-11 | Oneric | api: ensure only visible posts are interactable | pending |  | Review against local BE/FE behavior, then update this row. |
| `f8db412af` | 2025-12-11 | Oneric | fed/fetch: don't serve unsanitised object data for some activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `409698ca6` | 2025-12-11 | Oneric | fed/out: ensure we never serve Updates for objects we deem static | pending |  | Review against local BE/FE behavior, then update this row. |
| `a1662f05e` | 2025-12-11 | Oneric | fed/fetch: use same sanitisation logic as when delivering to inboxes | pending |  | Review against local BE/FE behavior, then update this row. |
| `885ba3a46` | 2025-12-11 | Oneric | test: add more representation tests for perpare_outgoing | pending |  | Review against local BE/FE behavior, then update this row. |
| `18d762c01` | 2025-12-11 | Oneric | Add voters key to internal object fields | pending |  | Review against local BE/FE behavior, then update this row. |
| `75353282e` | 2025-12-11 | Phantasm | AP ObjectView: add test for Listen activities | pending |  | Review against local BE/FE behavior, then update this row. |
| `b3887a6fa` | 2025-12-11 | Phantasm | AP C2S: Validate visibility for C2S requests to /users/:nickname/outbox | pending |  | Review against local BE/FE behavior, then update this row. |
| `a4e480a63` | 2025-12-11 | Phantasm | lint and credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `2b76243ec` | 2025-12-11 | Phantasm | CommonAPI: Fail when user sends report with posts not visible to them | pending |  | Review against local BE/FE behavior, then update this row. |
| `7f3b3c249` | 2025-12-11 | Phantasm | AP C2S: remove check for local user since user is already authenticated | pending |  | Review against local BE/FE behavior, then update this row. |
| `21b2fd1e0` | 2025-12-11 | Phantasm | AP C2S: reject Flag activities, add visibility refutes to some tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `3f1696517` | 2025-12-11 | Phantasm | Transmogrifier: update internal fields list according to constant | pending |  | Review against local BE/FE behavior, then update this row. |
| `f91474851` | 2025-12-11 | Phantasm | Transmogrifier: make Listen Activity test more strict | pending |  | Review against local BE/FE behavior, then update this row. |
| `426535bc3` | 2025-12-11 | Phantasm | CommonAPI: Forbid disallowed status (un)muting and unpinning | pending |  | Review against local BE/FE behavior, then update this row. |
| `63bdf4dc2` | 2025-12-11 | Phantasm | C2S: New Add/Remove and Actor creation tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `9d89156b8` | 2025-12-11 | Phantasm | AP C2S: Explicitly reject Updates to Actors that failed silently | pending |  | Review against local BE/FE behavior, then update this row. |
| `293628fb2` | 2025-12-11 | Phantasm | MastoAPI/CommonAPI: Return 404 when post not visible to user | pending |  | Review against local BE/FE behavior, then update this row. |
| `73a3f06f7` | 2025-12-12 | Phantasm | PleromaAPI: Change EmojiReact to invisible post response from 400 to 404 | pending |  | Review against local BE/FE behavior, then update this row. |
| `fe7108cbc` | 2025-12-12 | Phantasm | MastoAPI: Unify pin/bookmark/mute/fav not visible responses to 404 | pending |  | Review against local BE/FE behavior, then update this row. |
| `374305d5f` | 2025-12-12 | Phantasm | AP C2S: Add reply test | pending |  | Review against local BE/FE behavior, then update this row. |
| `53f23dd25` | 2025-12-12 | Phantasm | MastoAPI docs: Remove unused 403 respones | pending |  | Review against local BE/FE behavior, then update this row. |
| `6f55763db` | 2025-12-12 | Phantasm | add changelogs | pending |  | Review against local BE/FE behavior, then update this row. |
| `49a5630c7` | 2025-12-12 | Phantasm | CommonAPI: Standardize visibility error, use helper function if possible | pending |  | Review against local BE/FE behavior, then update this row. |
| `d36d0abd2` | 2025-12-12 | Phantasm | API Docs: Switch some added 404 API response to ApiNotFoundError schema | pending |  | Review against local BE/FE behavior, then update this row. |
| `3466b626d` | 2025-12-14 | Phantasm | lint | pending |  | Review against local BE/FE behavior, then update this row. |
| `4b168691f` | 2025-12-16 | Phantasm | add missing changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `ed538603f` | 2025-12-21 | Lain Soykaf | TransmogrifierTest: Add failing test for Update. | pending |  | Review against local BE/FE behavior, then update this row. |
| `98f300c5a` | 2025-12-21 | Lain Soykaf | Transmogrifier: Handle user updates. | pending |  | Review against local BE/FE behavior, then update this row. |
| `2f4854493` | 2025-12-23 | lain | Merge branch 'akkoma-fixes-1014-1018' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3f9466e3a` | 2025-12-23 | Mark Felder | Update Hackney, the default HTTP client, to the latest release which supports Happy Eyeballs for improved IPv6 federation | pending |  | Review against local BE/FE behavior, then update this row. |
| `cdd6df062` | 2025-12-25 | lain | Merge branch 'hackney-bump' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `03210f487` | 2025-10-09 | Oneric | provide full replies collection in ActivityPub objects | pending |  | Review against local BE/FE behavior, then update this row. |
| `4288e2780` | 2025-10-09 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add changelog entry | pending |  | Review against local BE/FE behavior, then update this row. |
| `73b446bb0` | 2025-12-24 | Lain Soykaf | ActivityPubControllerTest, UserViewTest: Add failing tests for reply collection related issues. | pending |  | Review against local BE/FE behavior, then update this row. |
| `4c537534a` | 2025-12-24 | Lain Soykaf | NoteHandlingTest: Replies go on an object, not an activity. | pending |  | Review against local BE/FE behavior, then update this row. |
| `fc15c2588` | 2025-12-25 | Lain Soykaf | Transmogrifier: Only set replies on objects, not activities. | pending |  | Review against local BE/FE behavior, then update this row. |
| `8e94c5ca3` | 2025-12-25 | Lain Soykaf | UserView: Followers != Follows | pending |  | Review against local BE/FE behavior, then update this row. |
| `e07b3d244` | 2025-12-25 | Lain Soykaf | ObjectView: Make the first reply collection a page, so it shows the actual items. | pending |  | Review against local BE/FE behavior, then update this row. |
| `916c8c058` | 2025-12-25 | Lain Soykaf | ActivityPubController: Don't crash on unknown params | pending |  | Review against local BE/FE behavior, then update this row. |
| `1a313fa30` | 2025-12-25 | lain | Merge branch 'replies_collection' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `23cb42a43` | 2025-12-26 | lain | Revert "Merge branch 'hackney-bump' into 'develop'" | pending |  | Review against local BE/FE behavior, then update this row. |
| `d6888e24e` | 2025-12-26 | lain | Merge branch 'revert-cdd6df06' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `19add4036` | 2025-12-29 | Lain Soykaf | Mix: Bump version to 2.10 | pending |  | Review against local BE/FE behavior, then update this row. |
| `325c29c3f` | 2025-12-29 | Lain Soykaf | Static: Update bundled frontend to 2.10 | pending |  | Review against local BE/FE behavior, then update this row. |
| `0127a1062` | 2025-12-29 | Lain Soykaf | Changelog: Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `c2b40659e` | 2025-12-22 | Phantasm | MastoAPI: Fix misattribution when fetching status by Activity FlakeID | pending |  | Review against local BE/FE behavior, then update this row. |
| `01ffaba3d` | 2025-12-23 | Phantasm | MastoAPI: Fix unauth visibility checks when fetching by Activity FlakeID | pending |  | Review against local BE/FE behavior, then update this row. |
| `b9601ae11` | 2025-12-23 | Phantasm | MastoAPI: Add Announce and EmojiReact attribution tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `ba8235ef5` | 2025-12-23 | Phantasm | lint | pending |  | Review against local BE/FE behavior, then update this row. |
| `7c93cd351` | 2025-12-23 | Phantasm | MastoAPI StatusController: add tests for fetching context via Activity | pending |  | Review against local BE/FE behavior, then update this row. |
| `df375662d` | 2025-12-23 | Phantasm | AP: simplify visible_for_user? conditions. | pending |  | Review against local BE/FE behavior, then update this row. |
| `07849927d` | 2025-12-23 | Phantasm | add changelogs | pending |  | Review against local BE/FE behavior, then update this row. |
| `96de44b3d` | 2025-12-25 | Phantasm | Tests AP Factory: fix featured collection factories | pending |  | Review against local BE/FE behavior, then update this row. |
| `38b3bff4e` | 2025-12-25 | Phantasm | MastoAPI: Add more post attribution tests when fetched by Activity ID | pending |  | Review against local BE/FE behavior, then update this row. |
| `6c73ebe48` | 2025-12-29 | Lain Soykaf | Merge branch 'phnt/mastoapi-misattribution-3381' into release/2.10-sec | pending |  | Review against local BE/FE behavior, then update this row. |
| `c313c15d7` | 2025-12-29 | Lain Soykaf | Mix: Fix version | pending |  | Review against local BE/FE behavior, then update this row. |
| `e204bc150` | 2025-12-29 | Lain Soykaf | Merge branch 'release/2.10' into release/2.10-sec | pending |  | Review against local BE/FE behavior, then update this row. |
| `b9e333c30` | 2025-12-29 | Lain Soykaf | Frontend: Actually use the correct build. | pending |  | Review against local BE/FE behavior, then update this row. |
| `92fc8f001` | 2025-12-29 | Lain Soykaf | Merge branch 'release/2.10' into release/2.10-sec | pending |  | Review against local BE/FE behavior, then update this row. |
| `a5da6ce58` | 2025-12-31 | Lain Soykaf | Changelog: Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `5337a0e22` | 2025-10-23 | Mark Felder | Enable expiration of CICD job artifacts | pending |  | Review against local BE/FE behavior, then update this row. |
| `aab65fe85` | 2025-10-23 | Mark Felder | GitLab support for default artifacts setting is broken | pending |  | Review against local BE/FE behavior, then update this row. |
| `a39f08242` | 2025-10-23 | Mark Felder | CI: Allow running pipelines from web or directly for a tag | pending |  | Review against local BE/FE behavior, then update this row. |
| `ea38015c9` | 2025-10-23 | Mark Felder | CI: use triggers for docs and api-docs deployments | pending |  | Review against local BE/FE behavior, then update this row. |
| `464fb3fb6` | 2025-10-23 | Mark Felder | Fix branch names for pleroma/docs and pleroma/api-docs triggers | pending |  | Review against local BE/FE behavior, then update this row. |
| `929ed42a4` | 2025-10-23 | Mark Felder | CI: Use the dotenv report method to capture the spec-build internal job id and pass it through to the spec-deploy job | pending |  | Review against local BE/FE behavior, then update this row. |
| `5bc454c26` | 2025-10-24 | feld | Merge branch 'merge-stable' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e1e16656c` | 2025-12-31 | Lain Soykaf | Merge in stable | pending |  | Review against local BE/FE behavior, then update this row. |
| `856bd7622` | 2025-12-31 | Lain Soykaf | GitlabCI: Fix. | pending |  | Review against local BE/FE behavior, then update this row. |
| `3b99bbd95` | 2025-12-31 | lain | Merge branch 'release/2.10' into 'stable' | pending |  | Review against local BE/FE behavior, then update this row. |
| `3d42219f1` | 2025-12-31 | lain | Merge branch '2.10-mergeback' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `db48aa5cd` | 2025-12-31 | Lain Soykaf | Installation: Add Release-Via-Docker option | pending |  | Review against local BE/FE behavior, then update this row. |
| `e3bdb8ef5` | 2026-01-01 | Lain Soykaf | Release-to-Docker: Add unzip / curl to make updates work | pending |  | Review against local BE/FE behavior, then update this row. |
| `009e63d20` | 2026-01-01 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `f1d588fd6` | 2026-01-06 | lain | Merge branch 'release-to-docker' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `033618b25` | 2026-01-05 | Lain Soykaf | TransmogrifierTest: Add failing test for EmojiReact url encoding | implemented | EmojiReact URL-encoding regression coverage is represented by the centralized emoji URL/tag handling and local custom emoji reaction tests. | No recheck unless EmojiReact custom emoji URLs regress. |
| `bac607c7c` | 2026-01-05 | Lain Soykaf | Emoji: Unify tag building, fix tests. | implemented | Emoji.build_emoji_tag/1 is present and Builder/Transmogrifier use it instead of hand-built emoji tags. | No recheck. |
| `2c20b3fc0` | 2026-01-05 | Lain Soykaf | Add changelog | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries the Unfathomably-facing release note instead. | No code action. |
| `19f3e2050` | 2026-01-06 | Lain Soykaf | Emoji: Handle more edge cases for local emoji with strange filenames. | implemented | Emoji.local_url/1 is present and callsites use it for local custom emoji paths with unusual filenames. | No recheck. |
| `ee19d14b0` | 2026-01-06 | Lain Soykaf | Linting | not-applicable | Upstream lint-only commit in the rate-limit cluster; local implementation is already warning-clean in the touched modules. | No code action. |
| `3ef98652f` | 2026-01-07 | Lain Soykaf | Emoji, AccountView, UtilController: Handle encoding of emoji | implemented | Account rendering, custom emoji listing, bookmark folders, util emoji output, and ActivityPub emoji tags encode local/remote emoji URLs. | No recheck. |
| `9ed6d78cb` | 2026-01-07 | Lain Soykaf | Linting | not-applicable | Upstream lint-only commit in the emoji URL cluster; local code already contains the semantic fix. | No code action. |
| `2620b89cb` | 2026-01-07 | lain | Merge branch 'issue-3389-emoji-react-encode' into 'develop' | implemented | Merge commit for the emoji URL-escape cluster; covered by the individual emoji rows above. | No recheck. |
| `0ec0ad855` | 2026-01-07 | floatingghost | paginate follow requests (#460) | implemented | Follow-request pagination was already backported and documented in CHANGELOG.md. | No recheck unless follow-request pagination regresses. |
| `7b134e7aa` | 2026-01-07 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | optimize follow_request_count for own account view | implemented | Own-account follow-request count optimization was already backported and documented in CHANGELOG.md. | No recheck. |
| `b2469404a` | 2026-01-07 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add changelog entry | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries the Unfathomably-facing release note instead. | No code action. |
| `792d47377` | 2026-01-08 | Haelwenn | Merge branch 'paginate-follow-requests' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `227c7fafa` | 2026-01-07 | Lain Soykaf | Tests: Syncify tests that mutate global state. | deferred | Test synchronization only; no runtime behavior. Review only if the affected global-state tests become flaky locally. | No runtime action. |
| `100cfe4db` | 2026-01-08 | Lain Soykaf | Config: Make streaming in tests actually synchronous | pending |  | Review against local BE/FE behavior, then update this row. |
| `3ecc861fa` | 2026-01-08 | Lain Soykaf | StripLocation, ReadDescription: Silence noisy errors. | pending |  | Review against local BE/FE behavior, then update this row. |
| `07b0e6c1d` | 2026-01-08 | Lain Soykaf | Mix: Silence migrations | pending |  | Review against local BE/FE behavior, then update this row. |
| `0b498833c` | 2026-01-08 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `4984aaa18` | 2026-01-08 | Lain Soykaf | Streamer: Fix Marker streaming bug, fix caching in tests. | pending |  | Review against local BE/FE behavior, then update this row. |
| `c945a8a46` | 2026-01-11 | lain | Merge branch 'less-flaky-tests' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `e671ca255` | 2026-01-07 | Phantasm | Add Oban Web and upgrade LiveView, plug | deferred | LiveView/Plug versions are already newer locally, but Oban Web adds a new dashboard dependency and route surface not enabled in this pass. | Decide separately whether to ship Oban Web after dependency/licensing/security review. |
| `30839063e` | 2026-01-07 | Phantasm | changelog | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries Unfathomably release notes. | No code action. |
| `619ff5b9e` | 2026-01-08 | Phantasm | Remove /pleroma/oban and /phoenix/live_dashboard from API routes | implemented | Dashboard routes are filtered out of generated API route metadata so frontend/admin route overrides do not misclassify them. | No recheck. |
| `39279292b` | 2026-01-08 | Phantasm | Docs: Add admin documentation for LiveDashboard and Oban Web | deferred | The upstream documentation partly describes Oban Web, which is not enabled locally in this pass. | Add adapted dashboard docs if Oban Web is later accepted. |
| `5e114931f` | 2026-01-09 | Phantasm | Move LiveDashboard to /pleroma/live_dashboard | implemented | LiveDashboard now mounts at /pleroma/live_dashboard and the legacy /phoenix/live_dashboard path redirects there. | No recheck. |
| `9fcf918e1` | 2026-01-11 | lain | Merge branch 'phnt/oban-web' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `05704ec86` | 2026-01-14 | Haelwenn (lanodan) Monnier | mix: upgrade vix from "~> 0.26.0" to "~> 0.36" | pending |  | Review against local BE/FE behavior, then update this row. |
| `6001ed39f` | 2026-01-14 | lain | Merge branch 'vix-0.36.0' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `aa95855a7` | 2026-01-11 | MediaFormat | Change redirect_uris to accept array of strings | pending |  | Review against local BE/FE behavior, then update this row. |
| `7da1d429a` | 2026-01-11 | MediaFormat | add changelog.d entry | pending |  | Review against local BE/FE behavior, then update this row. |
| `87f3459f8` | 2026-01-11 | MediaFormat | fix field type, fix formatting | pending |  | Review against local BE/FE behavior, then update this row. |
| `12002830b` | 2026-01-11 | MediaFormat | fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `4df7f93a2` | 2026-01-16 | Lain Soykaf | Fix OAuth registration redirect_uris array support | pending |  | Review against local BE/FE behavior, then update this row. |
| `09aad75b3` | 2026-01-16 | lain | Merge branch 'fix-oauth-app-registration' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `656c4368d` | 2026-01-16 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into pleroma-instance-domain-blocks | pending |  | Review against local BE/FE behavior, then update this row. |
| `e91bb2144` | 2026-01-16 | Lain Soykaf | InstanceView: Omit comment if it's empty | pending |  | Review against local BE/FE behavior, then update this row. |
| `c920241c0` | 2026-01-16 | lain | Merge branch 'instance-domain-blocks' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `1af899746` | 2026-01-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | do not ever allow setting database_config_whitelist to database | pending |  | Review against local BE/FE behavior, then update this row. |
| `57a3b1f6d` | 2026-01-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add sane defaults for :database_config_whitelist | pending |  | Review against local BE/FE behavior, then update this row. |
| `f0669997d` | 2026-01-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add test for default whitelist config | pending |  | Review against local BE/FE behavior, then update this row. |
| `b66b93a94` | 2026-01-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add task for filtering non-whitelisted configs | pending |  | Review against local BE/FE behavior, then update this row. |
| `92fd157cd` | 2026-01-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Update cheatsheet | pending |  | Review against local BE/FE behavior, then update this row. |
| `49985b161` | 2026-01-16 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Update tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `77a1d79f9` | 2026-01-17 | Lain Soykaf | ConfigTest: Don't crash when whitelist is unset / disabled | pending |  | Review against local BE/FE behavior, then update this row. |
| `0b871ff1f` | 2026-01-17 | Lain Soykaf | ConfigController: Don't allow updating the whitelist | pending |  | Review against local BE/FE behavior, then update this row. |
| `49f9ab303` | 2026-01-17 | Lain Soykaf | Cheatsheet: Fix double slash | pending |  | Review against local BE/FE behavior, then update this row. |
| `117b0bd79` | 2026-01-17 | Lain Soykaf | Config: Don't crash on falsy whitelist config | pending |  | Review against local BE/FE behavior, then update this row. |
| `a4fb651fa` | 2026-01-17 | Lain Soykaf | ConfigController: Don't allow whitelist modification. | pending |  | Review against local BE/FE behavior, then update this row. |
| `e09134971` | 2025-12-26 | lain | Revert "Merge branch 'revert-cdd6df06' into 'develop'" | pending |  | Review against local BE/FE behavior, then update this row. |
| `ef0f04ca4` | 2026-01-16 | Lain Soykaf | http(hackney): disable adapter redirects by default | pending |  | Review against local BE/FE behavior, then update this row. |
| `52fc344b0` | 2026-01-16 | Lain Soykaf | test(http): cover pooled redirect with hackney | pending |  | Review against local BE/FE behavior, then update this row. |
| `e67b4cd8b` | 2026-01-16 | Lain Soykaf | test(http): reproduce hackney follow_redirect crash via CONNECT proxy | pending |  | Review against local BE/FE behavior, then update this row. |
| `9b1941366` | 2026-01-16 | Mark Felder | In-house redirect handler for mediaproxy with Hackney adapter | pending |  | Review against local BE/FE behavior, then update this row. |
| `1a6a8f6fb` | 2026-01-16 | Lain Soykaf | test(http): cover reverse proxy redirects via CONNECT proxy | pending |  | Review against local BE/FE behavior, then update this row. |
| `346014b89` | 2026-01-16 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into revert-d6888e24 | pending |  | Review against local BE/FE behavior, then update this row. |
| `e7d2d9bd8` | 2026-01-17 | Lain Soykaf | mrf(media_proxy_warming): avoid adapter-level redirects | pending |  | Review against local BE/FE behavior, then update this row. |
| `a7a3978a2` | 2026-01-17 | lain | Merge branch 'revert-d6888e24' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `54092d2b7` | 2026-01-25 | Phantasm | Docs: Remove outdated, incorrect, inappropriate or unmaintained install docs | pending |  | Review against local BE/FE behavior, then update this row. |
| `d6bec8b6b` | 2026-01-25 | lain | Merge branch 'delete-outdated-docs' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `80ede85f7` | 2026-01-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Allow assigning users to reports | pending |  | Review against local BE/FE behavior, then update this row. |
| `055242f43` | 2026-01-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'assign-users' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `6fac6ff7f` | 2026-01-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | MastoAPI AccountView: Add mute/block expiry to the relationship object | pending |  | Review against local BE/FE behavior, then update this row. |
| `e7a4d5ea6` | 2026-01-28 | Phantasm | MastoAPI AccountView: Add mute/block expiry to the relationship key | pending |  | Review against local BE/FE behavior, then update this row. |
| `c1e33bfad` | 2026-01-28 | Phantasm | MastoAPI AccountView AccountController: Add more block/mute expiry tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `bc0c7fb31` | 2026-01-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Fix tests, relationship should always define `_expires_at` | pending |  | Review against local BE/FE behavior, then update this row. |
| `5001fb3a7` | 2026-01-28 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Update changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `833e9829b` | 2026-01-30 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'relationship-expires-at' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `bd30d461b` | 2026-01-30 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add /api/v2/instance profile fields limits info used by Mastodon | pending |  | Review against local BE/FE behavior, then update this row. |
| `cb78699a3` | 2026-01-30 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'instance-profile-fields' into 'develop' | pending |  | Review against local BE/FE behavior, then update this row. |
| `feda4d071` | 2026-02-09 | Lain Soykaf | CI: Add basic woodpecker file | pending |  | Review against local BE/FE behavior, then update this row. |
| `4693dc837` | 2026-02-09 | Lain Soykaf | CI: Only run on PR | pending |  | Review against local BE/FE behavior, then update this row. |
| `ec6ffa4fd` | 2026-02-09 | lain | Merge pull request 'CI: Add basic woodpecker file' (#7816) from woodpecker-ci into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `1c685ea41` | 2026-02-12 | feld | Update README.md | pending |  | Review against local BE/FE behavior, then update this row. |
| `e32ab8aef` | 2026-02-22 | Phantasm | DB prune: Check if user follows hashtag with no objects before deletion | pending |  | Review against local BE/FE behavior, then update this row. |
| `ef7be0a1e` | 2026-02-22 | Phantasm | DB prune: Add test for hashtags | pending |  | Review against local BE/FE behavior, then update this row. |
| `588bc656f` | 2026-02-22 | Phantasm | Merge pull request #7751 from gitlab-mr-iid-4374 into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `a9b5a28c2` | 2026-02-27 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Do not use Enum.map for side-effects | pending |  | Review against local BE/FE behavior, then update this row. |
| `9040f97ce` | 2026-03-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Do not use Enum.map for side-effects' (#7840) from mkljczk/pleroma:map-side-effects into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `c392b21db` | 2026-02-27 | mkljczk | Update docs on scrobbles | pending |  | Review against local BE/FE behavior, then update this row. |
| `38c30d50b` | 2026-03-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Update docs on scrobbles' (#7836) from mkljczk/pleroma:docs-scrobble into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `3d9ac413a` | 2026-02-17 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Move avatar_description and header_description fields to the account object | pending |  | Review against local BE/FE behavior, then update this row. |
| `6405a2e68` | 2026-03-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Move avatar_description and header_description fields to the account object' (#7828) from mkljczk/pleroma:avatar-description-mastodon-api into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `938ee4cb0` | 2026-02-27 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | mix.exs: use correct override value | pending |  | Review against local BE/FE behavior, then update this row. |
| `d389359ec` | 2026-03-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'mix.exs: use correct override value' (#7838) from mkljczk/pleroma:mix-exs-fix into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `b798f7d6e` | 2026-02-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Add issue and pull request templates for Forgejo | pending |  | Review against local BE/FE behavior, then update this row. |
| `0b950f625` | 2026-02-18 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | comment out stuff | pending |  | Review against local BE/FE behavior, then update this row. |
| `36a79ab58` | 2026-03-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Add issue and pull request templates for Forgejo' (#7819) from mkljczk/pleroma:forgejo-templates into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `c3b779036` | 2026-03-01 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'develop' into pleroma-database-config-whitelist | pending |  | Review against local BE/FE behavior, then update this row. |
| `3620726ff` | 2026-03-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Add sane defaults for :database_config_whitelist, add a task to remove non-whitelisted configs' (#7837) from pleroma-database-config-whitelist into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `37041aae6` | 2026-03-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | update mix.exs deps versions to match mix.lock so they don't look that scary | pending |  | Review against local BE/FE behavior, then update this row. |
| `68de46339` | 2026-03-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'update mix.exs deps versions to match mix.lock so they don't look that scary' (#7839) from mkljczk/pleroma:mix-exs-update into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `490cd33bc` | 2026-03-03 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Support lists `exclusive` param | pending |  | Review against local BE/FE behavior, then update this row. |
| `0592f111f` | 2026-03-06 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | update tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `2e80c786b` | 2026-02-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Update comment for prepare_object, rename prepare_outgoing | pending |  | Review against local BE/FE behavior, then update this row. |
| `65c7d0c7b` | 2026-03-03 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Update comment for prepare_object, rename prepare_outgoing' (#7818) from mkljczk/pleroma:update-comment into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `ca3821789` | 2026-03-03 | Phantasm |  Fix AccountController Plug warning | pending |  | Review against local BE/FE behavior, then update this row. |
| `222306ff2` | 2026-03-03 | Phantasm | Merge pull request 'Fix AccountController Plug warning from typo' (#7848) from phnt/pleroma:plug-test-typo into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `120719f28` | 2026-02-27 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Don't use the confusing TwitterAPI namespace | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b182b07d` | 2026-03-03 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | is this what i was meant to do? | pending |  | Review against local BE/FE behavior, then update this row. |
| `19025563e` | 2026-03-03 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | fixes | pending |  | Review against local BE/FE behavior, then update this row. |
| `499b2ed11` | 2026-03-06 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | remove unused alias | pending |  | Review against local BE/FE behavior, then update this row. |
| `a1bb81bdd` | 2026-03-06 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Don't use the confusing TwitterAPI namespace' (#7841) from mkljczk/pleroma:twitter-api-removal into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `2086561fb` | 2026-03-02 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Various bookmark folders-related improvements | pending |  | Review against local BE/FE behavior, then update this row. |
| `40bc79e5c` | 2026-03-06 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Various bookmark folders-related improvements' (#7829) from mkljczk/pleroma:bookmark-folders into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `eed4f4bba` | 2026-02-17 | Phantasm | Gopher: Fix crash on (re)boot when ConfigDB is enabled | pending |  | Review against local BE/FE behavior, then update this row. |
| `d95d7f6eb` | 2026-03-08 | Phantasm | Merge pull request 'Gopher: Fix crash on (re)boot when ConfigDB is enabled' (#7826) from fix-gopher-crash into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `d1787966a` | 2026-03-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge branch 'develop' into exclusive-lists | pending |  | Review against local BE/FE behavior, then update this row. |
| `70de4491c` | 2026-03-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Support lists `exclusive` param' (#7831) from mkljczk/pleroma:exclusive-lists into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `87b4e3f3f` | 2026-03-06 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Avoid code duplication in UserView | pending |  | Review against local BE/FE behavior, then update this row. |
| `37cb2f927` | 2026-03-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Avoid code duplication in UserView' (#7817) from mkljczk/pleroma:user-view-repeat into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `f80c5744b` | 2026-02-12 | Phantasm | Normalize Hubzilla alsoKnownAs from string to array | pending |  | Review against local BE/FE behavior, then update this row. |
| `d0ef58a59` | 2026-03-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Normalize Hubzilla alsoKnownAs from string to array' (#7821) from phnt/pleroma:normalize-alsoKnownAs into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `b645643cf` | 2026-03-03 | Oneric | Merge pull request 'Allow fine-grained announce visibilities' (#941) from Oneric/akkoma:announce-visibility into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `8921dbfff` | 2026-03-03 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `6bbfba7f6` | 2026-03-21 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Allow fine-grained announce visibilities (ported from Akkoma)' (#7832) from mkljczk/pleroma:boost-visibilities into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `2937bb68b` | 2026-03-25 | Mark Felder | Fix MoveTokensExpirationIntoOban migration | pending |  | Review against local BE/FE behavior, then update this row. |
| `f3f72048a` | 2026-03-25 | Mark Felder | Fix MoveActivityExpirationsToOban migration | pending |  | Review against local BE/FE behavior, then update this row. |
| `e1a1e5c72` | 2026-03-25 | Mark Felder | Correct old migrations for expiring activities and user access tokens. | pending |  | Review against local BE/FE behavior, then update this row. |
| `dc7bd8296` | 2026-03-25 | feld | Merge pull request 'Correct old migrations for expiring activities and user access tokens' (#7862) from fix-old-migrations into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `dfaabb48e` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violation on struct updates in Pleroma.Marker | pending |  | Review against local BE/FE behavior, then update this row. |
| `1b9cd83d8` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violation on struct updates in MFA.Changeset | pending |  | Review against local BE/FE behavior, then update this row. |
| `5b6af83e8` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violation on struct updates in Pleroma.Upload | pending |  | Review against local BE/FE behavior, then update this row. |
| `19e05b4a7` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violation on struct updates in Web.ApiSpec.Cast* | pending |  | Review against local BE/FE behavior, then update this row. |
| `958d250fe` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violation on struct updates in Web.ApiSpec.Rend* | pending |  | Review against local BE/FE behavior, then update this row. |
| `8417629b4` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violation on struct updates in CommonAPI.Activity* | pending |  | Review against local BE/FE behavior, then update this row. |
| `93e8f9d7d` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violations in ActivityPubTest | pending |  | Review against local BE/FE behavior, then update this row. |
| `b8a66c22b` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violation in MediaControllerTest | pending |  | Review against local BE/FE behavior, then update this row. |
| `ec294b30c` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violation in RepoTest | pending |  | Review against local BE/FE behavior, then update this row. |
| `f4c28392e` | 2026-03-25 | Phantasm | Elixir 1.19: Fix typing violation in MarkerTest | pending |  | Review against local BE/FE behavior, then update this row. |
| `f60a317c2` | 2026-03-25 | Phantasm | Elixir 1.19: Only match once on structs | pending |  | Review against local BE/FE behavior, then update this row. |
| `531041041` | 2026-03-25 | Phantasm | Elixir 1.19: Fix deprecation warning when invoking ParallelCompiler | pending |  | Review against local BE/FE behavior, then update this row. |
| `bf86768e8` | 2026-03-25 | Phantasm | Elixir 1.19: Fix ConfigDBTest regex tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `6a3b5b321` | 2026-03-25 | Phantasm | Elixir 1.19: Fix MRFTest regex tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `a9ad6297b` | 2026-03-25 | Phantasm | Elixir 1.19: Fix Mastodon StatusControllerTest DateTime difference | pending |  | Review against local BE/FE behavior, then update this row. |
| `ee5576450` | 2026-03-25 | Phantasm | lint | pending |  | Review against local BE/FE behavior, then update this row. |
| `645211812` | 2026-03-25 | Phantasm | Elixir 1.19 MRFTest: Replace matchable_regexes with regexes_match! func | pending |  | Review against local BE/FE behavior, then update this row. |
| `750266f2e` | 2026-03-25 | Phantasm | ActivityDraft: Add missing __MODULE__ matches and drop unneeded ones | pending |  | Review against local BE/FE behavior, then update this row. |
| `cbb715b97` | 2026-03-25 | Mark Felder | No-op code correctness improvements detected by Elixir 1.19 compiler | pending |  | Review against local BE/FE behavior, then update this row. |
| `85d311adc` | 2026-03-25 | feld | Merge pull request 'No-op code correctness improvements detected by Elixir 1.19 compiler' (#7863) from elixir-1.19-cherrypick into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `a0131ff73` | 2026-03-08 | Phantasm | credo: fix ordering of aliases missed in pleroma/pleroma!7841 | pending |  | Review against local BE/FE behavior, then update this row. |
| `93d05efdb` | 2026-03-25 | feld | Merge pull request 'credo: fix ordering of aliases missed in pleroma/pleroma!7841' (#7852) from phnt/pleroma:credo-alias-fixes into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `4e1ba489e` | 2026-03-08 | shibao | fix 404s for missing static files | pending |  | Review against local BE/FE behavior, then update this row. |
| `bceb28b94` | 2026-03-08 | shibao | add changelog note for missing static files fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `876913d2a` | 2026-03-25 | feld | Merge pull request 'Fix error codes for missing static files' (#7850) from shibao/pleroma:static-fix into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `699a7e57e` | 2026-02-17 | Phantasm | Fix LiveDashboard redirect not working when user added a path segment | pending |  | Review against local BE/FE behavior, then update this row. |
| `eabfb2bd4` | 2026-03-25 | feld | Merge pull request 'Fix LiveDashboard redirect not working when user added a path segment' (#7830) from live-dashboard-fix-redirect into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `23cc81236` | 2026-03-19 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Restore embed route | pending |  | Review against local BE/FE behavior, then update this row. |
| `106a52eb2` | 2026-03-25 | feld | Merge pull request 'Restore embed route' (#7857) from mkljczk/pleroma:restore-embeds into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `23a4d68c9` | 2026-02-22 | Phantasm | ReverseProxy: Follow redirects recursively until redirect_limit | pending |  | Review against local BE/FE behavior, then update this row. |
| `cbc2ea331` | 2026-02-22 | Phantasm | typo | pending |  | Review against local BE/FE behavior, then update this row. |
| `95c8b4732` | 2026-02-22 | Phantasm | ReverseProxy Hackney: Add redirect handling logging | pending |  | Review against local BE/FE behavior, then update this row. |
| `d1bd24ba6` | 2026-03-25 | feld | Merge pull request 'ReverseProxy: Follow redirects recursively until redirect_limit' (#7812) from gitlab-mr-iid-4435 into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `9ede9b92d` | 2026-01-06 | Lain Soykaf | RateLimiterTest: Add failing test for invalid values. | implemented | RateLimiter invalid-value behavior is covered by the local RateLimit type and fallback-to-default normalization path. | No recheck unless rate-limit config crashes. |
| `958a4581d` | 2026-01-06 | Lain Soykaf | RateLimiter: Ensure that the rate limiter doesn't crash on bad values | implemented | RateLimiter fetch_and_normalize_limits/1 handles invalid configured limits without crashing and falls back to defaults or disables the limiter. | No recheck. |
| `47f4bde0e` | 2026-01-06 | Lain Soykaf | ConfigDBTest: Add failing test for invalid rate limiter values. | implemented | ConfigDB validates stored :rate_limit values through Pleroma.EctoType.Config.RateLimit. | No recheck. |
| `bd6191627` | 2026-01-06 | Lain Soykaf | ConfigDB, RateLimiter, RateLimit: Use new type to parse and cast rate limits. | implemented | Pleroma.EctoType.Config.RateLimit exists and both ConfigDB and RateLimiter use it. | No recheck. |
| `b9c281a0c` | 2026-01-06 | Lain Soykaf | Add changelog | not-applicable | Upstream changelog-only commit; local CHANGELOG.md carries the Unfathomably-facing release note instead. | No code action. |
| `63c9c7ea9` | 2026-03-25 | feld | Merge pull request 'Harden rate limiter to deal with configuration issues' (#7795) from gitlab-mr-iid-4418 into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `627c944fe` | 2024-06-26 | Mark Felder | Search Indexing: filter indexable activities before inserting Oban jobs | pending |  | Review against local BE/FE behavior, then update this row. |
| `a5c88eb39` | 2024-06-26 | Mark Felder | Remove redundant checks from backends' add_to_index/1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `77436451a` | 2024-06-26 | Mark Felder | Indexable changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `7c09150cd` | 2024-06-26 | Mark Felder | Validate the activity is public before indexing | pending |  | Review against local BE/FE behavior, then update this row. |
| `592955a89` | 2024-06-26 | Mark Felder | Improve add_to_index/1 when there is no Object | pending |  | Review against local BE/FE behavior, then update this row. |
| `7cc9ba6f0` | 2026-03-25 | Mark Felder | Merge remote-tracking branch 'origin/develop' into gitlab-mr-iid-4161 | pending |  | Review against local BE/FE behavior, then update this row. |
| `711b33d81` | 2026-03-25 | Mark Felder | Fix CommonAPI.favorite/2 arg order | pending |  | Review against local BE/FE behavior, then update this row. |
| `1d819195b` | 2026-03-25 | feld | Merge pull request 'Search: filter indexable activities before inserting Oban jobs' (#7538) from gitlab-mr-iid-4161 into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `ea78e7683` | 2026-03-25 | Mark Felder | Fix add_to_index/1 to adhere to the typespec | pending |  | Review against local BE/FE behavior, then update this row. |
| `f06a0eab5` | 2026-03-25 | Mark Felder | Move object_to_search_data/1 to Pleroma.Search | pending |  | Review against local BE/FE behavior, then update this row. |
| `9af26e5fb` | 2026-03-25 | feld | Merge pull request 'Additional Search Indexing cleanup' (#7864) from search-indexing into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `5aa3c8a06` | 2026-03-26 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Federate `votersCount` correctly | pending |  | Review against local BE/FE behavior, then update this row. |
| `9e22baa66` | 2026-03-26 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Federate `votersCount` correctly' (#7858) from mkljczk/pleroma:poll-voters-count into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `848b3f5d5` | 2026-03-05 | Yonle | reverse_proxy,endpoint,uploaded_media: add immutable cache-control flag | pending |  | Review against local BE/FE behavior, then update this row. |
| `970e0f904` | 2026-03-05 | Yonle | endpoint: set cache control for favicon.png | pending |  | Review against local BE/FE behavior, then update this row. |
| `8abd25950` | 2026-03-05 | Yonle | endpoint: use favicon plug | pending |  | Review against local BE/FE behavior, then update this row. |
| `4bc0b26ab` | 2026-03-05 | Yonle | changelog.d: add cache-control-immutable | pending |  | Review against local BE/FE behavior, then update this row. |
| `0879dd395` | 2026-03-05 | Yonle | endpoint: reorder: handle favicon plug first | pending |  | Review against local BE/FE behavior, then update this row. |
| `96f252023` | 2026-03-05 | Yonle | constants: remove favicon.png from static_only_files | pending |  | Review against local BE/FE behavior, then update this row. |
| `897512968` | 2026-03-05 | Yonle | webplug(favicon): remove check on url path. | pending |  | Review against local BE/FE behavior, then update this row. |
| `d03ae43ee` | 2026-03-05 | Phantasm | Favicon Plug: Simplify and pass when not requesting favicon | pending |  | Review against local BE/FE behavior, then update this row. |
| `2388964b1` | 2026-03-05 | Phantasm | Favicon Plug: Add tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `662c9f36a` | 2026-03-05 | Phantasm | Favicon Plug: Update moduledoc and rename to adhere to convention | pending |  | Review against local BE/FE behavior, then update this row. |
| `d0db1f00c` | 2026-03-05 | Phantasm | Favicon Plug: assert HTTP 200 status in tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f321b0b5` | 2026-03-05 | Phantasm | Favicon Plug: Halt Plug pipeline when favicon not found | pending |  | Review against local BE/FE behavior, then update this row. |
| `376048081` | 2026-03-05 | Phantasm | lint | pending |  | Review against local BE/FE behavior, then update this row. |
| `9db47790b` | 2026-03-26 | feld | Merge pull request 'reverse_proxy,endpoint,uploaded_media: add immutable cache-control flag' (#7835) from Yonle/pleroma:develop into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `c8baad165` | 2026-03-31 | Phantasm | lint: fix warnings throughout codebase | pending |  | Review against local BE/FE behavior, then update this row. |
| `eb6957615` | 2026-03-31 | Phantasm | fix test after embed route got added back | pending |  | Review against local BE/FE behavior, then update this row. |
| `f13842381` | 2026-03-31 | Phantasm | Merge pull request 'lint-warnings' (#7867) from phnt/pleroma:lint-warnings into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `a9fe2fe4d` | 2026-03-31 | Phantasm | Move main Woodpecker file to own directory | pending |  | Review against local BE/FE behavior, then update this row. |
| `88a349f3a` | 2026-03-31 | Phantasm | Woodpecker CI: Retry failed tests using pleroma.test_runner | pending |  | Review against local BE/FE behavior, then update this row. |
| `1a0af1c0c` | 2026-03-31 | Phantasm | Woodpecker CI: Add check-changelog workflow | pending |  | Review against local BE/FE behavior, then update this row. |
| `4493d0d18` | 2026-03-31 | Phantasm | Woodpecker CI: Update check-changelog script for Woodpecker | pending |  | Review against local BE/FE behavior, then update this row. |
| `2880aac61` | 2026-03-31 | Phantasm | Woodpecker CI: Unit test using Elixir 1.15 and 1.18 | pending |  | Review against local BE/FE behavior, then update this row. |
| `6f8233d78` | 2026-03-31 | Phantasm | Woodpecker CI: Add linting pipeline | pending |  | Review against local BE/FE behavior, then update this row. |
| `b67d7c110` | 2026-03-31 | Phantasm | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `0fd544722` | 2026-03-31 | Phantasm | Woodpecker: Ensure correct workflow status in lint pipeline | pending |  | Review against local BE/FE behavior, then update this row. |
| `8640fcef2` | 2026-03-31 | Phantasm | Woodpecker CI: Fix compile error on Elixir 1.18 due to wrong OTP | pending |  | Review against local BE/FE behavior, then update this row. |
| `b224a2dac` | 2026-03-31 | Phantasm | Woodpecker CI: Don't immediately fail whole lint workflow with one error | pending |  | Review against local BE/FE behavior, then update this row. |
| `265d3eeeb` | 2026-03-31 | Phantasm | Woodpecker CI: Fix syntax error in lint workflow | pending |  | Review against local BE/FE behavior, then update this row. |
| `56a25202b` | 2026-03-31 | Phantasm | Woodpecker CI: Fix credo | pending |  | Review against local BE/FE behavior, then update this row. |
| `b0de9bd3c` | 2026-03-31 | Phantasm | Woodpecker CI: Make xref use fail stamp | pending |  | Review against local BE/FE behavior, then update this row. |
| `cdcc432f3` | 2026-03-31 | Phantasm | Woodpecker CI: Lint workflow, don't use brackets in shell tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `08bf6c8fe` | 2026-03-31 | Phantasm | Woodpecker CI: Explicitely exit with non-zero exit code on fail | pending |  | Review against local BE/FE behavior, then update this row. |
| `1fe0970b6` | 2026-03-31 | Phantasm | woodpecker CI: Fix cycles in lint workflow | pending |  | Review against local BE/FE behavior, then update this row. |
| `7bba48539` | 2026-03-31 | Phantasm | Woodpecker CI: Disable cycles lint step for now since it always fails | pending |  | Review against local BE/FE behavior, then update this row. |
| `072dc39d8` | 2026-03-31 | Phantasm | Woodpecker CI: Don't depend on changelog in lint workflow | pending |  | Review against local BE/FE behavior, then update this row. |
| `096c4ea98` | 2026-03-31 | Phantasm | Woodpecker CI: Run lint and unit tests also on push to default branch | pending |  | Review against local BE/FE behavior, then update this row. |
| `fd7b809c5` | 2026-03-31 | Phantasm | Woodpecker CI: Only run lint and unit tests when relevant files changed | pending |  | Review against local BE/FE behavior, then update this row. |
| `1405f5dc8` | 2026-03-31 | Phantasm | Merge pull request 'PR Woodpecker CI workflow' (#7825) from phnt/pleroma:woodpecker-pr-ci into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `799199f6b` | 2026-03-26 | Phantasm | DigestEmailsWorker: Change Oban queue to "background" | pending |  | Review against local BE/FE behavior, then update this row. |
| `01ced6bea` | 2026-04-01 | Mark Felder | Fix the daily email digest job which was not executing | pending |  | Review against local BE/FE behavior, then update this row. |
| `a3404e91b` | 2026-04-01 | feld | Merge pull request 'DigestEmailsWorker: Change Oban queue to "background"' (#7865) from phnt/oban-digest-queue into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `fc5aea73f` | 2026-04-23 | Phantasm | Woodpecker CI: Add develop Docker image build pipeline | pending |  | Review against local BE/FE behavior, then update this row. |
| `5351cd4ce` | 2026-04-23 | Phantasm | Woodpecker CI: Add OTP develop pipeline | pending |  | Review against local BE/FE behavior, then update this row. |
| `d2f7c9252` | 2026-04-23 | Phantasm | Woodpecker CI Docker develop: Switch to kaniko | pending |  | Review against local BE/FE behavior, then update this row. |
| `e2adc796c` | 2026-04-23 | Phantasm | Woodpecker CI: Multiplatform Docker image manifests | pending |  | Review against local BE/FE behavior, then update this row. |
| `67e7f788c` | 2026-04-23 | Phantasm | Woodpecker CI Docker Develop combine: Switch to plugin | pending |  | Review against local BE/FE behavior, then update this row. |
| `13d6246ed` | 2026-04-23 | Phantasm | Woodpecker CI: Cleanup develop releases CI code duplication | pending |  | Review against local BE/FE behavior, then update this row. |
| `f00c13602` | 2026-04-23 | Phantasm | Woodpecker CI Develop: Also tag images using commit sha | pending |  | Review against local BE/FE behavior, then update this row. |
| `e002650e2` | 2026-04-23 | Phantasm | Woodpecker CI: Add Docker stable releases | pending |  | Review against local BE/FE behavior, then update this row. |
| `97a2e8c76` | 2026-04-23 | Phantasm | Woodpecker CI: Tag stable docker release with version tag | pending |  | Review against local BE/FE behavior, then update this row. |
| `42eb9706a` | 2026-04-23 | Phantasm | Woodpecker CI: Build stable OTP releases | pending |  | Review against local BE/FE behavior, then update this row. |
| `eea01b54b` | 2026-04-23 | Phantasm | Woodpecker CI: Allow running stable release jobs manually | pending |  | Review against local BE/FE behavior, then update this row. |
| `dd29b9c11` | 2026-04-23 | Phantasm | Woodpecker CI OTP: use CI_COMMIT_BRANCH variable instead of stable | pending |  | Review against local BE/FE behavior, then update this row. |
| `89a78d765` | 2026-04-23 | Phantasm | Woodpecker CI: Unify Docker image workflows | pending |  | Review against local BE/FE behavior, then update this row. |
| `d8b8cbbb8` | 2026-04-23 | Phantasm | Woodpecker CI: Shorten commit sha to eight chars | pending |  | Review against local BE/FE behavior, then update this row. |
| `5229e8ae6` | 2026-04-23 | Phantasm | Woodpecker CI: Unify OTP builds into a single worfklow | pending |  | Review against local BE/FE behavior, then update this row. |
| `2e968890d` | 2026-04-23 | Phantasm | Woodpecker CI: Remove branch requirement for tag | pending |  | Review against local BE/FE behavior, then update this row. |
| `16b7a95c4` | 2026-04-23 | Phantasm | Woodpecker CI: Run Docker image workflows also on Dockerfile changes | pending |  | Review against local BE/FE behavior, then update this row. |
| `209b9c0a1` | 2026-04-23 | Phantasm | Woodpecker CI: Shorten zip archive names further | pending |  | Review against local BE/FE behavior, then update this row. |
| `7f97e2191` | 2026-04-24 | Phantasm | pleroma_ctl: Properly handle user arguments with whitespace | pending |  | Review against local BE/FE behavior, then update this row. |
| `95a33855d` | 2026-04-24 | Phantasm | pleroma_ctl: Update update logic to Gitea API | pending |  | Review against local BE/FE behavior, then update this row. |
| `cafd75b07` | 2026-04-24 | Phantasm | Woodpecker CI docker-combine: Hoist docker_settings anchor | pending |  | Review against local BE/FE behavior, then update this row. |
| `25e543d44` | 2026-04-24 | Phantasm | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `a996d25b8` | 2026-04-25 | Phantasm | Woodpecker CI Docker: label workflow as high memory | pending |  | Review against local BE/FE behavior, then update this row. |
| `e4632eced` | 2026-04-25 | Phantasm | Woodpecker CI: Only run stable release pipelines on tag events | pending |  | Review against local BE/FE behavior, then update this row. |
| `3dbc57047` | 2026-05-02 | Lain Soykaf | Woodpecker CI: Publish update-compatible OTP releases | pending |  | Review against local BE/FE behavior, then update this row. |
| `00265751c` | 2026-04-03 | Mark Felder | Update Bandit | pending |  | Review against local BE/FE behavior, then update this row. |
| `ebfa0d88d` | 2026-04-07 | feld | Merge pull request 'Update Bandit' (#7868) from bandit into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `7582b71f4` | 2026-04-08 | Mark Felder | Downgrade Hackney to 1.20.1, before connection performance regressions | pending |  | Review against local BE/FE behavior, then update this row. |
| `683ab3916` | 2026-04-08 | feld | Merge pull request 'Downgrade Hackney' (#7860) from hackney-downgrade into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `da9cbc8e2` | 2026-05-02 | Lain Soykaf | Merge origin/develop into woodpecker-releases | pending |  | Review against local BE/FE behavior, then update this row. |
| `47e6dbfad` | 2026-05-02 | Lain Soykaf | Woodpecker CI: Work around script entrypoint truncation | pending |  | Review against local BE/FE behavior, then update this row. |
| `93c155e4f` | 2026-05-02 | lain | Merge pull request 'woodpecker-releases' (#7878) from woodpecker-releases into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `ee18feef7` | 2026-05-02 | Lain Soykaf | Woodpecker CI: Allow manual develop release runs | pending |  | Review against local BE/FE behavior, then update this row. |
| `9fdad779b` | 2026-05-02 | Lain Soykaf | Woodpecker CI: Run Docker manifest combine on amd64 | pending |  | Review against local BE/FE behavior, then update this row. |
| `50651284a` | 2026-05-02 | Lain Soykaf | Woodpecker CI: Run generic workflows on amd64 | pending |  | Review against local BE/FE behavior, then update this row. |
| `1a8d585cb` | 2026-05-03 | Lain Soykaf | Woodpecker CI: Allow rerunning OTP package uploads | pending |  | Review against local BE/FE behavior, then update this row. |
| `cb2271978` | 2026-04-30 | Phantasm | UpdateValidator: fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `af6d12c0a` | 2026-04-30 | Phantasm | UpdateValidator: Check Actor owns Object or updates itself | pending |  | Review against local BE/FE behavior, then update this row. |
| `da28a4c44` | 2026-04-30 | Phantasm | ReceiverWorker: Add cancels on actor does not match signature test | pending |  | Review against local BE/FE behavior, then update this row. |
| `42683e79d` | 2026-04-30 | Phantasm | ReceiverWorker: Check that signature matches actor | pending |  | Review against local BE/FE behavior, then update this row. |
| `80e72b79f` | 2026-04-30 | Lain Soykaf | Add spoofing regression tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `9c540995b` | 2026-04-30 | Lain Soykaf | Use Mox in spoofing regression tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `bd45704db` | 2026-04-30 | Lain Soykaf | Clarify cross-domain spoofing regressions | pending |  | Review against local BE/FE behavior, then update this row. |
| `7756f491d` | 2026-05-01 | Lain Soykaf | Split failed-signature inbox retries | pending |  | Review against local BE/FE behavior, then update this row. |
| `4337e0eb1` | 2026-05-01 | Lain Soykaf | Fail closed on unresolved signed payloads | pending |  | Review against local BE/FE behavior, then update this row. |
| `99b614a52` | 2026-05-01 | Lain Soykaf | Add spoofing fixes changelog entry | pending |  | Review against local BE/FE behavior, then update this row. |
| `a35aa6551` | 2026-05-02 | Lain Soykaf | Fix Woodpecker path filters | pending |  | Review against local BE/FE behavior, then update this row. |
| `a1f741383` | 2026-05-02 | Lain Soykaf | Merge branch 'develop' of https://git.pleroma.social/pleroma/pleroma into update-spoofing | pending |  | Review against local BE/FE behavior, then update this row. |
| `4acd8c4e7` | 2026-05-02 | Lain Soykaf | Log failed-signature retry rejections | pending |  | Review against local BE/FE behavior, then update this row. |
| `00dd1b510` | 2026-05-03 | Lain Soykaf | Add failed-signature retry regression tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `6ae02d71b` | 2026-05-03 | Lain Soykaf | Align inbox controller tests with signer mapping | pending |  | Review against local BE/FE behavior, then update this row. |
| `621d86a31` | 2026-05-03 | Lain Soykaf | Validate WebFinger nicknames against actors | implemented | WebFinger nickname validation checks actor/account consistency and preserves local generated-nickname compatibility. | No recheck. |
| `78a41dfdc` | 2026-05-03 | Lain Soykaf | Merge branch 'update-spoofing' of ssh://git.pleroma.social:22/pleroma-secteam/pleroma into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `6553ba24a` | 2026-05-03 | Lain Soykaf | Prepare 2.10.1 release | pending |  | Review against local BE/FE behavior, then update this row. |
| `2c7095d30` | 2026-05-03 | lain | Merge pull request 'Prepare 2.10.1 release' (#7879) from release/2.10.1 into stable | pending |  | Review against local BE/FE behavior, then update this row. |
| `78aef1b87` | 2026-05-03 | Lain Soykaf | Merge branch 'stable' of ssh://git.pleroma.com/pleroma/pleroma into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `8ccdd9891` | 2026-05-03 | Lain Soykaf | Prepare 2.10.2 release | pending |  | Review against local BE/FE behavior, then update this row. |
| `4230887d7` | 2026-05-03 | lain | Merge pull request 'Prepare 2.10.2 release' (#7880) from release/2.10.2 into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `af175fbdf` | 2026-05-03 | Lain Soykaf | Woodpecker CI: Build armv7 Docker images | pending |  | Review against local BE/FE behavior, then update this row. |
| `684e9ef24` | 2026-05-04 | Lain Soykaf | Woodpecker CI: Isolate armv7 Docker builds | pending |  | Review against local BE/FE behavior, then update this row. |
| `394db0dce` | 2026-05-04 | Lain Soykaf | Woodpecker CI: Target armv7 Docker runner | pending |  | Review against local BE/FE behavior, then update this row. |
| `be327ca98` | 2026-01-18 | Haelwenn (lanodan) Monnier | Switch Phoenix back to upstream | pending |  | Review against local BE/FE behavior, then update this row. |
| `6f86883cc` | 2026-01-18 | Haelwenn (lanodan) Monnier | Web: remove legacy :set_put_layout plug | pending |  | Review against local BE/FE behavior, then update this row. |
| `aec0deef8` | 2026-05-05 | Yonle | poll_view: try to read votersCount first, and then manually count local voters. | implemented | Object vote-count handling for remote votersCount was reviewed with the poll rendering cluster. | No recheck unless poll counts regress. |
| `727e9e774` | 2026-05-06 | Lain Soykaf | Fix votersCount inflation in multiple-choice polls | implemented | Poll rendering prefers remote votersCount and avoids inflating duplicate multi-option voters. | No recheck. |
| `c2fb145c5` | 2026-04-10 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | litepub-0.1.jsonld cleanup | pending |  | Review against local BE/FE behavior, then update this row. |
| `86a521352` | 2026-05-05 | lain | Merge pull request 'litepub-0.1.jsonld cleanup' (#7871) from mkljczk/pleroma:context-cleanup into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `f1249d830` | 2026-05-06 | lain | Merge branch 'develop' into pf1 | pending |  | Review against local BE/FE behavior, then update this row. |
| `c62d19198` | 2026-05-06 | Lain Soykaf | Add changelog for votersCount inflation fix | pending |  | Review against local BE/FE behavior, then update this row. |
| `2082bf729` | 2026-05-06 | lain | Merge pull request 'poll_view: try to read votersCount first, and then manually count local voters.' (#7883) from Yonle/pleroma:pf1 into develop | implemented | Poll votersCount behavior is present in PollView tests and rendering. | No recheck. |
| `487399198` | 2026-05-06 | Phantasm | Update Pleroma-FE build artifacts URL | pending |  | Review against local BE/FE behavior, then update this row. |
| `ebcc7684c` | 2026-05-06 | Phantasm | Merge pull request 'Update Pleroma-FE build artifacts URL' (#7885) from phnt/pleroma:fe-build-link into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `6b86e31e5` | 2026-05-11 | Lain Soykaf | Add backend MFM support | implemented | MFM scrubber support is present in the default scrubber policy. | No recheck. |
| `c780298ce` | 2026-05-11 | Lain Soykaf | Add changelog for MFM support | pending |  | Review against local BE/FE behavior, then update this row. |
| `47021b5ab` | 2026-05-11 | Lain Soykaf | Fix MFM validator alias ordering | pending |  | Review against local BE/FE behavior, then update this row. |
| `e1b2e788d` | 2026-05-11 | lain | Merge pull request 'Add backend MFM support' (#7889) from lambadalambda/pleroma:mfm-backend into develop | implemented | MFM parser dependency is present and local scrubbers support the upstream MFM classes/attributes. | No recheck. |
| `592be493c` | 2026-05-11 | Lain Soykaf | Use published Pleroma MFM parser package | implemented | MFM parser integration is present in the formatting stack. | No recheck. |
| `f579dc099` | 2026-05-11 | lain | Merge pull request 'Use published Pleroma MFM parser package' (#7890) from lambadalambda/pleroma:mfm-backend-hex into develop | implemented | Published pleroma_mfm_parser dependency is in mix.exs/mix.lock. | No recheck. |
| `216a00f73` | 2026-05-11 | Lain Soykaf | Merge develop into Phoenix upstream migration | pending |  | Review against local BE/FE behavior, then update this row. |
| `ab9fd3376` | 2026-05-11 | Lain Soykaf | Fix Phoenix upstream migration regressions | pending |  | Review against local BE/FE behavior, then update this row. |
| `61feb3dfc` | 2026-05-11 | Lain Soykaf | Update http_signatures to 0.1.3 | pending |  | Review against local BE/FE behavior, then update this row. |
| `7f4890b6a` | 2026-05-11 | Lain Soykaf | Add changelog for http_signatures update | pending |  | Review against local BE/FE behavior, then update this row. |
| `960c73070` | 2026-05-11 | lain | Merge pull request 'Update http_signatures to 0.1.3' (#7891) from bump/http-signatures-0.1.3 into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `8e72f4cd1` | 2026-05-11 | lain | Merge branch 'develop' into gitlab-mr-iid-4426 | pending |  | Review against local BE/FE behavior, then update this row. |
| `8a56cf5c0` | 2026-05-11 | Lain Soykaf | Clarify websocket token precedence test | pending |  | Review against local BE/FE behavior, then update this row. |
| `ea886dc36` | 2026-05-12 | Phantasm | EnsureHostMatchesPlug: Ensure Host header matches instance URI | pending |  | Review against local BE/FE behavior, then update this row. |
| `d6d0ce726` | 2026-05-12 | Phantasm | EnsureHostMatchesPlug: Add tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `90e390e45` | 2026-05-12 | Phantasm | fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `35b5447f3` | 2026-05-12 | Phantasm | EnsureHostMatchesPlug: Add more tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `6f415cf3f` | 2026-05-12 | Phantasm | EnsureHostMatchesPlug: Remove match against default scheme port | pending |  | Review against local BE/FE behavior, then update this row. |
| `6c2d8209c` | 2026-05-13 | Phantasm | SignatureRetryWorker: require validated host header | pending |  | Review against local BE/FE behavior, then update this row. |
| `95b15190d` | 2026-05-13 | Phantasm | ActivityPubController: require validated host header | pending |  | Review against local BE/FE behavior, then update this row. |
| `c19bdf381` | 2026-05-13 | Phantasm | SignatureRetryWorker: add mismatched host test, fix tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `95eef879d` | 2026-05-13 | Phantasm | ActivityPubController: add mismatched host test | pending |  | Review against local BE/FE behavior, then update this row. |
| `2b3ac2d7f` | 2026-05-13 | Phantasm | lint | pending |  | Review against local BE/FE behavior, then update this row. |
| `4810d2536` | 2026-05-13 | Phantasm | ActivityPubController: Use valid signatures in Host header test | pending |  | Review against local BE/FE behavior, then update this row. |
| `0cf865f02` | 2026-05-12 | Lain Soykaf | Reject third-party remote reports | pending |  | Review against local BE/FE behavior, then update this row. |
| `4d3aea1fc` | 2026-05-13 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Handle reports with just actor ap id as the object | pending |  | Review against local BE/FE behavior, then update this row. |
| `d8e9affde` | 2026-05-12 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Handle reports with just actor ap id as the object' (#7897) from mkljczk/pleroma:iceshrimpnet-reports-fix into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `68e4bb53a` | 2026-05-13 | Lain Soykaf | Merge branch 'develop' into fix/reject-third-party-reports | pending |  | Review against local BE/FE behavior, then update this row. |
| `e211b7292` | 2026-05-13 | lain | Merge pull request 'Reject third-party remote reports' (#7896) from fix/reject-third-party-reports into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `71afba482` | 2026-05-12 | Lain Soykaf | Signature: Treat HTTP signature errors as invalid | pending |  | Review against local BE/FE behavior, then update this row. |
| `9b331d648` | 2026-05-12 | lain | Merge branch 'develop' into bump/http-signatures-0.1.3 | implemented | HTTP signature helper checks explicit true from HTTPSignatures.validate_conn/2. | No recheck. |
| `ffff2098f` | 2026-05-13 | lain | Merge pull request 'Signatures: Only true is true.' (#7892) from bump/http-signatures-0.1.3 into develop | implemented | Signature validation only treats literal true as success before falling back to historical keys. | No recheck. |
| `71f5a493f` | 2026-01-01 | Lain Soykaf | Search: Better sorting for user searches. | pending |  | Review against local BE/FE behavior, then update this row. |
| `ee17d6413` | 2026-01-01 | Lain Soykaf | Merge branch 'develop' of git.pleroma.social:pleroma/pleroma into better-user-search | pending |  | Review against local BE/FE behavior, then update this row. |
| `3903f12c7` | 2026-01-01 | Lain Soykaf | Add changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `47ca42749` | 2026-05-13 | lain | Merge pull request 'Better user search' (#7793) from gitlab-mr-iid-4416 into develop | implemented | User search already has resolved URI/AP-ID boosts, FTS/trigram ranking, domain filtering, and DB checkout hardening. | No recheck. |
| `9e16332d9` | 2026-05-13 | Lain Soykaf | Update majic to 1.2.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `d8e3ea69b` | 2026-05-13 | Lain Soykaf | Use Hex release for majic 1.2.0 | pending |  | Review against local BE/FE behavior, then update this row. |
| `d0c2d0435` | 2026-05-13 | Lain Soykaf | Use Hex release for oban_plugins_lazarus | pending |  | Review against local BE/FE behavior, then update this row. |
| `2db3a9c04` | 2026-05-13 | lain | Merge pull request 'Use Hex releases for majic and oban_plugins_lazarus' (#7899) from issue-7686-majic-1-2-0 into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `c92d23323` | 2026-05-13 | Lain Soykaf | Use upstream remote_ip package | pending |  | Review against local BE/FE behavior, then update this row. |
| `7ab9e2c7c` | 2026-05-13 | Lain Soykaf | Use pleroma_captcha Hex package | pending |  | Review against local BE/FE behavior, then update this row. |
| `9ae1249cc` | 2026-05-13 | Lain Soykaf | Remove captcha dependency shape test | pending |  | Review against local BE/FE behavior, then update this row. |
| `e4ad3ab32` | 2026-05-13 | lain | Merge pull request 'Use pleroma_captcha Hex package' (#7901) from issue-7678-captcha-hex-1-0-3 into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `512b0f67a` | 2026-05-14 | Lain Soykaf | Merge remote-tracking branch 'origin/develop' into issue-3314-remote-ip-hex | pending |  | Review against local BE/FE behavior, then update this row. |
| `5b63307f8` | 2026-05-14 | lain | Merge pull request 'Use upstream remote_ip package' (#7900) from issue-3314-remote-ip-hex into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `b90ac6b9c` | 2026-05-14 | lain | Merge branch 'develop' into host-verification | pending |  | Review against local BE/FE behavior, then update this row. |
| `c5737898f` | 2026-05-14 | lain | Merge pull request 'Ensure only requests with Host header set to target instance pass through HTTP signatures.' (#7893) from phnt/pleroma:host-verification into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `143f426e8` | 2026-05-13 | Irrlicht | Translated using Weblate (French) | pending |  | Review against local BE/FE behavior, then update this row. |
| `7fff19cbe` | 2026-05-13 | Neko Nekowazarashi | Translated using Weblate (Indonesian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `526365364` | 2026-05-13 | Neko Nekowazarashi | Added translation using Weblate (Indonesian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `4fef91030` | 2026-05-13 | Neko Nekowazarashi | Added translation using Weblate (Indonesian) | pending |  | Review against local BE/FE behavior, then update this row. |
| `086c15b5c` | 2026-05-13 | Codimp | Translated using Weblate (French) | pending |  | Review against local BE/FE behavior, then update this row. |
| `d7a0d97c3` | 2026-05-13 | Codimp | Translated using Weblate (French) | pending |  | Review against local BE/FE behavior, then update this row. |
| `0cf221ba1` | 2026-05-14 | lain | Merge pull request 'Translations update from Pleroma Weblate' (#7866) from weblate into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `c7c453ca2` | 2026-05-14 | lain | Merge branch 'develop' into gitlab-mr-iid-4426 | pending |  | Review against local BE/FE behavior, then update this row. |
| `093b156c6` | 2026-05-14 | lain | Merge pull request 'Switch Phoenix back to upstream' (#7803) from gitlab-mr-iid-4426 into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `1a13ec539` | 2026-05-18 | Henry Jameson | reorganize mfm attributes in order they're listed in misskey repo, add missing ones | pending |  | Review against local BE/FE behavior, then update this row. |
| `c428cf43e` | 2026-05-18 | Henry Jameson | "changelog" | pending |  | Review against local BE/FE behavior, then update this row. |
| `46a280869` | 2026-05-18 | Henry Jameson | extraneous commas | pending |  | Review against local BE/FE behavior, then update this row. |
| `cda673830` | 2026-05-22 | hj | Update priv/scrubbers/default.ex | pending |  | Review against local BE/FE behavior, then update this row. |
| `1a83b1d28` | 2026-05-23 | lain | Merge pull request 'reorganize mfm attributes in order they're listed in misskey repo, add missing ones' (#7904) from mfm-extended into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `7575b7abc` | 2026-05-14 | Phantasm | Woodpecker CI: Do not trigger on Weblate MRs | pending |  | Review against local BE/FE behavior, then update this row. |
| `a5e7145c9` | 2026-05-24 | Phantasm | Merge pull request 'Woodpecker CI: Do not trigger on Weblate MRs' (#7903) from phnt/pleroma:weblate-no-ci into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `9dd02ecd5` | 2026-05-22 | Lain Soykaf | Fix WebSocket protocol token handshakes | implemented | Mastodon websocket protocol-token handshake behavior is covered by the local websocket plug/tests. | No recheck. |
| `4c9fc6287` | 2026-05-25 | Lain Soykaf | Remove unreachable WebSocket protocol match | pending |  | Review against local BE/FE behavior, then update this row. |
| `619db0adc` | 2026-05-25 | lain | Merge pull request 'Restore streaming WebSocket protocol tokens' (#7908) from issue-3298-websocket-protocol into develop | implemented | Websocket plug and endpoint echo sec-websocket-protocol and keep EventSource fallback. | No recheck. |
| `94a28d128` | 2026-05-24 | Phantasm | RichMedia Backfill: Add cachex positive test | pending |  | Review against local BE/FE behavior, then update this row. |
| `678fe8a06` | 2026-05-24 | Phantasm | RichMedia: Add support for disabling wss streaming out on backfill | pending |  | Review against local BE/FE behavior, then update this row. |
| `5f55c9653` | 2026-05-24 | Phantasm | RichMedia: Disable websockets backfill streaming in StatusView | pending |  | Review against local BE/FE behavior, then update this row. |
| `ff7927e21` | 2026-05-24 | Phantasm | changelog | pending |  | Review against local BE/FE behavior, then update this row. |
| `6ee40cb2e` | 2026-05-24 | Phantasm | RichMedia: Add StatusView backfill streaming tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `0c0d68733` | 2026-05-24 | Phantasm | credo, lint | pending |  | Review against local BE/FE behavior, then update this row. |
| `cdb0f103a` | 2026-05-25 | Lain Soykaf | Tighten rich media backfill stream test | pending |  | Review against local BE/FE behavior, then update this row. |
| `c8c1f7d38` | 2026-05-25 | lain | Merge pull request 'Fix Websockets streaming API pushing old already federated posts to TL' (#7907) from websockets-necroposts into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `b1d72e16a` | 2026-05-25 | lain | Merge branch 'develop' into ci/build-armv7-docker-images | pending |  | Review against local BE/FE behavior, then update this row. |
| `e46365bf2` | 2026-05-25 | lain | Merge pull request 'Woodpecker CI: Build armv7 Docker images' (#7882) from ci/build-armv7-docker-images into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `b054c2aa4` | 2026-05-22 | Lain Soykaf | Fix paged featured collection fetches | implemented | Featured collection page handling is present through prepare_featured_collection/1 and embedded first-page tests. | No recheck. |
| `33fdc59bc` | 2026-05-25 | lain | Merge branch 'develop' into issue-7887-featured-collection | pending |  | Review against local BE/FE behavior, then update this row. |
| `f99ce5b2e` | 2026-05-25 | lain | Merge pull request 'Support paged featured collections' (#7912) from issue-7887-featured-collection into develop | implemented | Featured collection fetch path accepts embedded and URL first pages in the local ActivityPub pipeline. | No recheck. |
| `3c63877e6` | 2026-05-05 | Phantasm | Add custom Docker image for FE E2E tests | pending |  | Review against local BE/FE behavior, then update this row. |
| `8a410bf49` | 2026-05-25 | Lain Soykaf | Quote E2E entrypoint variables | pending |  | Review against local BE/FE behavior, then update this row. |
| `54369c93d` | 2026-05-25 | Lain Soykaf | Use E2E approval config key | pending |  | Review against local BE/FE behavior, then update this row. |
| `e023ed7a5` | 2026-05-25 | Lain Soykaf | Seed E2E admin before API readiness | pending |  | Review against local BE/FE behavior, then update this row. |
| `aa16f40f0` | 2026-05-25 | lain | Merge pull request 'Prepared FE E2E Docker image' (#7884) from docker-e2e-image into develop | pending |  | Review against local BE/FE behavior, then update this row. |
| `1e65c7a69` | 2026-05-22 | Lain Soykaf | Add grouped notifications API | pending |  | Review against local BE/FE behavior, then update this row. |
| `add3844c6` | 2026-05-23 | Lain Soykaf | Persist notification group keys | pending |  | Review against local BE/FE behavior, then update this row. |
| `1db2b99e4` | 2026-05-23 | Lain Soykaf | Run group key migration before notification backfill | pending |  | Review against local BE/FE behavior, then update this row. |
| `a2a23b327` | 2026-05-23 | Lain Soykaf | Keep cursor cleanup scoped to grouped notifications | pending |  | Review against local BE/FE behavior, then update this row. |
| `fc9e6793c` | 2026-05-29 | Lain Soykaf | Address grouped notification review cleanup | implemented | `lib/pleroma/notification.ex`, `lib/pleroma/web/mastodon_api/mastodon_api.ex`, `lib/pleroma/web/mastodon_api/views/notification_view.ex` | Local grouped notification implementation includes review cleanup plus Unfathomably group-follow notification support. |
| `98cd1bbb9` | 2026-06-05 | lain | Merge pull request 'Add grouped notifications API' (#7910) from issue-7905-grouped-notifications into develop | implemented | `lib/pleroma/web/router.ex`, `lib/pleroma/web/mastodon_api/controllers/notification_controller.ex`, `lib/pleroma/web/api_spec/operations/notification_operation.ex` | Grouped notification API endpoints, OpenAPI coverage, grouping keys, and response rendering are present locally. |
| `86dd9663f` | 2026-06-01 | Henry Jameson | allow <center> (used by mfm) | implemented | `priv/scrubbers/default.ex` | Default scrubber allows `<center>` with no attributes, preserving MFM center markup without broad sanitizer loosening. |
| `6f5ea5561` | 2026-06-05 | lain | Merge pull request 'allow <center> (used by mfm)' (#7920) from mfm-center into develop | implemented | `priv/scrubbers/default.ex` | Merge-only upstream commit; sanitizer allowance is present locally. |
| `07c65adb0` | 2026-06-10 | Phantasm | Grouped Notifications: Add feature flag to instance view and nodeinfo | implemented | `lib/pleroma/web/mastodon_api/views/instance_view.ex`, NodeInfo metadata | Local instance metadata advertises `mastodon_api_grouped_notifications` and `notifications_v2`. |
| `19a84baf8` | 2026-06-23 | Phantasm | InstanceView: Add feature flag tests | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Upstream test-only commit; runtime feature flags are implemented and covered by local compatibility tests/smoke coverage. |
| `7e9b8a766` | 2026-06-23 | Phantasm | InstanceView: Add federation/0 func test | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Upstream test-only tightening; no runtime change to backport. |
| `86725b5a0` | 2026-06-23 | Phantasm | InstanceView: add rule(s), translation render tests | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Upstream test-only tightening; local translation metadata has diverged with additional providers. |
| `df67f2197` | 2026-06-23 | Phantasm | InstanceView: use shorter setup syntax when applicable | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Test refactor only; no runtime change to backport. |
| `e45dad210` | 2026-06-23 | Phantasm | InstanceView: Add domain_blocks.json render test | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Upstream test-only commit; domain block rendering already follows the local instance view path. |
| `c290f022d` | 2026-06-26 | Phantasm | InstanceView: Add show.json render test | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Upstream test-only commit; no runtime code to backport. |
| `0337bd0ae` | 2026-06-26 | Phantasm | InstanceView: Add show2.json render test | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Upstream test-only commit; no runtime code to backport. |
| `6393fe0a9` | 2026-06-26 | Phantasm | InstanceView: removing unneeded doubling of attributes in tests | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Test cleanup only; no runtime change to backport. |
| `93fe0f5ab` | 2026-06-26 | Phantasm | InstanceView: Filter out *configuration keys from *configuration2 | implemented | `lib/pleroma/web/mastodon_api/views/instance_view.ex` | Local instance view keeps separate v1/v2 configuration render paths and no longer carries the old filter-render guard shape. |
| `9912b2d16` | 2026-06-26 | Phantasm | InstanceView: lint tests | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Test lint cleanup only; no runtime change to backport. |
| `6c79cc792` | 2026-06-27 | Phantasm | InstanceView: improve filtering in tests, simplify | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Test cleanup only; local instance metadata behavior is handled by the current view implementation. |
| `ef321846d` | 2026-06-27 | Phantasm | InstanceView: Use attribute for pleroma_configuration filter in test | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Test cleanup only; no runtime change to backport. |
| `6e03f1d78` | 2026-06-27 | Phantasm | InstanceView: Tighten show.json render test, rename show2-only funcs | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Test-only tightening; no runtime code to backport. |
| `d19a9f768` | 2026-06-27 | Phantasm | InstanceView: Tighten show2.json | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Test-only tightening; no runtime code to backport. |
| `3027052b0` | 2026-06-28 | Phantasm | InstanceView: Remove wall of changed configs in show render tests. | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Test cleanup only; no runtime change to backport. |
| `dd0708837` | 2026-06-28 | Phantasm | InstanceView: lint tests | not-applicable | `test/pleroma/web/mastodon_api/views/instance_view_test.exs` | Test lint cleanup only; no runtime change to backport. |
| `964feb1e4` | 2026-06-28 | Phantasm | InstanceView: Remove unreachable guards in filter_render | implemented | `lib/pleroma/web/mastodon_api/views/instance_view.ex` | Local instance view no longer has the old `filter_render` guard path. |
| `cb0a1d160` | 2026-06-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Grouped Notifications: Add feature flag to instance view and nodeinfo' (#7926) from phnt/pleroma:grouped-notifs-flag into develop | implemented | `lib/pleroma/web/mastodon_api/views/instance_view.ex`, NodeInfo metadata | Merge-only upstream commit; grouped notification feature advertising is present locally. |
| `c6d1cead8` | 2026-06-23 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Allow attaching emojis to user lists | implemented | `lib/pleroma/list.ex`, `lib/pleroma/web/mastodon_api/views/list_view.ex` | User lists store, validate, and render unicode or local custom emoji metadata. |
| `b0ae45194` | 2026-06-29 | nicole mikoÃƒâ€¦Ã¢â‚¬Å¡ajczyk | Merge pull request 'Allow attaching emojis to user lists' (#7929) from mkljczk/pleroma:list-emoji into develop | implemented | `lib/pleroma/list.ex`, `lib/pleroma/web/mastodon_api/views/list_view.ex` | Merge-only upstream commit; list emoji support is present locally. |

/* end of UPSTREAM_PLEROMA_AUDIT.md */













