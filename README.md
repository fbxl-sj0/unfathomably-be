# Unfathomably BE

> Your corner of the Fediverse is the whole thing

Unfathomably BE is a self-hosted, multi-protocol social networking server. It
gives a community one local identity, moderation, privacy, and storage boundary
while reaching across the Fediverse, Threadiverse, federated media and
publishing services, Nostr, AT Protocol, and diaspora*.

This is not a Pleroma theme or a lightly renamed Rebased release. The project
descends from both systems and preserves their useful compatibility surfaces,
but it now has its own federation model, product concepts, protocol adapters,
security rules, background services, APIs, and paired frontend. The current
release is 3.5.0.

## The system in one view

```text
 Unfathomably FE       Mastodon-compatible clients       Administration
         \                        |                            /
          +------------ HTTP APIs and WebSockets ------------+
                                   |
                timelines | groups and sources | Worlds
                                   |
                      Unfathomably canonical core
            accounts | objects | timelines | visibility | moderation
                    /              |                    \
          ActivityPub peers   selective adapters      operator services
                              Nostr, AT Protocol,      Oban, search,
                                  diaspora*           media, translation
```

ActivityPub is the canonical local model. Material arriving through another
protocol is mapped into local actors, objects, relationships, and activities,
then passes through the same visibility, authorization, moderation, and
retention rules as ordinary federation. A bridge assertion is not allowed to
bypass the local trust boundary.

PostgreSQL stores durable social and federation state. Oban owns asynchronous
delivery, ingestion, synchronization, archive, maintenance, and repair work.
Phoenix serves the client APIs, public pages, ActivityPub endpoints, and
WebSocket streams.

## What people can do with it

### Run a complete social server

Unfathomably provides accounts, profiles, posts, media, polls, conversations,
chats, reactions, quotes, bookmarks, lists, filters, notifications, scheduled
posts, account migration, moderation, reporting, OAuth, MFA, push delivery,
search, translation, streaming, and administration. Common Mastodon client APIs
remain available, with Pleroma and Unfathomably extensions for the broader
feature set.

Account history can be exported, and supported public ActivityPub history can
be imported from compatible archives. An operator can disable post archive
imports, require administrator review, or permit automatic processing.

### Use groups and sources as first-class objects

The server does not assume every federated destination is a person with a
microblog. It understands community and source shapes used by forum, media,
event, publishing, and feed software.

- Group-aware discovery, following, posting, replies, moderation, and audience
  construction cover Lemmy, PieFed, Mbin, Lotide, NodeBB, Discourse,
  FediGroups, Friendica, Hubzilla, PeerTube, and compatible shapes.
- Sources represent channels, libraries, publishers, RSS or Atom feeds, and
  other read-oriented actors that should not be presented as ordinary people.
- Bounded thread and collection hydration can recover relevant remote replies
  without crawling an entire remote service.
- Follow state, group membership, and local moderation remain explicit. Merely
  opening discovery does not join, follow, publish, or contact a remote actor.

### Move beyond one generic timeline with Worlds

Worlds is Unfathomably's semantic layer for finding, presenting, and authoring
specialized federated material. Users work with familiar tasks such as finding
a book, joining an event, publishing a route, or sharing a model instead of
having to understand ActivityStreams vocabulary or remote server software.

The 16 current Worlds families are:

| Area | Families |
| --- | --- |
| Media and publishing | Audio, video, photography, long-form writing, publishing |
| Culture and collections | Books, bookmarks, culture, games |
| Communities and coordination | Groups, events, coordination |
| Tools and exchange | Software development, 3D models, marketplace, routes |

Worlds uses bounded server-side discovery and fixed authoring schemas. It
preserves remote ownership, visibility, licensing, and source-specific actions;
it does not flatten every remote object into a generic status or let an
untrusted object opt itself into local discovery.

The detailed user and acceptance contract is in
[Worlds user epics and stories](docs/WORLDS_USER_EPICS_AND_STORIES.md).

