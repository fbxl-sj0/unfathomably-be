#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-wordpress-smoke.sh
#
# Purpose:
#
#   Run the stock WordPress ActivityPub plugin in blog actor mode against
#   Unfathomably and exercise the plugin's native federation collections.
#
# Responsibilities:
#
#   * install a disposable WordPress site and the upstream ActivityPub plugin
#   * test bidirectional Group follows and their Undo activities
#   * test posts, comments, Likes, Undo Likes, and Delete activities
#   * test local actor and domain moderation state on both peers
#   * report moderation capabilities the plugin does not implement
#
# This file intentionally does NOT contain:
#
#   * a patched WordPress or ActivityPub plugin build
#   * production WordPress credentials or deployment settings
#   * Mastodon API assumptions for WordPress
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-wordpress-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-wordpress.test}"
export BE_PORT="${BE_PORT:-5015}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_wordpress_smoke_be}"
export GTS_HOST="${GTS_HOST:-wordpress-ref.test}"
export GTS_PORT="${GTS_PORT:-5016}"
export GTS_APP_PORT=80
export GTS_LABEL=WordPress
export GTS_USERNAME="${WORDPRESS_BLOG_IDENTIFIER:-blog}"
export GTS_IMAGE="${WORDPRESS_IMAGE:-wordpress:latest}"

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

WORDPRESS_CLI_IMAGE="${WORDPRESS_CLI_IMAGE:-wordpress:cli}"
WORDPRESS_DB_IMAGE="${WORDPRESS_DB_IMAGE:-mariadb:11}"
WORDPRESS_DB_CONTAINER="${PREFIX}-wordpress-db"
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=wordpress-smoke-password
WORDPRESS_ADMIN=smokeadmin
WORDPRESS_ADMIN_EMAIL=admin@wordpress-smoke.test
WORDPRESS_VOLUME="$GTS_VOLUME"
WORDPRESS_ACTOR="http://$GTS_HOST/@$GTS_USERNAME"

cleanup() {
    local status="$?"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        printf '\nKEEP_CONTAINERS=1, leaving containers and work directory in place.\n' >&2
        exit "$status"
    fi

    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$WORDPRESS_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$WORDPRESS_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    exit "$status"
}

wordpress_cli() {
    docker run --rm \
        --user 33:33 \
        --network "$NETWORK" \
        --volumes-from "$GTS_CONTAINER" \
        -e HOME=/tmp \
        -e WORDPRESS_DB_HOST="$WORDPRESS_DB_CONTAINER" \
        -e WORDPRESS_DB_NAME="$WORDPRESS_DB_NAME" \
        -e WORDPRESS_DB_USER="$WORDPRESS_DB_USER" \
        -e WORDPRESS_DB_PASSWORD="$WORDPRESS_DB_PASSWORD" \
        -e WORDPRESS_CONFIG_EXTRA="define('WP_HOME', 'http://$GTS_HOST'); define('WP_SITEURL', 'http://$GTS_HOST');" \
        "$WORDPRESS_CLI_IMAGE" \
        --path=/var/www/html "$@"
}

wait_wordpress_files() {
    for _ in $(seq 1 90); do
        if wordpress_cli core version >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "WordPress did not finish installing its core files"
}

wait_wordpress_http() {
    for _ in $(seq 1 90); do
        if curl -fsS "$GTS_BASE/" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for WordPress at $GTS_BASE"
}

