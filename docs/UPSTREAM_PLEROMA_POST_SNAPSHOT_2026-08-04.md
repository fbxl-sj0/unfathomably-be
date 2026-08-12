# Pleroma post-snapshot audit, 2026-08-04

The previous upstream snapshot ended at Pleroma commit `b0ae45194` from
2026-06-29. The official `develop` branch was refreshed to `ad7f68b92` from
2026-08-03, adding 259 commits through merged long-lived branches.

## Backported in this pass

- `c3fe61c2f`: invalidate the numeric user cache key when a user changes.
- `868723e37`: preserve streamed posts from explicitly followed accounts when
  their domain is otherwise blocked.
- `59269cf07` and `b97092a97`: preserve existing query distinct clauses while
  fixing multi-hashtag timeline ordering and pagination.
- `2b32e3cf1` and `4a47a756b`: apply configured unauthenticated activity
  restrictions to account status feeds without forcing a slow global plan.
- `2876fed87`: include move targets, emoji data, chat messages, and reports in
  grouped notification responses.
- `a9bf7212d`, `85a802282`, `d0c8ca92a`, `ecd8a1443`, `c51831934`,
  `5f7153244`, and `c5230d98c`: escape feed identifiers and links, correct
  Atom/RSS entry links, and avoid advertising sensitive attachments as feed
  enclosures or previews.

## Already present or superseded

- Elixir 1.19 compatibility and Logger ConfigDB hardening are already covered
  by the current Elixir 1.20 warning-clean source and ConfigDB blacklist.
- Publisher parameters use `String.to_existing_atom/1`, so the upstream atom
  creation issue does not apply.
- OAuth bearer-token lookup cleanup, favourites ordering, preview-card
  compatibility, and duplicate HTTP signature rejection are already present
  in equivalent or stronger Unfathomably code.
- The repository already carries newer Gun and Cowlib dependency releases than
  the versions introduced by the new Pleroma merge.

## Focused integration completed

- Integrated the Gun pool rewrite (`f11ffca7f`) with explicit stream leases,
  HTTP/1 exclusivity, HTTP/2 stream cancellation, connection fingerprints,
  proxy tunnel ownership, and safe idle reclamation. Unfathomably's
  `SSL_CERT_FILE` override, pool configuration, and quieter lifecycle telemetry
  remain intact.
- Integrated extensionless media sniffing (`d5f48101b`) and truncated proxy
  stream aborts (`bc999b330`) while retaining local origin throttling, cached
  failure responses, image placeholders, and Plug-adapter streaming behavior.
- Merged the fedidev.fun normalization series (`ce5c1b4c1`) case by case. The
  result accepts list-valued ActivityStreams types, inferred and list-valued
  tags, varied emoji icon shapes, and safe attachment URL variants without
  dropping Unfathomably's ForgeFed, NeoDB, group, and native-object extensions.

## Optional upstream features not adopted

- ParadeDB search, Mastodon webhooks, passwordless admin account creation, and
  the newer Admin API surfaces are optional features rather than corrections
  to current behavior.

The historical strict audit cursor remains at row 17000. This post-snapshot
review covers newly merged upstream topics and does not falsely mark the older
row 17001 through row 17947 ledger queue as complete.