## Federation and protocol coverage

### ActivityPub and the wider Fediverse

The ActivityPub implementation supports server-to-server federation and
client-to-server interactions, ActivityStreams 2.0 JSON-LD, WebFinger,
NodeInfo, LitePub relays, legacy HTTP Signatures, and RFC 9421 HTTP Message
Signatures. It includes explicit support for group federation, quote
authorization, interaction policies, appendable collections, server actors,
follower synchronization, and other finalized or deployment-gated FEPs
documented in the [federation capability manifest](FEDERATION.md).

Compatibility work covers ordinary account servers as well as forum, video,
audio, event, image, publishing, catalogue, marketplace, route, and development
software. The repository includes disposable smoke adapters for 25 stock peer
implementations. A capability is recorded as unsupported or untested when the
peer does not expose it; a successful HTTP exchange alone is not counted as
working interoperability.

See [federation testing](FEDERATION_TESTING.md) for the peer matrix, supported
directions, known stock limitations, and test commands.

### Selective bridges

The non-ActivityPub adapters are intentionally bounded:

| Network | Supported model | Deliberate boundary |
| --- | --- | --- |
| Nostr | A local relay, configured external relays, profiles, posts, threads, reactions, reposts, deletes, communities, lists, calendars, live activities, polls, reports, badges, and NIP-17 private chat | No unrestricted relay-graph crawl; private material is not projected into public ActivityPub timelines |
| AT Protocol and Bluesky | Explicit identity resolution, followed and directly relevant records, thread hydration, linked local identities, media, and supported read or publish actions | No firehose consumption, global repository mirror, relay, or AppView |
| diaspora* | Signed and locally relevant profiles, public statuses, comments, likes, reshares, retractions, and contact changes | No arbitrary public pod ingestion and no private aspect messages whose audience cannot be represented safely |

Bridge availability is configuration-dependent. The instance API reports which
adapters are actually enabled so clients do not have to infer support from a
software version string.

### Feeds and auxiliary discovery

RSS and Atom sources, WordPress-style publishers, remote source actors,
FediBuzz event discovery, and administrator-approved FASP providers can extend
local discovery. These integrations are paced and bounded. Results still use
the normal fetch, origin, visibility, blocking, and moderation paths, and an
unapproved provider is not queried.

## Security and trust boundaries

Federation accepts hostile network input by design. Unfathomably therefore
treats protocol compatibility and security as the same engineering problem.
Important rules include:

- bind fetched objects, redirects, identifiers, actors, and embedded activities
  to their authoritative origins
- require destructive Updates, Deletes, forwarded activities, and group
  wrappers to prove the authority that owns the affected object
- preserve private and followers-only audiences across replies, quotes, and
  bridge projections
- reject or constrain local, private, credential-bearing, cross-origin, cyclic,
  oversized, and otherwise unsafe remote targets before network or storage work
- validate signed request components, body digests, signature lifetimes, and
  actor-controlled keys while bounding failed-signature key refreshes
- apply local MRF, domain blocks, visibility, relationship, and moderation
  policy before committing an interaction or claiming delivery success
- put explicit depth, page, item, byte, and retry limits around remote
  collections and asynchronous work

The repository contains regression tests for these boundaries and federation
safety smoke lanes. This is not a claim that the software is free of security
defects. Report suspected vulnerabilities privately according to
[SECURITY.md](SECURITY.md).

## Operations and maintenance

Unfathomably is designed for a real, long-running community rather than only a
demonstration federation node. Operator-facing facilities include:

- database-backed configuration and role-scoped administration APIs
- Oban queues with bounded retry, uniqueness, cleanup, and repair paths
- remote host health and reachability tracking
- stale actor, cached post, group discussion, job, application, and hashtag
  cleanup
