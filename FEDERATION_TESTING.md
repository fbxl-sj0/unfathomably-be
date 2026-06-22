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

# end of FEDERATION_TESTING.md
