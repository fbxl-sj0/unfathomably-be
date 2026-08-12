<!--
Unfathomably BE

File: SECURITY.md
Purpose: Explain supported releases and safe vulnerability reporting.
Responsibilities: Direct private reports to this project and define useful scope.
This file intentionally does not publish operational secrets or exploit details.
-->

# Unfathomably backend security policy

## Supported versions

Security fixes are made against the current minor release line. Older release
lines should be upgraded before requesting a backport.

| Version | Support |
| --- | --- |
| 3.5.x | Security fixes |
| 3.4.x and earlier | Not supported |

The development branch can contain unreleased schema or configuration changes
and is not a substitute for a tagged release.

## Reporting a vulnerability

Do not open a public issue containing vulnerability details, credentials,
private user data, or a working exploit.

When GitHub private vulnerability reporting is available, use the repository's
[private vulnerability report](https://github.com/fbxl-sj0/unfathomably-be/security/advisories/new).
If that form is unavailable, contact the repository maintainers through a
private channel before sharing technical details. A public issue may request a
private contact method, but must not describe the vulnerability.

A useful report includes:

- the affected version or commit
- the deployment shape and relevant non-secret configuration
- the security impact and who can trigger it
- a minimal reproduction or proof of concept
- sanitized logs, request bodies, or stack traces
- any known workaround or proposed fix

Do not test against an installation you do not own or have permission to test.

## Scope

Reports may cover the backend, its API and federation boundaries, bundled
runtime assets, database migrations, and checked-in installation or build
scripts. A flaw in peer software is outside this project's scope unless an
Unfathomably trust-boundary failure makes that flaw exploitable here.

## Handling and announcements

Maintainers will validate the report, determine affected versions, prepare a
fix, and coordinate disclosure with the reporter when practical. Security
notices and fixed releases are published through this repository's GitHub
Security Advisories and release notes.

<!-- end of SECURITY.md -->
