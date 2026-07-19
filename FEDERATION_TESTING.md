# Unfathomably Backend Federation Testing

This backend test regime borrows the useful habits from larger federated
projects without copying their tooling wholesale.

## Lanes

`mix strict`

Runs the normal backend hard gate: warning-clean compile, formatter check,
strict Credo checks, and the full test suite.

`mix test.federation`

Runs the fast federation compatibility lane. It covers platform-family
classification, source item normalization, and local group creation.

`build_scripts/unfathomably-wide-federation-smoke.sh`

Runs the broad compatibility lane across 25 disposable peer adapters: Discourse,
FediGroups, Friendica, Funkwhale, Gancio, GoToSocial, Hubzilla, Iceshrimp,
Lemmy, Mastodon, Mbin, Misskey, Mitra, Mobilizon, NodeBB, Owncast, PeerTube,
PieFed, Pixelfed, Postmarks, Sharkey, snac, wafrn, WordPress, and WriteFreely.
The default local list is the 11 newest adapters; set
`FEDERATION_WIDE_LOCAL_PLATFORMS` or use `--local-platforms` to select any
combination from the complete set. The runner builds the checked-in
`unfathomably-elixir-smoke:otp28` image automatically before local peers run,
so a separate unpublished image-preparation step is not required. A custom
prebuilt image can still be selected with `UNFATHOMABLY_SMOKE_IMAGE` or
`SMOKE_IMAGE`.

Each peer records its supported and explicitly unsupported behavior in the
same capability matrix. Public-target checks can prove local discovery,
follow, hydration, like/unlike, optional reply/delete, and follow cleanup;
reverse-direction group follow, remote posting, remote comments, remote
reactions, remote deletes, moderation, and modlog checks must either pass
through a local peer adapter or be recorded as unsupported/not_tested.

`build_scripts/unfathomably-federation-safety-smoke.sh`

Runs the shared moderation and defederation safety contract before the expensive
platform matrix. This lane proves that known local defederation policy is
visible through `/api/v1/federation/status`, that account and source follows
return a clear policy reason instead of a generic failure, that local group
bans expose `blocked_by`, `can_follow`, `can_post`, and a moderation message to
clients, that local group bans federate an ActivityPub `Block`, and that the
frontend renders disabled blocked/federation controls for groups and feeds.
The peer-specific Docker lanes still prove platform behavior; this shared lane
keeps the safety UX contract consistent across all of them.

`build_scripts/unfathomably-nodebb-smoke.sh`

Runs a local stock NodeBB peer against disposable Unfathomably instances. The
lane proves the supported category actor path, including Unfathomably follow,
NodeBB topic delivery, local like/unlike, local reply, reply delete, local
NodeBB cleanup, and unfollow. It records stock NodeBB limitations instead of
patching them: NodeBB categories do not follow ActivityPub `Group` actors,
remote Unfathomably group posts are redirected to their origin rather than
imported as local NodeBB posts, and NodeBB API-driven deletes do not federate
remote deletes in the smoke path.

`build_scripts/unfathomably-peertube-smoke.sh`

Runs a local stock PeerTube peer against a disposable HTTPS-advertised
Unfathomably instance. The lane follows PeerTube's native channel/video model:
PeerTube channels are ActivityPub `Group` actors, uploaded videos are resolved
by Unfathomably, likes/unlikes and dislikes/undislikes federate back to
PeerTube, comments federate in both directions, comment deletes are cleaned up,
and PeerTube video deletes are observed by Unfathomably. Stock PeerTube keeps a
local user's rate on a local video in its aggregate video rate collection and
broadcasts a `Video` update rather than an individual `Dislike` or
`Undo Dislike`. The harness records that reverse per-user limitation, along
with non-video text group-post import, rather than patching PeerTube.

`build_scripts/unfathomably-friendica-smoke.sh`