start_wordpress() {
    docker volume create "$WORDPRESS_VOLUME" >/dev/null

    docker run -d \
        --name "$WORDPRESS_DB_CONTAINER" \
        --network "$NETWORK" \
        -e MARIADB_DATABASE="$WORDPRESS_DB_NAME" \
        -e MARIADB_USER="$WORDPRESS_DB_USER" \
        -e MARIADB_PASSWORD="$WORDPRESS_DB_PASSWORD" \
        -e MARIADB_RANDOM_ROOT_PASSWORD=yes \
        "$WORDPRESS_DB_IMAGE" >/dev/null

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e WORDPRESS_DB_HOST="$WORDPRESS_DB_CONTAINER" \
        -e WORDPRESS_DB_NAME="$WORDPRESS_DB_NAME" \
        -e WORDPRESS_DB_USER="$WORDPRESS_DB_USER" \
        -e WORDPRESS_DB_PASSWORD="$WORDPRESS_DB_PASSWORD" \
        -e WORDPRESS_CONFIG_EXTRA="define('WP_HOME', 'http://$GTS_HOST'); define('WP_SITEURL', 'http://$GTS_HOST');" \
        -v "$WORDPRESS_VOLUME:/var/www/html" \
        "$GTS_IMAGE" >/dev/null

    wait_wordpress_files
    start_gts_proxy
    wait_wordpress_http
}

install_activitypub_plugin() {
    wordpress_cli core install \
        --url="http://$GTS_HOST" \
        --title='Unfathomably WordPress Smoke' \
        --admin_user="$WORDPRESS_ADMIN" \
        --admin_password="$PASSWORD" \
        --admin_email="$WORDPRESS_ADMIN_EMAIL" \
        --skip-email >/dev/null
    wordpress_cli rewrite structure '/%postname%/' --hard >/dev/null
    wordpress_cli plugin install activitypub --activate >/dev/null
    wordpress_cli option update activitypub_actor_mode blog >/dev/null
    wordpress_cli option update activitypub_blog_identifier "$GTS_USERNAME" >/dev/null

    # WordPress's safe HTTP helper rejects Docker's private network addresses.
    # The smoke network is isolated and every hostname is controlled here, so
    # this local-only filter lets the unmodified plugin fetch its test peers.
    wordpress_cli eval '
        wp_mkdir_p( WPMU_PLUGIN_DIR );
        file_put_contents(
            WPMU_PLUGIN_DIR . "/unfathomably-smoke.php",
            "<?php add_filter( \"http_request_host_is_external\", \"__return_true\" );"
        );
    ' >/dev/null
    wordpress_cli cache flush >/dev/null || true
}

flush_wordpress_federation() {
    local _

    for _ in 1 2 3; do
        wordpress_cli cron event run --due-now >/dev/null 2>&1 || true
        wordpress_cli action-scheduler run --batch-size=100 >/dev/null 2>&1 || true
        sleep 2
    done
}

wordpress_eval() {
    wordpress_cli eval "$1"
}

