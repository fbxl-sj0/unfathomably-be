<!--
  Unfathomably upstream review
  File: UPSTREAM_PIXELFED_AUDIT.md

  Purpose:
    Record the reviewed Pixelfed commit window and the portable lessons applied
    to Unfathomably.

  This file intentionally does not track general Pixelfed compatibility tests
  or claim that Laravel and Passport changes can be copied into the Elixir
  backend unchanged.
-->

# Pixelfed upstream audit

## Review boundary

- Upstream: `pixelfed/pixelfed`, official `dev` branch.
- Base: `032e4436d931cdca21f95a0831dd80867afc22b0`, 2026-06-08,
  `Merge pull request #6625 from pixelfed/staging`.
- Head: `c8bed78bee3d796c5efb57393dafafbba3706f38`, 2026-06-29,
  `Merge pull request #6642 from pixelfed/staging`.
- Window: 19 commits, including 11 non-merge commits.
- Next review cursor: `c8bed78bee3d796c5efb57393dafafbba3706f38`.

June 8 is the nearest commit before the requested June 18 comparison point.
Pixelfed had no commits between June 8 and June 21, so this boundary does not
omit intervening development.

## Applied lesson

### Bound OAuth token issuance independently

Pixelfed added layered throttles to its personal-access-token paths and a
per-minute limit to OAuth token and authorization routes. Unfathomably already
limited authorization submissions, but `/oauth/token` was in a session-only
pipeline and had no dedicated rate-limit plug.

Unfathomably now applies an `:oauth_token` bucket to token exchanges:

- 10 attempts per minute.
- 60 attempts per hour.
- The limit is separate from interactive authorization attempts so normal
  browser login and machine token issuance cannot consume one another's quota.

The implementation uses Unfathomably's existing centralized rate limiter and
therefore preserves its normal API error behavior and runtime configurability.

## Existing Unfathomably safeguards retained

- Requested OAuth scopes are filtered and validated against the scopes
  registered to the client application before authorization or password-grant
  token creation.
- User-bound token creation checks account state and the configured
  authenticator, including MFA where required.
- Token revocation and application ownership remain in the existing OAuth
  model rather than gaining a second Passport-style personal-token subsystem.
- Invitation records already carry expiration and use limits; those semantics
  do not require Pixelfed's Laravel command implementation.

## Commit dispositions

| Commit | Pixelfed change | Unfathomably disposition |
| --- | --- | --- |
| `971b3b7a` | Pin Symfony HTTP Foundation for CVE-2026-48736 | Not portable; Unfathomably does not use PHP or Symfony. Dependency advisories remain part of the native Mix dependency audit. |
| `038a2bbf` | Lint cleanup | No independent behavioral lesson. |
| `adfab57a` | Composer lock update | Not portable to Mix. |
| `d8412ec0` | Admin invite form validation cleanup | Existing invite and registration validation retained. DNS-dependent address rejection was not imported because transient DNS failures should not decide whether an otherwise valid address can be invited. |
| `9fe9b7eb` | Invite expiry, cleanup, and command improvements | Expiry and bounded use are already represented by Unfathomably invite tokens. Laravel command details are not portable. |
| `25d5142f` | OAuth route and personal-token hardening | Token-issuance throttling adapted. Existing scope containment and ownership rules retained. |
| `13e49026` | Laravel route cleanup | Framework-specific; no backend route defect matched it. |
| `e557d37b` | Cache and validate Passport personal-access clients | Not applicable; Unfathomably has no global Passport personal-access client lookup. |
| `8ca77709` | Personal-access-token component changes | Not applicable to the current frontend token workflow. |
| `fb92949a` | Controller return-type cleanup | Framework-specific type annotation. |
| `0f781cba` | Personal-token creation, renewal, throttling, and JSON errors | Throttling adapted. Renewal was deliberately not copied because it preserves old scopes without re-authorizing them and is not atomic with revocation, which can retain obsolete privileges or leave two live tokens after a partial failure. Debug exception details are also inappropriate for production API responses. |

## Deferred opportunities

- If Unfathomably later adds user-managed personal access tokens, creation and
  renewal must validate scopes against the user's current privileges and the
  client application at the moment of issuance.
- A renewal operation must create the replacement and revoke the predecessor in
  one database transaction.
- Token-management UI should list only the authenticated user's active,
  unexpired tokens and should require explicit confirmation before revocation.

## Outcome

This window produced one concrete backend hardening change. The remaining
commits are either already represented by Unfathomably's OAuth and invitation
models, specific to Pixelfed's Laravel/Passport stack, or contain renewal
semantics that should not be adopted without stronger privilege and atomicity
guarantees.

<!-- end of UPSTREAM_PIXELFED_AUDIT.md -->