Runs a local stock Friendica peer against a disposable Unfathomably instance.
The lane uses dotted internal hostnames so Friendica resolves the
Unfathomably group by ActivityPub handle instead of falling back to the Atom
feed advertised on HTML profile pages. It creates a Friendica author and forum
account, follows groups in both directions, and exercises posts, replies,
likes, unlikes, deletes, and unfollow cleanup across the boundary. The harness
records stock Friendica limitations instead of patching Friendica: favourites
of remote forum copies are local-only, and Friendica stores group-targeted
remote posts as forum-owned copies that are not removed by the remote author's
Delete.

`build_scripts/unfathomably-hubzilla-smoke.sh`

Runs a local stock Hubzilla peer against a disposable Unfathomably instance.
The lane installs Hubzilla with `pubcrawl`, creates a normal author channel and
a forum-style `Group` channel, follows groups in both supported directions, and
exercises Hubzilla-to-Unfathomably group posting,
Unfathomably-to-Hubzilla group posting, local reactions, local cleanup, and
delete delivery. The harness records stock Hubzilla limitations instead of
patching Hubzilla: remote replies under Hubzilla-authored content are accepted
but not materialized in the smoke-observable item table, Hubzilla's stock
`item/update` API returns `invalid post id` when replying to imported
Unfathomably ActivityPub objects, Hubzilla likes of imported Unfathomably
content do not federate back during the smoke window, remote Deletes are
accepted but do not mark imported Unfathomably rows deleted, and no stock
CLI/API unfollow helper was available for the reverse Hubzilla connection.

`build_scripts/unfathomably-gotosocial-smoke.sh`

Runs a local stock GoToSocial peer against a disposable Unfathomably instance.
The lane follows GoToSocial's native account-style federation model: accounts
resolve and follow in both directions, posts and replies flow both ways,
likes/unlikes are observed by the origin server, top-level deletes are checked
from both sides, and unfollow cleanup runs at the end. The harness also probes
whether stock GoToSocial can import an Unfathomably `Group` actor as a
followable account. If it cannot, the result is recorded as an explicit stock
limitation instead of being confused with untested group coverage.

`build_scripts/unfathomably-misskey-smoke.sh`

Runs a local stock Misskey peer against a disposable Unfathomably instance. The
lane follows Misskey's native account-and-note model: accounts resolve and
follow in both directions, notes and replies flow both ways, favourites,
emoji reactions, unreactions, top-level deletes, and unfollow cleanup are
checked from both sides. It also covers Misskey-specific federation behavior:
`_misskey_summary` profile text imports, `_misskey_reaction` emoji reactions,
and `_misskey_quote` / `quoteUrl` quote notes must surface through the
Unfathomably API fields consumed by the frontend. Stock Misskey does not expose
forum-style ActivityPub `Group` actor behavior, so that family is recorded as
not supported rather than treated as a failed group lane.

`build_scripts/unfathomably-pixelfed-smoke.sh`

Runs a local stock Pixelfed peer built from the official Pixelfed source
Dockerfile against a disposable Unfathomably instance. The lane follows
Pixelfed's photo-oriented account model: accounts resolve and follow in both
directions, image posts flow both ways, remote media attachments remain visible
through each Mastodon-compatible API, replies flow both ways, favourites are
observed by the origin server, local unfavourite cleanup is checked,
Pixelfed-origin deletes are observed by Unfathomably, and unfollow cleanup runs
at the end. Stock Pixelfed may accept remote Undo Like and Delete inbox
deliveries without decrementing the remote status favourite counter or hiding
imported Unfathomably statuses, so those edges are recorded as explicit
capability probes instead of being treated as silent coverage. The harness also
probes whether stock Pixelfed can import an Unfathomably `Group` actor as a
followable account and records the result explicitly.

`build_scripts/unfathomably-funkwhale-smoke.sh`

Runs a local stock Funkwhale peer against a disposable HTTPS-advertised
Unfathomably instance. The lane follows Funkwhale's native music model:
Funkwhale boots with PostgreSQL, Redis, Celery, and a protected-media nginx
proxy, publishes a public library and tagged audio upload, and Unfathomably
resolves the resulting ActivityPub audio object. Favourites and unfavourites
are checked locally and as outbound Funkwhale inbox deliveries, while stock
Funkwhale remote `TrackFavorite` materialization is reported explicitly as a
capability probe. Funkwhale audio delete behavior is likewise reported as a
capability probe because stock upload deletion can leave the ActivityPub track
object visible. Funkwhale's stock behavior around generic account follows and
forum-style `Group` actors is reported explicitly instead of being treated as
silent group coverage.

