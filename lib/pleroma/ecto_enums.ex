# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

import EctoEnum

defenum(Pleroma.UserRelationship.Type,
  block: 1,
  mute: 2,
  reblog_mute: 3,
  notification_mute: 4,
  inverse_subscription: 5,
  suggestion_dismiss: 6,
  endorsement: 7
)

defenum(Pleroma.FollowingRelationship.State,
  follow_pending: 1,
  follow_accept: 2,
  follow_reject: 3
)

defenum(Pleroma.DataMigration.State,
  pending: 1,
  running: 2,
  complete: 3,
  failed: 4,
  manual: 5
)

defenum(Pleroma.User.Backup.State,
  pending: 1,
  running: 2,
  complete: 3,
  failed: 4,
  invalid: 5
)

defenum(Pleroma.User.PostArchiveImport.State,
  pending: 1,
  awaiting_review: 2,
  approved: 3,
  running: 4,
  complete: 5,
  failed: 6,
  rejected: 7,
  invalid: 8
)
