# Unfathomably BE documentation

Unfathomably BE is the Elixir backend for the Unfathomably social networking
stack. It is derived from Rebased and Pleroma, retains Mastodon API
compatibility, and adds broader ActivityPub, Worlds, and selective protocol
bridge support.

## Start here

- [Install a new source deployment](INSTALLATION.MD)
- [Enable optional protocols and product features](FEATURE_ENABLEMENT.md)
- [Upgrade a Rebased, Soapbox, or Pleroma deployment](UPGRADE.MD)
- [Review configuration](configuration/cheatsheet.md)
- [Harden a deployment](configuration/hardening.md)
- [Understand federation support](../FEDERATION.md)
- [Run federation tests](../FEDERATION_TESTING.md)
- [Report a security issue](../SECURITY.md)

## Inherited names

The OTP application, configuration namespace, database conventions, and many
Mix tasks still use the name `pleroma`. Those names are compatibility surfaces,
not references to a separate service that must be installed alongside
Unfathomably.

The public project overview is in the repository [README](../README.md).