## What this is meant to catch

The first compatibility target is shape drift. A remote service can change
NodeInfo, actor metadata, or ActivityPub object payloads without warning. The
tests should fail close to the normalization layer instead of later in a
frontend screen.

The second compatibility target is semantic drift. Groups, sources, long-form
articles, audio, video, events, photos, books, and bookmarks all need different
native-feeling UI affordances. Backend tests should keep those families stable.

The third target is release drift. The strict lane must stay warning-clean
because long-lived federation code gets painful when compiler and linter output
is treated as harmless background noise.

## Inspired practices

* Mastodon splits backend tests, frontend tests, linting, browser tests, and
  optional search integration so expensive services do not block fast feedback.
* Lemmy and Misskey both keep explicit federation test lanes that exercise
  multi-instance behavior.
* GoToSocial uses a testrig mindset, where local, disposable instances make
  integration work less spooky.
* PeerTube runs service-backed test matrices and uploads logs on failure.
* Pixelfed keeps a simple framework-native lane that is easy for contributors
  to run.

## Next layers

The current fast lane should be extended with fixture payloads captured from
the platform families we care about most:

* audio: Funkwhale
* longform: WordPress, WriteFreely
* microblog: snac, Misskey, Sharkey, Iceshrimp, Mitra, wafrn
* photo: Pixelfed
* video: PeerTube, Owncast
* books: BookWyrm
* bookmarks: Postmarks
* groups: Lemmy, Lotide, Mbin, PieFed, FediGroups, Discourse, NodeBB
* events: Mobilizon, Gancio
* generic: Bonfire, Friendica, Hubzilla

## Discourse ActivityPub bidirectional smoke lane

Use `build_scripts/unfathomably-discourse-smoke.sh` when checking Discourse
category actors against Unfathomably groups. The harness uses the stock
`discourse/discourse_dev:release` image and clones the official
`discourse-activity-pub` plugin into a throwaway source checkout, so failures
should be treated as either harness assumptions or Unfathomably compatibility
issues rather than fixed by patching Discourse.

The intended coverage is broad, matching the Lemmy, PieFed, MBin, PeerTube, and
NodeBB lanes where the peer platform exposes the needed capability:

- Unfathomably follows a Discourse category `Group` actor.
- The Discourse category actor follows the Unfathomably group and posting user.
- Discourse creates a category topic that Unfathomably resolves and renders.
- Unfathomably likes, unlikes, replies to, and deletes a reply under the Discourse topic.
- Unfathomably creates a group post that Discourse imports into the category.
- Discourse replies to, likes, and unlikes under the Unfathomably post.
- Unfathomably-origin reply and post deletes propagate into Discourse.
- Discourse-origin deletes are capability checked. The current stock plugin path
  can generate non-deliverable Delete activities for deleted posts, so the
  harness records that direction as `not_supported` instead of pretending it
  passed.
- Both sides unfollow at cleanup.

Example remote run on the `.99` smoke host:

```sh
docker rm -f uf-discourse-330a-discourse-proxy uf-discourse-330a-discourse \
  uf-discourse-330a-be-proxy uf-discourse-330a-be \
  uf-discourse-330a-be-a uf-discourse-330a-be-b uf-discourse-330a-be-db >/dev/null 2>&1 || true
docker network rm uf-discourse-330a-net >/dev/null 2>&1 || true
cd /home/jkfirth/unfathomably-smoke/work/pleroma
SMOKE_PREFIX=uf-discourse-330a SMOKE_POLL_ATTEMPTS=120 \
  bash build_scripts/unfathomably-discourse-smoke.sh
```

## Remaining broad-platform full-matrix boundaries

### FediGroups

