# unfathomably-be

> Your corner of the Fediverse is the whole thing

**unfathomably-be** is a Fediverse backend written in Elixir.

It descends from Rebased and Pleroma, keeps Mastodon API compatibility, and is
the backend half of the Unfathomably stack alongside unfathomably-fe.

## Your social media server

unfathomably-be empowers people to take control of their social media experience.
Hosting your own server means that *you* get to decide the rules.

It is designed to connect deeply across the Fediverse while staying practical
for real communities to operate.

## What Makes It Different

Pleroma and Rebased are the foundation, but unfathomably-be has moved in a more
interoperability-focused direction. The goal is not only to talk to Mastodon-like
microblogging servers. The goal is to make one small-to-medium instance useful
across the Fediverse, the Threadiverse, media platforms, publishing feeds, and
other ActivityPub software that does not fit neatly into a single profile-feed
model.

Important areas of work include:

- **Groups and Threadiverse compatibility.** unfathomably-be understands
  group-like actors from Lemmy, PieFed, Mbin, Lotide, PeerTube, NodeBB,
  Discourse, FediGroups, Hubzilla, Friendica, and similar software where their
  ActivityPub shape can be mapped safely.
- **Source-style feeds.** Sources cover actors and feeds that are not ordinary
  user profiles, including RSS feeds, WordPress-style publishers, Funkwhale
  libraries, PeerTube channels, Pixelfed-style media sources, and other
  feed-like targets.
- **Remote discussion hydration.** The backend can refresh remote reply
  collections and thread chains so group discussions, PeerTube comments, and
  other remote conversations do not depend only on replies that happened to be
  delivered directly to the local inbox.
- **Threadiverse-aware audience handling.** Replies and posts aimed at group
  software use target-aware audience and recipient behavior so they look more
  natural on Lemmy-like and Mbin-like platforms.
- **Mastodon-compatible streaming.** Websocket streaming support covers common
  Mastodon client expectations, including notification, public, direct, list,
  and related stream behavior exposed through the Mastodon API surface.
- **Translation support.** LibreTranslate, OpenTranslate-compatible services,
  and related language metadata can be exposed to clients so translation buttons
  appear only when they make sense.
- **Search and feed discovery.** Meilisearch support, RSS source ingestion,
  redirect/gone handling, and remote source discovery are part of the current
  operator-facing stack.
- **Post archive portability.** Account history export and import support has
  begun, with instance policy controls for disabled imports, admin-reviewed
  imports, or automatic imports.
- **Federation health and janitor work.** Remote host health, stale actor
  cleanup, cached remote post cleanup, old job cleanup, and reachability checks
  help long-running instances keep themselves from filling up with unreachable
  or unused remote history.
- **Broader ActivityPub normalization.** Recent compatibility work includes
  Misskey reaction shapes, Mbin wrapped activities, NodeBB attributed groups and
  profile fields, Hubzilla nomadic identity hints, Discourse context handling,
  FediGroups locked group mentions, Friendica source discovery, and Funkwhale
  source metadata.

## Relationship To Upstream

unfathomably-be intentionally keeps many inherited names. The OTP application is
still `:pleroma`, many modules are still under `Pleroma.*`, and many commands
still begin with `mix pleroma.*`. Existing clients also still expect Mastodon,
Pleroma, and Soapbox API conventions.

Those compatibility names are deliberate. They keep existing deployments,
admin tools, clients, and documentation paths working while the behavior evolves
into something broader than the original Rebased installation.

## Frontend Pairing

unfathomably-be is designed to pair with
`https://github.com/fbxl-sj0/unfathomably-fe`.

The backend owns accounts, federation, moderation, timelines, search,
translation, websocket streams, post archive jobs, media proxying, and cleanup
workers. The frontend owns the browser UI, group and source navigation, docked
media player, archive import/export screens, admin federation health views, and
thread display.

Other Mastodon-compatible clients should continue to work where they use common
API surfaces, but the full groups, sources, translation, and admin experience is
best exposed through unfathomably-fe.

## Installation

See `docs/INSTALLATION.MD` for a from-scratch source installation and
OpenTranslate setup.

See `docs/UPGRADE.MD` for upgrade notes from Rebased/Soapbox or from a more
standard Pleroma source installation.

The code still follows Pleroma-style deployment conventions in many places.
That means a production install may still use a `pleroma` Unix user, a
`pleroma` database, `pleroma.service`, and Mix tasks with `pleroma` in the
command name.

## License

unfathomably-be is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

unfathomably-be is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with unfathomably-be.  If not, see <https://www.gnu.org/licenses/>.
