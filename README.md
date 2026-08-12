# unfathomably-be

> Your corner of the Fediverse is the whole thing

**unfathomably-be** is an Elixir social networking backend descended from
Rebased and Pleroma. It keeps broad Mastodon API compatibility and provides the
backend half of the Unfathomably stack alongside
[unfathomably-fe](https://github.com/fbxl-sj0/unfathomably-fe).

## Your social media server

unfathomably-be lets a community operate its own social space and set its own
rules. It is designed to connect deeply across federated networks while
remaining practical for a small-to-medium instance to run.

## What makes it different

Pleroma and Rebased remain the foundation, but the project now covers much more
than Mastodon-style profile feeds. Important areas of work include:

- **Worlds.** A bounded discovery and authoring layer organizes federated
  material into audio, video, long-form writing, photography, books, bookmarks,
  groups, events, software development, 3D models, marketplaces, games, routes,
  culture, coordination, and publishing.
- **Groups and Threadiverse compatibility.** Group-like actors from Lemmy,
  PieFed, Mbin, Lotide, PeerTube, NodeBB, Discourse, FediGroups, Hubzilla,
  Friendica, and similar software are mapped where their ActivityPub shape can
  be handled safely.
- **Selective protocol bridges.** Configurable Nostr, AT Protocol/Bluesky, and
  diaspora* support maps locally relevant identities and interactions into the
  server's ActivityPub model without trying to mirror those networks.
- **Source-style feeds.** Sources cover actors and feeds that are not ordinary
  user profiles, including RSS and WordPress publishers, Funkwhale libraries,
  PeerTube channels, Pixelfed-style media sources, and other feed-like targets.
- **Remote discussion hydration.** The backend can refresh remote reply
  collections and thread chains so group discussions, PeerTube comments, and
  other conversations do not depend only on replies delivered to the local
  inbox.
- **Target-aware audiences.** Replies and posts sent to group software use
  audience and recipient rules suited to Lemmy-like and Mbin-like platforms.
- **Mastodon-compatible streaming.** WebSocket streaming covers notification,
  public, direct, list, and related streams expected by Mastodon clients.
- **Translation.** LibreTranslate, OpenTranslate-compatible services, and
  language metadata can be exposed to clients when translation is available.
- **Search and discovery.** Meilisearch, RSS ingestion, remote source discovery,
  redirect and gone handling, and administrator-approved FASP account search
  are part of the operator-facing stack.
- **Post archive portability.** ActivityPub export archives can be imported
  under an instance policy that disables imports, requires administrator
  review, or allows automatic processing.
- **Long-running instance maintenance.** Federation health, stale actor and
  remote post cleanup, old job cleanup, and reachability checks keep unused or
  unreachable remote state bounded.
- **Broader ActivityPub normalization.** Compatibility work covers Misskey
  reactions, Mbin activity wrappers, NodeBB groups and profile fields, Hubzilla
  nomadic identity hints, Discourse contexts, FediGroups locked mentions,
  Friendica source discovery, and Funkwhale source metadata.

## Interoperability boundaries

ActivityPub is the canonical local data and moderation model. The other
protocol integrations are deliberately selective:

- Nostr uses the local relay and administrator-selected external relays.
- AT Protocol stores followed, explicitly opened, and directly relevant
  records instead of consuming the firehose or mirroring repositories.
- diaspora* accepts signed, locally relevant traffic and does not implement
  private aspect messages that cannot be represented safely.

Bridge features are configuration-dependent. Imported material still passes
through local validation, visibility, and moderation rules. See the
[federation capability manifest](FEDERATION.md) and
[federation test matrix](FEDERATION_TESTING.md) for the exact supported surface
and known peer limitations.

## Relationship to upstream

unfathomably-be intentionally keeps many inherited names. The OTP application
is still `:pleroma`, many modules are under `Pleroma.*`, and many commands begin
with `mix pleroma.*`. Existing clients also expect Mastodon, Pleroma, and
Soapbox API conventions.

Those compatibility names keep existing deployments, administration tools,
clients, and configuration paths working while the behavior evolves beyond the
original Rebased installation.

## Frontend pairing

The backend owns accounts, federation, moderation, timelines, search,
translation, WebSocket streams, archive jobs, media proxying, and cleanup
workers. [unfathomably-fe](https://github.com/fbxl-sj0/unfathomably-fe) owns the
browser interface, including Worlds, groups, sources, archive controls,
federation health views, and thread display.

Other Mastodon-compatible clients should continue to work where they use common
API surfaces. Unfathomably-specific features are best exposed through the
paired frontend.

## Installation and upgrades

- [Install Unfathomably from source](docs/INSTALLATION.MD)
- [Upgrade from Rebased, Soapbox, or Pleroma](docs/UPGRADE.MD)
- [Read the operator and API documentation](docs/README.md)
- [Review the security policy](SECURITY.md)
- [Review release history](CHANGELOG.md)

Production deployments still follow Pleroma conventions in several places. A
deployment may use a `pleroma` Unix user, `pleroma` database,
`pleroma.service`, and Mix tasks containing `pleroma`.

## Development and verification

Use the Erlang and Elixir versions in [`.tool-versions`](.tool-versions). The
test configuration expects PostgreSQL on `localhost` by default.

```sh
mix deps.get
mix strict
```

`mix strict` performs a warning-clean compile, checks formatting, runs the
strict Credo checks, creates and migrates the test database, and runs the full
test suite. For narrower release checks, use `mix test.federation` or
`mix test.release_surface`. The Docker-based peer tests and their requirements
are documented in [FEDERATION_TESTING.md](FEDERATION_TESTING.md).

## License

unfathomably-be is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

unfathomably-be is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
details.

You should have received a copy of the GNU Affero General Public License along
with unfathomably-be. If not, see <https://www.gnu.org/licenses/>.