`build_scripts/unfathomably-wide-federation-smoke.sh` treats FediGroups as a
public group-relay target rather than a Lemmy/PieFed/MBin-style local peer.
Stock FediGroup can advertise groups and boost posts that mention a group, but
upstream currently documents several operations as not implemented: web UI
posting, like/share actions, Delete activities, edit activities, group pages,
group editing/deletion, and moderation.

Because of that stock platform shape, the wide matrix records FediGroups
Delete, reaction, threaded-comment, arbitrary remote-group-follow, and
moderation checks as `unsupported` rather than as passed or silently skipped.
The remaining useful FediGroups harness work is narrower: boot a disposable
stock FediGroup instance, create a test group through its supported setup path,
and prove Unfathomably-to-FediGroup group mentions are accepted and reboosted.

### Hubzilla

Hubzilla now has a stock local Docker harness:
`build_scripts/unfathomably-hubzilla-smoke.sh`. It is the authoritative
full-matrix lane for Hubzilla behavior that can be driven through stock
Hubzilla setup, channel, ActivityPub, and API surfaces. The public-target lane
remains useful for broad discovery checks, but reverse actions should be judged
from the local harness because they require authenticated Hubzilla channels.

The current stock limitation set is explicit: Hubzilla accepts some remote
inbox deliveries without exposing matching item-table state, and the stock
authenticated API cannot drive every browser-visible operation for imported
ActivityPub content. Those cases are reported as `not_supported`, not as
Unfathomably failures.

## Peer-specific feature audit

This table is the selection record for the stock peers in the automated smoke
matrix. A feature is promoted into Unfathomably only when it has a useful
client-facing meaning outside the originating server. Stock limitations remain
explicit adapter results rather than being hidden as generic success.

