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

Runs the broad group/forum/channel compatibility lane for PeerTube, NodeBB, Discourse, FediGroups, Hubzilla, and Friendica. The script records a full bidirectional capability matrix for every platform row. Public-target checks can prove local discovery, follow, hydration, like/unlike, optional reply/delete, and follow cleanup; reverse-direction group follow, remote posting, remote comments, remote reactions, remote deletes, and modlog checks must either pass through a local peer/adapter or be recorded as unsupported/not_tested.

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
by Unfathomably, likes/unlikes federate back to PeerTube, comments federate in
both directions, comment deletes are cleaned up, and PeerTube video deletes are
observed by Unfathomably. The harness records stock PeerTube limitations around
non-video text group-post import rather than patching PeerTube.

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
* microblog: GoToSocial, snac, Misskey, Sharkey, Iceshrimp, Mitra, wafrn
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

Example remote run on a smoke host:

```sh
docker rm -f uf-discourse-330a-discourse-proxy uf-discourse-330a-discourse \
  uf-discourse-330a-be-proxy uf-discourse-330a-be \
  uf-discourse-330a-be-a uf-discourse-330a-be-b uf-discourse-330a-be-db >/dev/null 2>&1 || true
docker network rm uf-discourse-330a-net >/dev/null 2>&1 || true
cd /srv/unfathomably-smoke/work/pleroma
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

# end of FEDERATION_TESTING.md
