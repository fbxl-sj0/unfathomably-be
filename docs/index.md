# Introduction to Unfathomably

## What is Unfathomably?

Unfathomably is a self-hosted social networking stack for the Fediverse. The
backend speaks ActivityPub, exposes Mastodon-compatible client APIs, and adds
bounded support for groups, non-profile sources, Worlds, Nostr, AT Protocol,
and diaspora*. The paired frontend presents those capabilities in the browser.

An instance operator controls registration, moderation, federation policy,
search, translation, media handling, imports, and the optional protocol
bridges. ActivityPub remains the canonical local model even when an object
arrives through another supported protocol.

## Components

- [unfathomably-be](https://github.com/fbxl-sj0/unfathomably-be) owns accounts,
  storage, APIs, federation, moderation, background work, and streaming.
- [unfathomably-fe](https://github.com/fbxl-sj0/unfathomably-fe) provides the
  browser interface.

Mastodon-compatible applications can use common API surfaces, but the paired
frontend exposes the complete Worlds, group, source, archive, and administration
experience.

## Where to begin

Operators should start with the [source installation guide](INSTALLATION.MD) or
the [upgrade guide](UPGRADE.MD), then review the
[configuration reference](configuration/cheatsheet.md) and
[hardening guide](configuration/hardening.md). Peer implementers can use the
[federation manifest](../FEDERATION.md), while contributors should begin with
the verification commands in the repository [README](../README.md).