| Peer | Distinctive federation surface | Acceptance decision |
| --- | --- | --- |
| Discourse | Category actors, topics, and category-targeted replies | Keep the category/topic model in the adapter. Unfathomably renders the category as a group and tests topics, replies, reactions, deletes, and follow cleanup in both supported directions. |
| FediGroups | Hashtag-driven group bot that announces matching posts | Keep bot-specific commands in the adapter. Test group discovery, mention/hashtag announcement, follow cleanup, and every upstream unsupported operation explicitly. |
| Friendica | Forum actors plus native `Dislike` and `Undo Dislike` | Promote dislikes to a first-class status action. Test counts, attribution, undo, forum posts, replies, deletes, and follows in both directions. |
| Funkwhale | `Library`, `Track`, `Audio`, `Listen`, and track favorites | Promote federated Track listens through the existing scrobble API and native audio source-item UI. Test real Track listens in both directions, plus audio rendering and favorite probes. |
| Gancio | Event-first federation with `Place` location data | Preserve Event and Place metadata in the shared event UI. Test event creation, location rendering, comments, deletes, and moderation boundaries. |
| GoToSocial | Strict account-oriented ActivityPub and conservative object validation | Use it as the strict microblog compatibility lane. Its behavior does not require a separate product feature; test ordinary lifecycle and safe Group rejection. |
| Hubzilla | Nomadic identities, channel aliases, and forum channels | Preserve aliases and forum attribution. Keep channel-management quirks in the adapter while testing the supported group lifecycle. |
| Iceshrimp.NET | Misskey-family quote and emoji-reaction extensions | Reuse the quote and emoji-reaction UI. Test `_misskey_quote`, profile summary, reaction, undo, and ordinary lifecycle; do not expose server-specific client APIs. |
| Lemmy | Community actors, threaded posts/comments, upvotes, and downvotes | Promote native downvotes as status dislikes. Test group lifecycle, comments, deletes, votes, downvotes, and undo in both directions. |
| Mastodon | De facto Mastodon API, `Question` polls, and poll votes | Retain the existing poll composer/results UI. Test poll rendering and actual remote votes in both directions in addition to the account/status baseline. |
| MBin | Magazines, article threads, boosts/favorites, and native article downvotes | Promote downvotes through status dislikes, respecting MBin's deliberate ban on post downvotes. Test Unfathomably `Dislike` and `Undo Dislike` on MBin article comments. Record that stock MBin stores its own article-comment downvotes locally but does not federate `Dislike` or `Undo Dislike` to the remote author. |
| Misskey | `_misskey_summary`, `_misskey_reaction`, `_misskey_quote`, and polls | Reuse profile summary, emoji reaction, quote, and poll UI. Test all four surfaces and poll votes in both directions. |
| Mitra | Subscription/payment metadata layered onto microblog ActivityPub | Keep payment and chain-specific state out of the generic status model until a stable portable consumer exists. Test profiles, posts, reactions, moderation, and lifecycle without inventing wallet UX. |
| Mobilizon | Groups, Events, Places, event comments, and RSVP `Join`/`Leave` | Reuse the existing event card and RSVP controls. Test Join, Accept, Leave, event comments, deletes, group follows, and reports across the boundary. |
| NodeBB | Forum category actors, topics, and NodeBB profile fields | Treat categories as groups and topics as threaded status roots. Keep NodeBB-only administration outside the product UI. |
| Owncast | `Service` actor and live-stream lifecycle/preview metadata | Render a native live-stream preview and retain Service actor identity. Treat transient `Offer`, `View`, and `Leave` receipts as lifecycle signals, not posts. |
| PeerTube | Channel groups, `Video`, comments, and video `Dislike` | Reuse media cards and status dislikes. Test Unfathomably `Dislike`/`Undo Dislike`, comments, comment deletes, video delete, and channel follow behavior. Stock PeerTube exposes local-user rates on local videos through aggregate ActivityPub collections and broadcasts a `Video` update rather than sending an individual `Dislike`/`Undo Dislike`, so the reverse per-user action is explicitly unsupported. |
| PieFed | Community actors, threaded content, and signed vote activities | Promote native downvotes as status dislikes. Test group posts, comments, deletes, votes, downvotes, and undo in both directions. Current PieFed main stores new downvotes with zero effect. It removes Unfathomably's voter row after `Undo Dislike` but leaves its aggregate counter stale; for its own downvote, `score: 0` cannot reverse the row and queues another `Dislike` instead of `Undo`. The adapter proves row removal in the first direction and duplicate idempotency in the second while reporting both stock-peer defects explicitly. |
| Pixelfed | Photo-first posts and media-centric profiles | Reuse the attachment/gallery UI and verify real image attachment federation in both directions. Keep Pixelfed collections outside scope until they have portable wire semantics. |
| Postmarks | Bookmark-oriented ActivityPub objects and collections | Preserve bookmark source metadata and render bookmark cards. Test bookmark creation, hydration, deletion, and supported follow/moderation behavior. |
| Sharkey | Misskey-compatible quotes, reactions, profile summary, and polls | Run the shared Misskey-family harness against the stock Sharkey image, including poll votes and quote/reaction cleanup. |
| snac | Small, deliberately minimal ActivityPub implementation | Use it as the minimal-protocol interoperability lane. No snac-only product feature is needed; strict ordinary lifecycle behavior is the value. |
| wafrn | Rich emoji reactions and quote-style posts in a microblog UI | Reuse the generic emoji-reaction and quote UI. Keep WAFRN-only presentation metadata in source previews unless another peer consumes it. |
| WordPress | Long-form `Article` objects, canonical links, and site authorship | Render Article source cards with canonical links and preserve long-form content. Test article discovery, comments, deletes, follows, and moderation boundaries. |
| WriteFreely | Blog `Article` objects and collection/outbox feeds | Reuse Article/source-card UX and preserve canonical author/blog links. Test article hydration, replies, deletes, follow cleanup, and explicit unsupported actions. |

The cross-peer baseline remains bidirectional follow and unfollow where the
peer supports Person actors, group follow and group unfollow where it exposes
Group actors, post/comment creation and deletion, reaction and undo, account
blocking in both directions, moderation reports/actions, and a visible local
defederation reason. Each adapter must print `supported`, `not_supported`, or
fail; silence is never coverage.

# end of FEDERATION_TESTING.md