- media proxying, attachment processing, backups, and archive jobs
- Prometheus-compatible metrics and federation diagnostics
- optional Meilisearch and OpenTranslate-compatible services
- migration and upgrade paths from Rebased, Soapbox, and Pleroma deployments

Protocol adapters are not all enabled by default. Operators choose the networks,
relays, providers, import policy, discovery connectors, and external services
appropriate for their community.

## Frontend and client compatibility

[unfathomably-fe](https://github.com/fbxl-sj0/unfathomably-fe) is the paired
browser frontend. It owns the complete Worlds interface, group and source
navigation, docked media, archive workflows, federation health views,
translation controls, and presentation of Unfathomably-specific metadata.

Mastodon-compatible clients can use the common account, timeline, posting,
notification, search, list, filter, conversation, and streaming APIs they
understand. They will not automatically expose every Worlds, bridge, source,
group-administration, or federation-diagnostics feature.

## Relationship to Pleroma and Rebased

The lineage remains visible in the code and deployment model:

- the OTP application is still named `:pleroma`
- most modules remain under `Pleroma.*`
- many Mix tasks begin with `mix pleroma.*`
- deployments commonly retain the `pleroma` Unix user, PostgreSQL database,
  and systemd service names
- Pleroma, Rebased, Soapbox, and Mastodon API compatibility names remain on
  wire surfaces where existing clients depend on them

These names are deliberate compatibility contracts, not the current product
boundary. New behavior should follow Unfathomably's validation, moderation,
bounded-discovery, and protocol-neutral architecture rather than assuming an
inherited upstream behavior is automatically correct for this project.

## Installing or upgrading

Production installation is more than running a development Phoenix server. It
requires PostgreSQL, the system media and build dependencies, a private runtime
configuration, database migrations, a reverse proxy with TLS, and a deployed
frontend.

- [Install a new Unfathomably instance from source](docs/INSTALLATION.MD)
- [Upgrade a Rebased, Soapbox, or Pleroma installation](docs/UPGRADE.MD)
- [Review configuration and operator documentation](docs/README.md)

Use [`.tool-versions`](.tool-versions) as the source of truth for Erlang and
Elixir versions. Version 3.5 uses Erlang/OTP 29 and Elixir 1.20.

## Development and verification

The test environment expects PostgreSQL on `localhost` by default.

```sh
mix deps.get
mix strict
```

`mix strict` performs a warning-clean compile, checks formatting, runs strict
Credo checks, creates and migrates the test database, and runs the full test
suite. Useful narrower lanes include:

```sh
mix test.federation
mix test.release_surface
```

The stock-peer federation lanes use Docker and additional disposable services.
Their requirements and platform-specific commands are documented in
[FEDERATION_TESTING.md](FEDERATION_TESTING.md).

## Documentation

| Topic | Document |
| --- | --- |
| Installation | [docs/INSTALLATION.MD](docs/INSTALLATION.MD) |
| Optional protocols and product features | [docs/FEATURE_ENABLEMENT.md](docs/FEATURE_ENABLEMENT.md) |
| Upgrading | [docs/UPGRADE.MD](docs/UPGRADE.MD) |
| Operator and API documentation | [docs/README.md](docs/README.md) |
| Federation capabilities | [FEDERATION.md](FEDERATION.md) |
| Federation verification | [FEDERATION_TESTING.md](FEDERATION_TESTING.md) |
| Worlds product contract | [docs/WORLDS_USER_EPICS_AND_STORIES.md](docs/WORLDS_USER_EPICS_AND_STORIES.md) |
| Security reporting | [SECURITY.md](SECURITY.md) |
| Release history | [CHANGELOG.md](CHANGELOG.md) |

## License

Unfathomably BE is free software released under the GNU Affero General Public
License, version 3 or, at your option, any later version. See [COPYING](COPYING)
for the complete license.

The project retains and builds upon AGPL-licensed work by the Pleroma, Rebased,
and Soapbox contributors. Source files preserve their applicable copyright and
license notices.