poll_wordpress_scalar() {
    local code="$1"
    local expected="$2"
    local message="$3"
    local value=""

    for _ in $(seq 1 90); do
        flush_wordpress_federation
        value="$(wordpress_eval "$code" 2>/dev/null || true)"

        if [ "$value" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message; last WordPress value was ${value:-empty}"
}

poll_wordpress_comment_text() {
    local text="$1"
    local expected="$2"
    local message="$3"
    local code

    code="global \$wpdb; echo (int) \$wpdb->get_var( \$wpdb->prepare( 'SELECT COUNT(*) FROM ' . \$wpdb->comments . ' WHERE comment_content LIKE %s', '%$text%' ) );"
    poll_wordpress_scalar "$code" "$expected" "$message"
}

poll_wordpress_like_count() {
    local post_id="$1"
    local expected="$2"
    local message="$3"
    local code

    code="global \$wpdb; echo (int) \$wpdb->get_var( \$wpdb->prepare( 'SELECT COUNT(*) FROM ' . \$wpdb->comments . ' WHERE comment_post_ID = %d AND comment_type = %s', $post_id, 'like' ) );"
    poll_wordpress_scalar "$code" "$expected" "$message"
}

poll_be_followed_by() {
    local account_id="$1"
    local expected="$2"
    local message="$3"

    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$account_id' '$ALICE_TOKEN' 200" \
        "len(data) == 1 and data[0].get('followed_by') is $expected" \
        "$message" >/dev/null
}

prepare_wordpress_like() {
    local object_uri="$1"
    local target_actor="$2"

    wordpress_eval "
        \$activity = new \\Activitypub\\Activity\\Activity();
        \$activity->set_type( 'Like' );
        \$activity->set_actor( \\Activitypub\\Collection\\Actors::get_by_id( 0 )->get_id() );
        \$activity->set_object( '$object_uri' );
        \$activity->set_to( array( '$target_actor' ) );
        \$result = \\Activitypub\\add_to_outbox( \$activity, null, 0, ACTIVITYPUB_CONTENT_VISIBILITY_PRIVATE );
        if ( ! \$result || is_wp_error( \$result ) ) {
            fwrite( STDERR, is_wp_error( \$result ) ? \$result->get_error_message() : 'Failed to queue Like' );
            exit( 1 );
        }
        echo \$result;
    "
}

prepare_wordpress_block() {
    local target_actor="$1"

    wordpress_eval "
        \$blocked = \\Activitypub\\Moderation::add_user_block(
            0,
            \\Activitypub\\Moderation::TYPE_ACTOR,
            '$target_actor'
        );
        if ( ! \$blocked || is_wp_error( \$blocked ) ) {
            fwrite( STDERR, is_wp_error( \$blocked ) ? \$blocked->get_error_message() : 'Failed to retain local actor block' );
            exit( 1 );
        }

        \$activity = new \\Activitypub\\Activity\\Activity();
        \$activity->set_type( 'Block' );
        \$activity->set_actor( \\Activitypub\\Collection\\Actors::get_by_id( 0 )->get_id() );
        \$activity->set_object( '$target_actor' );
        \$activity->set_to( array( '$target_actor' ) );
        \$result = \\Activitypub\\add_to_outbox(
            \$activity,
            null,
            0,
            ACTIVITYPUB_CONTENT_VISIBILITY_PRIVATE
        );
        if ( ! \$result || is_wp_error( \$result ) ) {
            fwrite( STDERR, is_wp_error( \$result ) ? \$result->get_error_message() : 'Failed to queue Block' );
            exit( 1 );
        }
        echo \$result;
    "
}

write_be_secret
write_proxy_configs

log "Creating Docker network"
docker rm -f \
    "$GTS_PROXY_CONTAINER" \
    "$GTS_CONTAINER" \
    "$WORDPRESS_DB_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker volume rm "$WORDPRESS_VOLUME" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

log "Starting databases and stock WordPress"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres
prepare_database
start_wordpress
install_activitypub_plugin

log "Migrating and starting Unfathomably"
migrate_and_create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be
ALICE_TOKEN="$(create_be_token alice)"

log "Creating the Unfathomably Group actor"
BE_GROUP="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    'display_name=Unfathomably WordPress Smoke' \
    'name=unfathomably_wordpress_smoke' \
    'note=Open group used by the WordPress federation smoke.' \
    'locked=false')"
BE_GROUP_ACTOR="http://$BE_HOST/users/unfathomably_wordpress_smoke"
BE_ALICE_ACTOR="http://$BE_HOST/users/alice"

log "Following the WordPress blog Group from Unfathomably"
WORDPRESS_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "$WORDPRESS_ACTOR" \
    "Unfathomably could not resolve the WordPress blog actor")"
BE_FOLLOW="$(http_form POST "$BE_BASE/api/v1/accounts/$WORDPRESS_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW" \
    'data.get("following") is True or data.get("requested") is True' \
    "Unfathomably could not follow the WordPress blog actor"
poll_wordpress_scalar \
    'echo \Activitypub\Collection\Followers::count( 0 );' \
    1 \
    "WordPress did not register the Unfathomably follower"

log "Following Unfathomably Person and Group actors from WordPress"
wordpress_eval "
    \$result = \\Activitypub\\follow( '$BE_ALICE_ACTOR', 0 );
    if ( is_wp_error( \$result ) ) { fwrite( STDERR, \$result->get_error_message() ); exit( 1 ); }
" >/dev/null
flush_wordpress_federation
poll_be_followed_by "$WORDPRESS_ACCOUNT_ID" True \
    "Unfathomably did not register the WordPress blog follow"

wordpress_eval "
    \$result = \\Activitypub\\follow( '$BE_GROUP_ACTOR', 0 );
    if ( is_wp_error( \$result ) ) { fwrite( STDERR, \$result->get_error_message() ); exit( 1 ); }
