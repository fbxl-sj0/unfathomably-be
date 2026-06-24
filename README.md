# unfathomably-be

**unfathomably-be** is a Fediverse backend written in Elixir.

It descends from Rebased and Pleroma, keeps Mastodon API compatibility, and is the backend half of the Unfathomably stack alongside unfathomably-fe.

## Your social media server

unfathomably-be empowers people to take control of their social media experience.
Hosting your own server means that *you* get to decide the rules.

It is designed to connect deeply across the Fediverse while staying practical for real communities to operate.

## What Makes It Different

Pleroma is the upstream foundation for much of the ActivityPub, Mastodon API, and operational model. Rebased added a Soapbox-oriented backend profile and its own compatibility choices. unfathomably-be keeps that lineage, but the project has moved in a more interoperability-focused direction.

The central goal is to make a small-to-medium Fediverse server useful across more kinds of software, not just across Mastodon-like microblogging instances.

Notable areas of work include:

- group-like actors from Lemmy, PieFed, Mbin, Lotide, PeerTube, and other Threadiverse-style systems
- source-like actors for feeds that are not ordinary user accounts, such as media, music, image, and publishing platforms
- bidirectional follow, post, comment, like, unlike, delete, and unfollow flows for compatible remote group software
- Mastodon-compatible streaming and websocket behavior, including public, direct, notification, list, and remote stream support
- richer ActivityPub normalization for quotes, reply collections, language metadata, actor metadata, and cross-platform edge cases
- remote reply collection refreshes so group discussions and remote posts can discover comments that were not pushed directly to the local instance
- cached ActivityPub follower/following collection counters with paginated rendering, so large relationship sets do not need to be loaded just to render collection pages
- search and translation provider support, including Meilisearch and LibreTranslate/OpenTranslate-style deployments
- janitor and reachability work for stale remote hosts, abandoned cached discussions, old Oban jobs, and remote content that no local user interacted with
- stricter browser-facing security defaults, while keeping local smoke-test allowances scoped to development and test configuration

## Relationship To Upstream

unfathomably-be is not a clean rebrand of Pleroma or Rebased. It is a fork with substantial compatibility, operations, frontend-integration, and maintenance changes.

The code still deliberately preserves many upstream names and API shapes. The OTP application is still `:pleroma`, many modules remain under `Pleroma.*`, and compatibility endpoints continue to use Mastodon, Pleroma, and Soapbox conventions where existing clients expect them. Those names are compatibility surfaces, not a statement that the project is unchanged from upstream.

The intent is to remain source-readable for people familiar with Pleroma while making the runtime behavior better suited to mixed Fediverse and Threadiverse environments.

## Current Focus

The current release line is focused on:

- making group and source feeds first-class enough to use every day
- reducing stale remote-host and stale-cache costs on long-running instances
- improving compatibility with Mastodon, Pleroma, Akkoma, Rebased, Lemmy, PieFed, Mbin, Lotide, PeerTube, Pixelfed, Misskey-family software, and other ActivityPub implementations where practical
- keeping public APIs and NodeInfo close enough to Mastodon expectations that common clients and indexers do not need special fallbacks
- tightening lint, test, and smoke-test coverage around the parts of federation that tend to regress silently

## Installation

Installation notes are being updated for the Unfathomably stack. Existing Pleroma/Rebased source-install and OTP-release knowledge is still useful, but operators should expect Unfathomably-specific configuration for the frontend, translation, search, websocket proxying, and optional compatibility jobs.

See the `docs/` directory for inherited Pleroma documentation and the Unfathomably-specific notes that have been added so far.

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
