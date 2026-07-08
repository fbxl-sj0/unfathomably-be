# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.MalformedJobsTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.Workers.AttachmentsCleanupWorker
  alias Pleroma.Workers.BackupWorker
  alias Pleroma.Workers.EventReminderWorker
  alias Pleroma.Workers.MailerWorker
  alias Pleroma.Workers.MuteExpireWorker
  alias Pleroma.Workers.NotificationWorker
  alias Pleroma.Workers.PollWorker
  alias Pleroma.Workers.PostArchiveImportWorker
  alias Pleroma.Workers.PurgeExpiredActivity
  alias Pleroma.Workers.PurgeExpiredFilter
  alias Pleroma.Workers.PurgeExpiredToken
  alias Pleroma.Workers.RichMediaWorker
  alias Pleroma.Workers.ScheduledActivityWorker
  alias Pleroma.Workers.SearchIndexingWorker
  alias Pleroma.Workers.WebPusherWorker

  test "notification and reminder workers cancel missing activities" do
    assert :discard =
             NotificationWorker.perform(%Oban.Job{
               args: %{"op" => "create", "activity_id" => nil}
             })

    assert {:cancel, :activity_not_found} =
             NotificationWorker.perform(%Oban.Job{
               args: %{"op" => "create", "activity_id" => "not-a-real-activity"}
             })

    assert :discard =
             EventReminderWorker.perform(%Oban.Job{
               args: %{"op" => "event_reminder", "activity_id" => nil}
             })

    assert {:cancel, :event_activity_not_found} =
             EventReminderWorker.perform(%Oban.Job{
               args: %{"op" => "event_reminder", "activity_id" => "not-a-real-event"}
             })
  end

  test "push and poll workers discard malformed jobs and cancel stale records" do
    assert :discard =
             WebPusherWorker.perform(%Oban.Job{
               args: %{"op" => "web_push", "notification_id" => nil}
             })

    assert {:cancel, :notification_not_found} =
             WebPusherWorker.perform(%Oban.Job{
               args: %{"op" => "web_push", "notification_id" => "not-a-real-notification"}
             })

    assert :discard =
             PollWorker.perform(%Oban.Job{
               args: %{"op" => "poll_end", "activity_id" => nil}
             })

    assert {:cancel, :poll_activity_not_found} =
             PollWorker.perform(%Oban.Job{
               args: %{"op" => "poll_end", "activity_id" => "not-a-real-poll"}
             })
  end

  test "search indexing jobs cancel missing source records" do
    assert :discard =
             SearchIndexingWorker.perform(%Oban.Job{
               args: %{"op" => "add_to_index", "activity" => nil}
             })

    assert {:cancel, :activity_not_found} =
             SearchIndexingWorker.perform(%Oban.Job{
               args: %{"op" => "add_to_index", "activity" => "not-a-real-activity"}
             })

    assert :discard =
             SearchIndexingWorker.perform(%Oban.Job{
               args: %{"op" => "remove_from_index", "object" => nil}
             })

    assert {:cancel, :object_not_found} =
             SearchIndexingWorker.perform(%Oban.Job{
               args: %{"op" => "remove_from_index", "object" => "not-a-real-object"}
             })
  end

  test "attachment cleanup tolerates malformed attachment entries" do
    clear_config([:instance, :cleanup_attachments], true)

    assert {:ok, :success} =
             AttachmentsCleanupWorker.perform(%Oban.Job{
               args: %{
                 "op" => "cleanup_attachments",
                 "object" => %{
                   "data" => %{
                     "actor" => "https://remote.example/users/alice",
                     "attachment" => [
                       %{
                         "name" => "image.png",
                         "url" => [
                           %{"href" => "https://example.test/media/image.png"},
                           %{"href" => nil},
                           %{"bad" => "shape"}
                         ]
                       },
                       %{"name" => 42, "url" => 42},
                       nil
                     ]
                   }
                 }
               }
             })
  end

  test "rich media jobs discard malformed urls" do
    assert {:cancel, :bad_request} =
             RichMediaWorker.perform(%Oban.Job{
               args: %{"op" => "expire", "url" => nil}
             })

    assert {:cancel, :bad_request} =
             RichMediaWorker.perform(%Oban.Job{
               args: %{"op" => "backfill", "url" => nil}
             })
  end

  test "scheduled activity jobs discard malformed args and cancel stale records" do
    assert :discard =
             ScheduledActivityWorker.perform(%Oban.Job{
               args: %{"activity_id" => nil}
             })

    assert {:cancel, :scheduled_activity_not_found} =
             ScheduledActivityWorker.perform(%Oban.Job{
               args: %{"activity_id" => "not-a-real-scheduled-activity"}
             })
  end

  test "expiration workers discard malformed args and cancel stale records" do
    assert :discard =
             PurgeExpiredActivity.perform(%Oban.Job{
               args: %{"activity_id" => nil}
             })

    assert {:cancel, :activity_not_found} =
             PurgeExpiredActivity.perform(%Oban.Job{
               args: %{"activity_id" => "not-a-real-expired-activity"}
             })

    assert :discard =
             PurgeExpiredFilter.perform(%Oban.Job{
               args: %{"filter_id" => nil}
             })

    assert {:cancel, :filter_not_found} =
             PurgeExpiredFilter.perform(%Oban.Job{
               args: %{"filter_id" => "not-a-real-filter"}
             })

    assert :discard =
             PurgeExpiredToken.perform(%Oban.Job{
               args: %{"token_id" => nil, "mod" => "Pleroma.Web.OAuth.Token"}
             })

    assert {:cancel, :invalid_token_module} =
             PurgeExpiredToken.perform(%Oban.Job{
               args: %{"token_id" => 1, "mod" => "Pleroma.Does.Not.Exist"}
             })
  end

  test "post archive imports cancel stale import records" do
    assert :discard =
             PostArchiveImportWorker.perform(%Oban.Job{
               args: %{"op" => "process", "import_id" => nil}
             })

    assert {:cancel, :post_archive_import_not_found} =
             PostArchiveImportWorker.perform(%Oban.Job{
               args: %{"op" => "process", "import_id" => "not-a-real-import"}
             })
  end

  test "backup jobs discard malformed args and cancel stale process records" do
    assert :discard =
             BackupWorker.perform(%Oban.Job{
               args: %{"op" => "process", "backup_id" => nil, "admin_user_id" => nil}
             })

    assert {:cancel, :backup_not_found} =
             BackupWorker.perform(%Oban.Job{
               args: %{
                 "op" => "process",
                 "backup_id" => "not-a-real-backup",
                 "admin_user_id" => nil
               }
             })

    assert :discard =
             BackupWorker.perform(%Oban.Job{
               args: %{"op" => "unknown_backup_op"}
             })
  end

  test "mailer jobs cancel invalid payloads" do
    assert :discard =
             MailerWorker.perform(%Oban.Job{
               args: %{"op" => "email", "encoded_email" => nil, "config" => []}
             })

    assert {:cancel, :invalid_email_payload} =
             MailerWorker.perform(%Oban.Job{
               args: %{"op" => "email", "encoded_email" => "not base64", "config" => []}
             })
  end

  test "mute expiration jobs discard malformed ids" do
    assert :discard =
             MuteExpireWorker.perform(%Oban.Job{
               args: %{"op" => "unmute_user", "muter_id" => nil, "mutee_id" => 1}
             })

    assert :discard =
             MuteExpireWorker.perform(%Oban.Job{
               args: %{
                 "op" => "unmute_conversation",
                 "user_id" => 1,
                 "activity_id" => nil
               }
             })
  end
end

# end of malformed_jobs_test.exs
