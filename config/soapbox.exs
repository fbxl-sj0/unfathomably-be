# Unfathomably default config overrides
# This file gets loaded after config.exs
# and before prod.secret.exs
import Config

# Twitter-like block behavior
config :pleroma, :activitypub, blockers_visible: false

# Sane default upload filters
config :pleroma, Pleroma.Upload,
  filters: [
    Pleroma.Upload.Filter.AnalyzeMetadata,
    Pleroma.Upload.Filter.Dedupe,
    Pleroma.Upload.Filter.Exiftool.StripLocation
  ]

# Default MRF policies
config :pleroma, :mrf,
  policies: [
    Pleroma.Web.ActivityPub.MRF.SimplePolicy,
    Pleroma.Web.ActivityPub.MRF.HellthreadPolicy,
    Pleroma.Web.ActivityPub.MRF.ObjectAgePolicy,
    Pleroma.Web.ActivityPub.MRF.TagPolicy,
    Pleroma.Web.ActivityPub.MRF.InlineQuotePolicy
  ]

# Keep the default connection pool size unless a deployment-specific secret
# config deliberately overrides it. The live database limit is intentionally
# lower than the historical Soapbox pool, so this file should not force a
# dangerzone override for every source install.
config :pleroma, Pleroma.Repo, timeout: 30_000

# Allow privileged staff
config :pleroma, :instance, privileged_staff: true

# Enable instance favicons
config :pleroma, :instances_favicons, enabled: true

# Hellthread limits
config :pleroma, :mrf_hellthread,
  delist_threshold: 15,
  reject_threshold: 100

# Sane default media attachment limit
config :pleroma, :instance, max_media_attachments: 20

# Use Unfathomably branding
config :pleroma, :instance,
  name: "Unfathomably",
  description: "A federated social platform powered by unfathomably-be and unfathomably-fe.",
  instance_thumbnail: "/instance/thumbnail.png",
  stats_refresh_interval: :timer.minutes(15)

config :pleroma, :frontend_configurations,
  soapbox_fe: %{
    allowedEmoji: [
      "\u{1F44D}",
      "\u{2764}\u{FE0F}",
      "\u{1F914}",
      "\u{1F606}",
      "\u{1F62E}",
      "\u{1F621}",
      "\u{1F622}",
      "\u{1F60F}",
      "\u{1F1EB}"
    ]
  }

# Background migration performance
config :pleroma, :delete_context_objects, sleep_interval_ms: 3_000

# Pretend to be WhatsApp because some sites don't return link previews otherwise
config :pleroma, :rich_media, user_agent: "WhatsApp/2"
