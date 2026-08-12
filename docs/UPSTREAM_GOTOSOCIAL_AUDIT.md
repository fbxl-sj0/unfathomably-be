<!--
  Unfathomably backend
  File: docs/UPSTREAM_GOTOSOCIAL_AUDIT.md
  Purpose: Record transferable GoToSocial federation lessons and dispositions.
  This file does not claim source compatibility with GoToSocial.
-->

# GoToSocial federation audit

## Scope

This audit reviewed the official GoToSocial Codeberg repository from the
conservative base `c74c5b74049bf9530a4c3fa5ba99c63fdd85d178` dated December
17, 2025 through commit `ace81a2480e6101edfb6a6e6563eccda979e55c3` dated
August 4, 2026. The screen covered all 188 commits reachable after January 1.
No earlier dedicated GoToSocial audit cursor was present, so this is the
baseline for future incremental reviews.

GoToSocial and Unfathomably use different languages, persistence models, and
delivery pipelines. The changes below adapt protocol lessons at existing
Unfathomably boundaries rather than copying Go implementation details.

## Implemented lessons

- `b49939a6a0624966563ccf73f42cf29010caf3c4`: prefer the current
  `replyAuthorization` property while accepting deprecated `approvedBy` on
  incoming replies. Unfathomably canonicalizes one authorization URI and
  advertises the GoToSocial JSON-LD term when re-serving the object.
- `867ce73d0759d3ed899b4eed30bd3640c35a3a54`: treat singular authorization
  properties as singular. Singleton arrays remain compatible; ambiguous
  multi-value authorizations are not reduced to an arbitrary first value.
- `c336ea0849096a48065ec7ad75aef822fa87ec11`: consider a poll closed once its
  known closing time passes even when the remote closing Update has not yet
  arrived. The API rejects late votes and the frontend derives expiry from
  `expires_at` as a defensive fallback.
- `ad4dea9831a03ec5726511bcfeed00eb658ae744`: distinguish fetched history from
  delivered posts. Objects older than 25 hours that enter through explicit
  dereferencing are still stored, indexed, counted, and associated with their
  group or thread, but are not emitted as fresh websocket events or mention
  notifications. Ordinary inbox deliveries are unchanged.

## Already covered

- `8bc9103f018956efd50aada5e765b2b372d8d17b` and
  `e0bc24aadc2456f88943cc87d16f1aa15afb5985`: blocked forwarded activities
  and unsupported Announce shapes already terminate cleanly in the inbox and
  receiver-worker paths instead of becoming retrying server errors.
- `6a5794e6bb94dbb34f090dff58c305aec68ddf2c`: remote thread fetching already
  classifies terminal, transient, cooldown, depth, and rate-limit outcomes and
  gives the Oban janitor enough structure to remove stale terminal work.
- `42a231a98b6e844392bd1a6de6bc1ced5deeff83` and
  `dd7d659129a4d163791d7370489b59470852b58e`: deterministic media failures are
  negative-cached, malformed attachment entries are dropped without losing
  the post, and valid attachments retain safe placeholder/proxy behavior.
- `de2e6a066e03adcd9b33b29c6e1b989c6ae6ebb3`: public-key lookup and signature
  failures already return authentication errors or bounded retry results;
  malformed keys do not escape as unhandled internal exceptions.
- `5caf33de0dac9260da3dc49daa3873e736c6cb25` and
  `663d725c92b4047a0f38e926820e052331b14644`: group and relay-style Announces
  already reconcile cached objects and stream accepted group traffic through
  the same timeline side-effect path as ordinary remote Create activities.

## Not transplanted

- GoToSocial's relay actor CRUD, subscription administration, and relay push
  interface do not map directly to Unfathomably's Group, source, FediBuzz, and
  native discovery architecture. Adding a parallel relay account system would
  duplicate policy and relationship state.
- Go module updates, Gin removal, SQLite migrations and REPL tooling, Bun query
  changes, and Go-specific media-process handling are implementation details
  rather than portable ActivityPub behavior.
- GoToSocial's static settings frontend and database-specific administration
  pages are not copied into Soapbox or AdminFE. Equivalent capabilities remain
  in their existing Unfathomably surfaces.

## Next cursor

Resume after `ace81a2480e6101edfb6a6e6563eccda979e55c3`.

<!-- end of docs/UPSTREAM_GOTOSOCIAL_AUDIT.md -->
