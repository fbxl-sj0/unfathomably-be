#!/usr/bin/env bash
#
# Project: Unfathomably backend maintenance
# -----------------------------------------
#
# File: build_scripts/unfathomably-oneoff-remote-history-cleanup.sh
#
# Purpose:
#
#     Run a large, one-time cleanup pass over old cached remote public posts
#     without starting a second Pleroma application node.
#
# Responsibilities:
#
#     - find stale remote public Create/object pairs
#     - preserve anything touched by local users
#     - delete safely bounded batches through psql
#     - leave progress markers for protected rows
#
# This file intentionally does NOT contain:
#
#     - recurring janitor scheduling
#     - application-level pruning callbacks
#     - media cleanup
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DATABASE="${DATABASE:-pleroma}"
BATCH_COUNT="${1:-1}"
WINDOW_SIZE="${REMOTE_CLEANUP_WINDOW_SIZE:-5000}"
MAX_AGE_DAYS="${REMOTE_CLEANUP_MAX_AGE_DAYS:-365}"
STATEMENT_TIMEOUT="${REMOTE_CLEANUP_STATEMENT_TIMEOUT:-30min}"
LOCK_TIMEOUT="${REMOTE_CLEANUP_LOCK_TIMEOUT:-5s}"
PSQL_USER="${REMOTE_CLEANUP_PSQL_USER:-postgres}"

if ! [[ "${BATCH_COUNT}" =~ ^[0-9]+$ ]] || [ "${BATCH_COUNT}" -lt 1 ]; then
    echo "BATCH_COUNT must be a positive integer" >&2
    exit 64
fi

if ! [[ "${WINDOW_SIZE}" =~ ^[0-9]+$ ]] || [ "${WINDOW_SIZE}" -lt 1 ]; then
    echo "REMOTE_CLEANUP_WINDOW_SIZE must be a positive integer" >&2
    exit 64
fi

if ! [[ "${MAX_AGE_DAYS}" =~ ^[0-9]+$ ]] || [ "${MAX_AGE_DAYS}" -lt 1 ]; then
    echo "REMOTE_CLEANUP_MAX_AGE_DAYS must be a positive integer" >&2
    exit 64
fi

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

echo "Starting one-off remote history cleanup"
echo "database=${DATABASE}"
echo "batches=${BATCH_COUNT}"
echo "window_size=${WINDOW_SIZE}"
echo "max_age_days=${MAX_AGE_DAYS}"
echo "statement_timeout=${STATEMENT_TIMEOUT}"
echo "lock_timeout=${LOCK_TIMEOUT}"

for ((batch = 1; batch <= BATCH_COUNT; batch++)); do
    echo
    echo "== batch ${batch}/${BATCH_COUNT} $(date -Is) =="

    sudo -u "${PSQL_USER}" psql \
        --set ON_ERROR_STOP=1 \
        --set window_size="${WINDOW_SIZE}" \
        --set max_age_days="${MAX_AGE_DAYS}" \
        --set statement_timeout="${STATEMENT_TIMEOUT}" \
        --set lock_timeout="${LOCK_TIMEOUT}" \
        --dbname "${DATABASE}" <<'SQL'
\timing on

set statement_timeout to :'statement_timeout';
set lock_timeout to :'lock_timeout';
set idle_in_transaction_session_timeout to '30min';

create unlogged table if not exists maintenance_remote_cleanup_seen (
    object_id bigint primary key,
    seen_at timestamp without time zone not null default timezone('UTC', now())
);

create unlogged table if not exists maintenance_remote_cleanup_cursor (
    name text primary key,
    last_object_id bigint not null default 0,
    updated_at timestamp without time zone not null default timezone('UTC', now())
);

insert into maintenance_remote_cleanup_cursor (name, last_object_id)
values ('remote_history_cleanup_' || (:'max_age_days')::text || 'd', 0)
on conflict (name) do nothing;

create temp table cleanup_local_users as
select
    ap_id,
    md5(ap_id) as ap_id_hash
from users
where local = true
  and ap_id is not null;

create index cleanup_local_users_hash_idx on cleanup_local_users (ap_id_hash);