" >/dev/null
flush_wordpress_federation
poll_wordpress_scalar \
    "echo count( \\Activitypub\\Collection\\Following::get_many( 0 ) );" \
    2 \
    "WordPress did not retain its Person and Group follows"

log "Testing WordPress post, Like, comment, and Delete delivery"
WORDPRESS_TITLE="WordPress to Unfathomably $(basename "$WORK_DIR")"
WORDPRESS_POST_ID="$(wordpress_cli post create \
    --post_type=post \
    --post_status=publish \
    --post_title="$WORDPRESS_TITLE" \
    --post_content="$WORDPRESS_TITLE. A disposable WordPress ActivityPub smoke post." \
    --post_author=1 \
    --porcelain)"
flush_wordpress_federation
BE_VIEW_ID="$(poll_account_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
    "$WORDPRESS_ACCOUNT_ID" "$WORDPRESS_TITLE" \
    "Unfathomably did not receive the WordPress post")"
BE_VIEW="$(http_form GET "$BE_BASE/api/v1/statuses/$BE_VIEW_ID" "$ALICE_TOKEN" 200)"
WORDPRESS_POST_URI="$(json_get "$BE_VIEW" uri)"

BE_LIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE" 'data.get("favourited") is True' \
    "Unfathomably could not like the WordPress post"
poll_wordpress_like_count "$WORDPRESS_POST_ID" 1 \
    "WordPress did not store the Unfathomably Like"

BE_UNLIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE" 'data.get("favourited") is False' \
    "Unfathomably could not undo its WordPress Like"
poll_wordpress_like_count "$WORDPRESS_POST_ID" 0 \
    "WordPress retained the Unfathomably Like after Undo"

BE_REPLY_TEXT="Unfathomably reply to WordPress $(basename "$WORK_DIR")"
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_VIEW_ID")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
poll_wordpress_comment_text "$BE_REPLY_TEXT" 1 \
    "WordPress did not store the Unfathomably comment"
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_wordpress_comment_text "$BE_REPLY_TEXT" 0 \
    "WordPress retained the Unfathomably comment after Delete"

WORDPRESS_COMMENT_TEXT="WordPress reply to Unfathomably $(basename "$WORK_DIR")"

# The WP-CLI --user option selects the command's execution user, but it does
# not populate wp_comments.user_id.  The ActivityPub plugin intentionally
# federates only comments owned by a registered local user.
WORDPRESS_COMMENT_ID="$(wordpress_cli comment create \
    --comment_post_ID="$WORDPRESS_POST_ID" \
    --comment_content="$WORDPRESS_COMMENT_TEXT" \
    --comment_author='WordPress Smoke' \
    --comment_author_email="$WORDPRESS_ADMIN_EMAIL" \
    --comment_approved=1 \
    --user_id="$(wordpress_cli user get "$WORDPRESS_ADMIN" --field=ID)" \
    --user="$WORDPRESS_ADMIN" \
    --porcelain)"
flush_wordpress_federation
poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$BE_VIEW_ID" \
    "$WORDPRESS_COMMENT_TEXT" \
    "Unfathomably did not receive the WordPress comment" >/dev/null
wordpress_cli comment delete "$WORDPRESS_COMMENT_ID" --force >/dev/null
flush_wordpress_federation

log "Testing WordPress outbound Like and Undo Like"
BE_POST_TEXT="Unfathomably post for WordPress engagement $(basename "$WORK_DIR")"
BE_POST="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 "status=$BE_POST_TEXT")"
BE_POST_ID="$(json_get "$BE_POST" id)"
BE_POST_URI="$(json_get "$BE_POST" uri)"
WORDPRESS_LIKE_ID="$(prepare_wordpress_like "$BE_POST_URI" "$BE_ALICE_ACTOR")"
flush_wordpress_federation
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_POST_ID" \
    'int(data.get("favourites_count") or 0) >= 1' \
    "Unfathomably did not receive the WordPress Like"
