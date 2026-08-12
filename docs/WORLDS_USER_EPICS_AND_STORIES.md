# Worlds user epics and stories

This document is the product acceptance contract for specialized federation.
It describes user outcomes, not protocols or server administration.

## Beginner knowledge boundary

A basic user may know the ordinary name of a book, song, event, community,
route, project, or item. They may know how to search, open a link, write a post,
and upload a file. We must not assume they know ActivityPub, actors, objects,
inboxes, federation, instance software, WebFinger, canonical URLs, or which
application hosts an item.

The main path uses familiar nouns and verbs. Software names and exact public
links are optional help. Following, joining, publishing, reacting, RSVP,
private contact, and source-owned actions always require an explicit choice.

## Shared epic: use any World without protocol knowledge

**W0.1:** As a person arriving from navigation, I want familiar post cards so
the World still feels like Soapbox.

**W0.2:** As a person who knows what I want but not where it is hosted, I want
one visible finder with examples so I do not need a server name.

**W0.3:** As a person opening a result, I want `Open here` and `Open original`
to have distinct meanings so I understand whether I am leaving my site.

**W0.4:** As a contributor, I want a task-specific create path so I do not have
to translate my goal into an ActivityPub object.

**W0.5:** As a cautious user, I want discovery to remain read-only until I
explicitly choose a social or publishing action.

**Shared acceptance:** Feed is first and uses standard status cards; Find is
visible without opening an advanced disclosure; Create is complete or states an
honest source-owned boundary; empty states offer a useful next step; no main
workflow lists instances or mutates local or remote relationships by itself.

## Epic B: books and reading

**Knowledge boundary:** The reader may know a title, author, or ISBN, but not
BookWyrm, Work objects, editions, or shelf federation.

**B1:** Find a book by title, author, or ISBN and distinguish its edition.

**B2:** Read reviews and reading activity as normal posts with book context.

**B3:** Select a book before reviewing, quoting, commenting, or shelving it.

**Acceptance B:** Find says `Find a book or edition`; Create starts with a
catalogue selection and preserves provider-owned identity; cards retain rating,
edition, reading state, shelf, and discussion context.

## Epic C: film, music, games, and culture

**Knowledge boundary:** The user knows a title or creator, but not NeoDB
categories or catalogue schemas.

**C1:** Search familiar cultural work types through one finder.

**C2:** See work, creator, year, status, rating, and review together.

**C3:** Discuss or collect a work without rewriting catalogue identity.

**Acceptance C:** Find names familiar work types; Create starts with a selected
work and then asks for status, rating, and optional review; cards retain the
structured context.

## Epic A: audio and podcasts

**Knowledge boundary:** The listener knows a track, artist, album, show, or
subject, but not Funkwhale libraries or Audio objects.

**A1:** Find and play received recordings locally instead of seeing bare links.

**A2:** See artist, release, duration, artwork, and social actions by the player.

**A3:** Upload audio first and then add credits, topics, and reuse terms.

**Acceptance A:** Find says `Find music or a podcast`; playable results use
status cards; Create is file-first and supports accessible cover descriptions;
restricted libraries remain source-owned.

## Epic V: video and live streams

**Knowledge boundary:** The viewer knows a title, channel, or topic, but not
PeerTube, Owncast, channel actors, or playlist objects.

**V1:** Play or open federated videos locally with comments and reactions.

**V2:** Distinguish a source-owned live stream from a saved local video.

**V3:** Upload video first and then add captions, artwork, language, and license.

**Acceptance V:** Find says `Find a video or channel`; local video has an
`Open here` path; source-only live services are labelled; Create accepts video,
artwork, and WebVTT captions.

## Epic P: photography

**Knowledge boundary:** The user knows a photographer, place, or subject, but
not Pixelfed or Image activity details.

**P1:** Open one image at full size and move through its gallery.

**P2:** Retain useful image descriptions for assistive technology.

**P3:** Share photographs first, then add caption, album, place, date, and license.

**Acceptance P:** Find says `Find photographs or photographers`; cards use the
standard media viewer; Create requires images and supports per-image descriptions
without requiring a remote Pixelfed account.

## Epic E: events and gatherings

**Knowledge boundary:** The attendee knows an event, organizer, place, or date,
but not Mobilizon, Gancio, organizer actors, or Join activities.

**E1:** See schedule, place, organizer, and participation on the event card.

**E2:** Distinguish local RSVP from source-owned registration.

**E3:** Plan an event using the complete existing event workflow.

**Acceptance E:** Find says `Find an event`; cards retain time and place; RSVP
appears only when supported; Create opens organizer, venue, participation,
visibility, banner, and description controls.

## Epic G: communities and forums

**Knowledge boundary:** The user knows a topic or community name, but need not
distinguish Lemmy, MBin, PieFed, NodeBB, Discourse, Friendica, Hubzilla,
FediGroups, or Bonfire.

**G1:** Search by topic and inspect a community before choosing to join.

**G2:** Read discussions as normal posts while retaining group context.

**G3:** Create a community with full identity, privacy, and moderation controls.

**Acceptance G:** Find says `Find a community`; server directories are not the
main workflow; opening never joins automatically; Create uses the established
permission-aware group creator.

## Epic M: classifieds and marketplace