create temp table cleanup_local_refs as
select
    data->>'object' as object_ap_id,
    md5(data->>'object') as object_ap_id_hash,
    associated_object_id(data) as associated_object_ap_id,
    md5(associated_object_id(data)) as associated_object_ap_id_hash,
    data#>>'{object,inReplyTo}' as embedded_in_reply_to,
    md5(data#>>'{object,inReplyTo}') as embedded_in_reply_to_hash,
    data->>'context' as context,
    md5(data->>'context') as context_hash
from activities
where local = true;

create index cleanup_local_refs_object_idx on cleanup_local_refs (object_ap_id_hash);
create index cleanup_local_refs_assoc_idx on cleanup_local_refs (associated_object_ap_id_hash);
create index cleanup_local_refs_reply_idx on cleanup_local_refs (embedded_in_reply_to_hash);
create index cleanup_local_refs_context_idx on cleanup_local_refs (context_hash);

create temp table cleanup_local_bookmarks as
select
    bookmarks.activity_id,
    activities.data->>'context' as context,
    md5(activities.data->>'context') as context_hash
from bookmarks
join users on users.id = bookmarks.user_id
join activities on activities.id = bookmarks.activity_id
where users.local = true;

create index cleanup_local_bookmarks_activity_idx on cleanup_local_bookmarks (activity_id);
create index cleanup_local_bookmarks_context_idx on cleanup_local_bookmarks (context_hash);

create temp table cleanup_local_notifications as
select
    notifications.activity_id,
    activities.data->>'context' as context,
    md5(activities.data->>'context') as context_hash
from notifications
join users on users.id = notifications.user_id
join activities on activities.id = notifications.activity_id
where users.local = true;

create index cleanup_local_notifications_activity_idx on cleanup_local_notifications (activity_id);
create index cleanup_local_notifications_context_idx on cleanup_local_notifications (context_hash);

create temp table cleanup_candidates as
select distinct on (objects.id)
    objects.id as object_id,
    objects.data->>'id' as object_ap_id,
    md5(objects.data->>'id') as object_ap_id_hash,
    objects.data->>'actor' as object_actor,
    md5(objects.data->>'actor') as object_actor_hash,
    objects.data->>'context' as object_context,
    md5(objects.data->>'context') as object_context_hash,
    coalesce(objects.data->'to', '[]'::jsonb) as object_to,
    coalesce(objects.data->'cc', '[]'::jsonb) as object_cc,
    coalesce(objects.data->'bto', '[]'::jsonb) as object_bto,
    coalesce(objects.data->'bcc', '[]'::jsonb) as object_bcc,
    activities.id as activity_id,
    activities.data->>'id' as activity_ap_id,
    activities.data->>'actor' as activity_actor,
    md5(activities.data->>'actor') as activity_actor_hash,
    activities.data->>'context' as activity_context,
    md5(activities.data->>'context') as activity_context_hash,
    coalesce(activities.data->'to', '[]'::jsonb) as activity_to,
    coalesce(activities.data->'cc', '[]'::jsonb) as activity_cc,
    coalesce(activities.data->'bto', '[]'::jsonb) as activity_bto,
    coalesce(activities.data->'bcc', '[]'::jsonb) as activity_bcc
from objects
join activities on associated_object_id(activities.data) = objects.data->>'id'
where objects.inserted_at < timezone('UTC', now()) - ((:'max_age_days')::int * interval '1 day')
  and objects.updated_at < timezone('UTC', now()) - ((:'max_age_days')::int * interval '1 day')
  and objects.id > (
        select last_object_id
        from maintenance_remote_cleanup_cursor
        where name = 'remote_history_cleanup_' || (:'max_age_days')::text || 'd'
      )
  and activities.inserted_at < timezone('UTC', now()) - ((:'max_age_days')::int * interval '1 day')
  and activities.local = false
  and objects.data->>'type' in ('Note', 'Article', 'Page', 'Question', 'Event', 'Audio', 'Video')
  and activities.data->>'type' = 'Create'
  and (
        objects.data->'to' ? 'https://www.w3.org/ns/activitystreams#Public'
        or objects.data->'cc' ? 'https://www.w3.org/ns/activitystreams#Public'
        or activities.data->'to' ? 'https://www.w3.org/ns/activitystreams#Public'
        or activities.data->'cc' ? 'https://www.w3.org/ns/activitystreams#Public'
      )
  and not exists (
        select 1
        from maintenance_remote_cleanup_seen seen
        where seen.object_id = objects.id
      )
  and not exists (
        select 1
        from cleanup_local_users local_user
        where (
            local_user.ap_id_hash = md5(objects.data->>'actor')
            and local_user.ap_id = objects.data->>'actor'
        ) or (
            local_user.ap_id_hash = md5(activities.data->>'actor')
            and local_user.ap_id = activities.data->>'actor'
        )
      )
order by objects.id, activities.id
limit (:'window_size')::int;

create index cleanup_candidates_object_idx on cleanup_candidates (object_id);
create index cleanup_candidates_activity_idx on cleanup_candidates (activity_id);
create index cleanup_candidates_object_ap_idx on cleanup_candidates (object_ap_id_hash);
create index cleanup_candidates_object_actor_idx on cleanup_candidates (object_actor_hash);
create index cleanup_candidates_activity_actor_idx on cleanup_candidates (activity_actor_hash);
create index cleanup_candidates_object_context_idx on cleanup_candidates (object_context_hash);
create index cleanup_candidates_activity_context_idx on cleanup_candidates (activity_context_hash);

create temp table cleanup_retained as
select distinct candidates.object_id
from cleanup_candidates candidates
where exists (
        select 1
        from cleanup_local_refs refs
        where refs.object_ap_id_hash = candidates.object_ap_id_hash
          and refs.object_ap_id = candidates.object_ap_id
      )
   or exists (
        select 1
        from cleanup_local_refs refs
        where refs.associated_object_ap_id_hash = candidates.object_ap_id_hash
          and refs.associated_object_ap_id = candidates.object_ap_id
      )
   or exists (
        select 1
        from cleanup_local_refs refs
        where refs.embedded_in_reply_to_hash = candidates.object_ap_id_hash
          and refs.embedded_in_reply_to = candidates.object_ap_id
      )
   or exists (
        select 1
        from cleanup_local_refs refs
        where refs.context_hash = candidates.object_context_hash
          and refs.context = candidates.object_context
      )
   or exists (
        select 1
        from cleanup_local_refs refs
        where refs.context_hash = candidates.activity_context_hash
          and refs.context = candidates.activity_context
      )
   or exists (
        select 1
        from cleanup_local_bookmarks bookmarks
        where bookmarks.activity_id = candidates.activity_id
      )
   or exists (
        select 1
        from cleanup_local_bookmarks bookmarks
        where bookmarks.context_hash = candidates.object_context_hash
          and bookmarks.context = candidates.object_context
      )
   or exists (
        select 1
        from cleanup_local_notifications notifications
        where notifications.activity_id = candidates.activity_id
      )
   or exists (
        select 1
        from cleanup_local_notifications notifications
        where notifications.context_hash = candidates.object_context_hash
          and notifications.context = candidates.object_context
      )
   or exists (
        select 1
        from report_notes
        where report_notes.activity_id = candidates.activity_id
      )
   or exists (
        select 1
        from deliveries
        where deliveries.object_id = candidates.object_id
      )
   or exists (
        select 1
        from cleanup_local_users local_user
        where (
            candidates.object_to ? local_user.ap_id
            or candidates.object_cc ? local_user.ap_id
            or candidates.object_bto ? local_user.ap_id
            or candidates.object_bcc ? local_user.ap_id
            or candidates.activity_to ? local_user.ap_id
            or candidates.activity_cc ? local_user.ap_id
            or candidates.activity_bto ? local_user.ap_id
            or candidates.activity_bcc ? local_user.ap_id
        )
      );

create temp table cleanup_prunable as
select candidates.*
from cleanup_candidates candidates
where not exists (
    select 1
    from cleanup_retained retained
    where retained.object_id = candidates.object_id
);

insert into maintenance_remote_cleanup_seen (object_id)
select object_id
from cleanup_retained
on conflict (object_id) do update
set seen_at = excluded.seen_at;

with deleted_activities as (
    delete from activities
    where id in (
        select activity_id
        from cleanup_prunable
    )
    returning id
),
deleted_objects as (
    delete from objects
    where id in (
        select object_id
        from cleanup_prunable
    )
    returning id
)
select
    (select count(*) from cleanup_candidates) as scanned_candidates,
    (select count(*) from cleanup_prunable) as prunable_candidates,
    (select count(*) from deleted_activities) as deleted_activities,
    (select count(*) from deleted_objects) as deleted_objects,
    (select count(*) from cleanup_retained) as marked_retained;

insert into maintenance_remote_cleanup_cursor (name, last_object_id, updated_at)
select
    'remote_history_cleanup_' || (:'max_age_days')::text || 'd',
    coalesce(
        max(object_id),
        (
            select last_object_id
            from maintenance_remote_cleanup_cursor
            where name = 'remote_history_cleanup_' || (:'max_age_days')::text || 'd'
        )
    ),
    timezone('UTC', now())
from cleanup_candidates
on conflict (name) do update
set
    last_object_id = greatest(
        maintenance_remote_cleanup_cursor.last_object_id,
        excluded.last_object_id
    ),
    updated_at = excluded.updated_at;

select
    name as cleanup_cursor,
    last_object_id
from maintenance_remote_cleanup_cursor
where name = 'remote_history_cleanup_' || (:'max_age_days')::text || 'd';
SQL
done

echo
echo "Finished one-off remote history cleanup $(date -Is)"

# end of build_scripts/unfathomably-oneoff-remote-history-cleanup.sh