wordpress_cli activitypub outbox undo "$WORDPRESS_LIKE_ID" >/dev/null
flush_wordpress_federation
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_POST_ID" \
    'int(data.get("favourites_count") or 0) == 0' \
    "Unfathomably did not receive the WordPress Undo Like"

# The ActivityPub plugin schedules a Delete when the published post changes to
# WordPress's non-public trash state.  A forced hard delete bypasses the
# wp_after_insert_post transition that owns that federation lifecycle.
wordpress_cli post delete "$WORDPRESS_POST_ID" >/dev/null
flush_wordpress_federation
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_VIEW_ID" \
    "Unfathomably retained the deleted WordPress post"

log "Testing follow cleanup and moderation state"
wordpress_eval "
    \$result = \\Activitypub\\unfollow( '$BE_GROUP_ACTOR', 0 );
    if ( is_wp_error( \$result ) ) { fwrite( STDERR, \$result->get_error_message() ); exit( 1 ); }
" >/dev/null
wordpress_eval "
    \$result = \\Activitypub\\unfollow( '$BE_ALICE_ACTOR', 0 );
    if ( is_wp_error( \$result ) ) { fwrite( STDERR, \$result->get_error_message() ); exit( 1 ); }
" >/dev/null
flush_wordpress_federation
poll_be_followed_by "$WORDPRESS_ACCOUNT_ID" False \
    "Unfathomably retained the WordPress blog follow after Undo Follow"

http_form POST "$BE_BASE/api/v1/accounts/$WORDPRESS_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
poll_wordpress_scalar \
    'echo \Activitypub\Collection\Followers::count( 0 );' \
    0 \
    "WordPress retained the Unfathomably follower after Undo Follow"

WORDPRESS_BLOCK_ID="$(prepare_wordpress_block "$BE_ALICE_ACTOR")"
flush_wordpress_federation
poll_json_assert \
    "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$WORDPRESS_ACCOUNT_ID' '$ALICE_TOKEN' 200" \
    "len(data) == 1 and data[0].get('blocked_by') is True" \
    "Unfathomably did not retain the WordPress Block" >/dev/null
wordpress_cli activitypub outbox undo "$WORDPRESS_BLOCK_ID" >/dev/null
flush_wordpress_federation

BE_BLOCK="$(http_form POST "$BE_BASE/api/v1/accounts/$WORDPRESS_ACCOUNT_ID/block" "$ALICE_TOKEN" 200)"
json_assert "$BE_BLOCK" 'data.get("blocking") is True' \
    "Unfathomably did not retain its WordPress block"
http_form POST "$BE_BASE/api/v1/accounts/$WORDPRESS_ACCOUNT_ID/unblock" "$ALICE_TOKEN" 200 >/dev/null

wordpress_eval "
    \\Activitypub\\Moderation::add_site_block( \\Activitypub\\Moderation::TYPE_DOMAIN, '$BE_HOST' );
    \$blocks = \\Activitypub\\Moderation::get_site_blocks();
    echo in_array( '$BE_HOST', \$blocks['domains'], true ) ? 'blocked' : 'missing';
" | grep -qx blocked || fail "WordPress did not retain its local domain defederation rule"

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$GTS_CONTAINER" "WordPress"

cat <<EOF

WordPress federation smoke passed.

Covered against stock WordPress ActivityPub:
* supported: Unfathomably follows and unfollows the WordPress blog Group
* supported: the WordPress blog Group follows and unfollows Person and Group actors
* supported: WordPress posts, comments, Likes, Undo Likes, and Deletes reach Unfathomably
* supported: Unfathomably comments, Likes, Undo Likes, and Deletes reach WordPress
* supported: WordPress sends Block and Unfathomably records being blocked
* supported: both peers retain local actor block state
* supported: WordPress retains an explicit local domain defederation rule
* not_supported: the WordPress plugin does not retain an inbound ActivityPub Block as a remote moderation state
* not_supported: WordPress cannot report that a remote domain has defederated it
EOF

# end of build_scripts/unfathomably-wordpress-smoke.sh