**Knowledge boundary:** The user knows what they offer or need and a general
area, but not Flohmarkt or Offer vocabulary.

**M1:** See condition, price, currency, location, availability, and fulfilment.

**M2:** Keep private contact explicit and avoid exposing a home address.

**M3:** Choose sell, give away, or wanted before optional external sharing.

**Acceptance M:** Find says `Find an offer or request`; Create explains safe
location, makes coordinates optional, and leaves marketplace sharing off by
default; requests are never sent as marketplace offers.

## Epic R: routes and trails

**Knowledge boundary:** The user knows a place, activity, or GPX file, but not
Wanderer, geographic vocabularies, or route actors.

**R1:** See distance, difficulty, elevation, duration, terrain, safety, and map.

**R2:** Download a route while retaining its author and discussion.

**R3:** Remove private endpoints and derive safe facts from GPX before sharing.

**Acceptance R:** Find says `Find a route or trail`; cards retain practical
facts; Create is GPX-first and asks only for details the file cannot provide.

## Epic D: 3D models

**Knowledge boundary:** The user knows an object or part, but not Manyfold,
model actors, or federated file collections.

**D1:** Keep previews, formats, version, dimensions, license, and files together.

**D2:** Inspect a local model page before downloading the original.

**D3:** Upload a model or archive first and then describe print and reuse needs.

**Acceptance D:** Find says `Find a 3D model`; actions distinguish local and
original pages; Create requires a model/archive and exposes version, scale,
category, printable state, and license.

## Epic F: software development

**Knowledge boundary:** The user knows a project, repository, bug, or feature,
but not ForgeFed actors or Ticket objects.

**F1:** Keep repositories, issues, patches, and activity tied to their project.

**F2:** Require a project when filing an issue.

**F3:** Identify the authoritative forge for source changes while retaining
local public discussion.

**Acceptance F:** Find says `Find a project or issue`; Create offers project and
ticket paths; tickets require a project and actionable details; a new project
offers a direct first-issue path.

## Epic H: coordination and mutual aid

**Knowledge boundary:** The person knows what they can offer or need, where,
and when, but not ValueFlows, EconomicResource, Intent, or ActivityPods.

**H1:** Begin with `I can help` or `I need help` before logistics.

**H2:** Keep resource, quantity, place, deadline, recipient, and skills together.

**H3:** Keep private records absent unless their owner grants access.

**Acceptance H:** Find says `Find help, offers, or needs`; Create starts with a
human intention; cards preserve coordination facts; private discovery is never
implied.

## Epic K: games and challenges

**Knowledge boundary:** The user knows a player, opening, game, or challenge,
but not Castling.club activity names.

**K1:** Render chess positions and moves as a board and move history.

**K2:** Explain that legal moves and challenges use the source rules engine.

**K3:** Permit local discussion and following without pretending to arbitrate.

**Acceptance K:** Find says `Find a player or game`; views expose board, players,
state, and moves; participation presents the source-owned challenge path and
never submits a move during discovery or audit.

## Epic L: articles and blogs

**Knowledge boundary:** The reader knows an author, publication, headline, or
subject, but not WriteFreely, WordPress ActivityPub, RSS, or Article objects.

**L1:** Read a complete article locally with author and publication context.

**L2:** Identify feed-derived articles honestly when replies cannot return.

**L3:** Write long-form content with publishing details and optional cover.

**Acceptance L:** Find says `Find an article or writer`; cards retain author,
date, topics, and discussion; Create provides headline, body, byline, language,
license, date, and media without exposing protocol fields.

## Epic Q: bookmarks and useful links

**Knowledge boundary:** The user knows a page, subject, tag, or curator, but not
Postmarks or bookmark schemas.

**Q1:** Understand why a link was saved before opening it.

**Q2:** Keep title, original address, note, tags, and site name together.

**Q3:** Know that `Open original` leaves the local site.

**Acceptance Q:** Find says `Find a saved link`; result actions are explicit;
Create requires title and web address, permits annotation and tags, and never
asks for an ActivityPub identifier.

## Epic U: publications and knowledge

**Knowledge boundary:** The user knows a document, chapter, author, or subject,
but not ZenPub, Ibis, XWiki, CommonsPub, or document vocabularies.

**U1:** Keep documents, chapters, editions, authors, languages, and licenses together.

**U2:** Read or download while retaining discussion and publisher identity.

**U3:** Start publishing with the document or accessible preview.

**Acceptance U:** Find says `Find a publication or document`; cards distinguish
local discussion from source download; Create is file-first and preserves
author, subject, language, license, audience, and collection context.

## Evidence and ownership

The backend owns normalization, classification, bounded discovery, resolution,
validation, delivery, and capability truth. The frontend owns plain language,
Feed/Find/Create navigation, progressive disclosure, status presentation, safe
source handoff, and accessible forms.

`scripts/audit-worlds-workflows.mjs` is the executable read-only acceptance
runner. It opens Feed, Find, and Create for every family, checks the family
heading, primary finder, and creation or source-owned controls, and fails on
visible errors, JavaScript exceptions, console warnings, same-origin HTTP
failures, or websocket errors. It does not submit forms or activate follow,
join, react, RSVP, or private-contact controls.

<!-- end of WORLDS_USER_EPICS_AND_STORIES.md -->
