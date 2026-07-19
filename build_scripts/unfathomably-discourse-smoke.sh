#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-discourse-smoke.sh
#
# Purpose:
#
#   Start a clean Unfathomably smoke instance and a stock Discourse
#   development instance with the official ActivityPub plugin, then
#   prove category/group-style federation works between them.
#
# Responsibilities:
#
#   * boot Discourse from the stock discourse/discourse_dev image
#   * install the official discourse-activity-pub plugin in a throwaway
#     source checkout
#   * create ActivityPub category and user actors through Discourse's
#     own Rails/plugin interfaces
#   * exercise follow, unfollow, post, reply, like, unlike, and delete
#     paths across the Unfathomably/Discourse boundary
#   * fail loudly if either server logs obvious 500/crash output
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * persistent Discourse site management
#   * browser automation
#

set -euo pipefail

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
DISCOURSE_IMAGE="${DISCOURSE_IMAGE:-discourse/discourse_dev:release}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

PREFIX="${SMOKE_PREFIX:-unfathomably-discourse-smoke}"
NETWORK="${SMOKE_NETWORK:-$PREFIX-net}"
BE_PREFIX="$PREFIX-be"
DISCOURSE_SMOKE_NETWORK_SUBNET="${DISCOURSE_SMOKE_NETWORK_SUBNET:-45.67.89.0/24}"

A_HOST="${SMOKE_A_HOST:-smoke-a}"
B_HOST="${SMOKE_B_HOST:-smoke-b}"
A_PORT="${SMOKE_A_PORT:-4831}"
B_PORT="${SMOKE_B_PORT:-4832}"
DISCOURSE_HOST="${DISCOURSE_HOST:-discourse-smoke}"
DISCOURSE_APP_HOST="$PREFIX-discourse"
DISCOURSE_PORT="${DISCOURSE_PORT:-4833}"
DISCOURSE_DB="${DISCOURSE_DB:-discourse_smoke}"
DISCOURSE_REQUIRE_SIGNED="${DISCOURSE_REQUIRE_SIGNED:-1}"
DISCOURSE_ALLOWED_INTERNAL_HOSTS="${DISCOURSE_ALLOWED_INTERNAL_HOSTS:-$A_HOST|$B_HOST}"

PASSWORD="${SMOKE_USER_PASSWORD:-SmokeTest_01}"
KEEP_SMOKE="${KEEP_SMOKE:-0}"
POLL_ATTEMPTS="${SMOKE_POLL_ATTEMPTS:-100}"

WORK_DIR="${SMOKE_WORK_DIR:-}"
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-discourse-smoke.XXXXXX")"
fi

BASE_URL="http://127.0.0.1:$A_PORT"
DISCOURSE_URL="http://127.0.0.1:$DISCOURSE_PORT"
DISCOURSE_SOURCE_DIR="${DISCOURSE_SOURCE_DIR:-$WORK_DIR/discourse}"
DISCOURSE_CERT_DIR="$WORK_DIR/discourse-certs"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2

    for container in \
        "$PREFIX-discourse-proxy" \
        "$PREFIX-discourse" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db"; do
        if docker inspect "$container" >/dev/null 2>&1; then
            printf '\n--- docker logs --tail 160 %s ---\n' "$container" >&2
            docker logs --tail 160 "$container" >&2 || true
        fi
    done

    if docker inspect "$PREFIX-discourse" >/dev/null 2>&1; then
        printf '\n--- Discourse Rails logs ---\n' >&2
        docker exec "$PREFIX-discourse" bash -lc \
            'cat /tmp/discourse-web.log /tmp/discourse-sidekiq.log 2>/dev/null | tail -240' >&2 || true
    fi

    exit 1
}

remove_work_dir() {
    rm -rf "$WORK_DIR" 2>/dev/null && return 0

    docker run --rm \
        -v "$WORK_DIR:/work" \
        "$NGINX_IMAGE" \
        sh -c 'rm -rf /work/* /work/.[!.]* /work/..?*' >/dev/null 2>&1 || true
    rmdir "$WORK_DIR" 2>/dev/null || true
}

cleanup() {
    if [ "$KEEP_SMOKE" = "1" ]; then
        cat <<EOF

Smoke containers preserved because KEEP_SMOKE=1.
Unfathomably: $BASE_URL
Discourse:     $DISCOURSE_URL
Work dir:      $WORK_DIR
EOF
        return
    fi

    docker rm -f \
        "$PREFIX-discourse-proxy" \
        "$PREFIX-discourse" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    remove_work_dir
}

trap cleanup EXIT

urlencode() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

json_get() {
    local json="$1"
    local path="$2"

    JSON_PAYLOAD="$json" python3 - "$path" <<'PY'
import json
import os
import sys

path = sys.argv[1].split(".")
data = json.loads(os.environ["JSON_PAYLOAD"])

for part in path:
    if isinstance(data, list):
        data = data[int(part)]
    else:
        data = data[part]

if isinstance(data, (dict, list)):
    print(json.dumps(data))
elif data is None:
    print("")
else:
    print(data)
PY
}

json_assert() {
    local json="$1"
    local expr="$2"
    local message="$3"

    json_matches "$json" "$expr" || fail "$message"
}

json_matches() {
    local json="$1"
    local expr="$2"

    JSON_PAYLOAD="$json" python3 - "$expr" <<'PY'
import json
import os
import sys

expr = sys.argv[1]
data = json.loads(os.environ["JSON_PAYLOAD"])
helpers = {"any": any, "all": all, "len": len, "str": str, "int": int}

if not eval(expr, {"__builtins__": {}}, {"data": data, **helpers}):
    raise SystemExit(1)
PY
}

http_form() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    shift 4

    local tmp code
    tmp="$(mktemp)"

    local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")
    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi
    for field in "$@"; do
        args+=(--data-urlencode "$field")
    done
    args+=("$url")

    code="$(curl "${args[@]}")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for $method $url"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected HTTP $code for $method $url (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

http_get() {
    local url="$1"
    local expected="$2"

    local tmp code
    tmp="$(mktemp)"

    code="$(curl -sS -o "$tmp" -w "%{http_code}" "$url")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for GET $url"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected HTTP $code for GET $url (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

poll_http_status() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local message="$5"
    local attempts="${6:-$POLL_ATTEMPTS}"
    local delay="${7:-2}"
    local tmp code

    tmp="$(mktemp)"

    for _ in $(seq 1 "$attempts"); do
        local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")
        if [ -n "$token" ]; then
            args+=(-H "Authorization: Bearer $token")
        fi
        args+=("$url")

        code="$(curl "${args[@]}")" || code="000"

        if [ "$code" = "$expected" ]; then
            rm -f "$tmp"
            return 0
        fi

        sleep "$delay"
    done

    cat "$tmp" >&2 || true
    rm -f "$tmp"
    fail "Polling timed out: $message stayed at HTTP $code instead of $expected"
}

poll_json_assert() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local expr="$5"
    local message="$6"
    local attempts="${7:-$POLL_ATTEMPTS}"
    local delay="${8:-2}"
    local result

    for _ in $(seq 1 "$attempts"); do
        if [ "$method" = "GET" ]; then
            result="$(http_form GET "$url" "$token" "$expected" || true)"
        else
            result="$(http_form "$method" "$url" "$token" "$expected" || true)"
        fi

        if [ -n "$result" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep "$delay"
    done

    printf '%s\n' "$result" >&2
    fail "Polling timed out: $message"
}

wait_http() {
    local url="$1"
    local name="$2"

    for _ in $(seq 1 160); do
        if curl -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    fail "Timed out waiting for $name at $url"
}

be_token() {
    local username="$1"
    local app token client_id client_secret

    app="$(
        http_form POST "$BASE_URL/api/v1/apps" "" 200 \
            "client_name=discourse-smoke" \
            "redirect_uris=urn:ietf:wg:oauth:2.0:oob" \
            "scopes=read write follow push"
    )"
    client_id="$(json_get "$app" client_id)"
    client_secret="$(json_get "$app" client_secret)"

    token="$(
        http_form POST "$BASE_URL/oauth/token" "" 200 \
            "grant_type=password" \
            "username=$username" \
            "password=$PASSWORD" \
            "client_id=$client_id" \
            "client_secret=$client_secret" \
            "scope=read write follow push"
    )"

    json_get "$token" access_token
}

resolve_be_status_id() {
    local uri="$1"
    local token="$2"
    local message="$3"
    local result

    result="$(
        poll_json_assert GET \
            "$BASE_URL/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$uri")" \
            "$token" \
            200 \
            'len(data.get("statuses", [])) >= 1' \
            "$message" \
            "$POLL_ATTEMPTS" \
            2
    )"

    json_get "$result" statuses.0.id
}

resolve_be_context_status_id() {
    local parent_id="$1"
    local uri="$2"
    local token="$3"
    local message="$4"
    local result
    local id

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(
            http_form GET \
                "$BASE_URL/api/v1/statuses/$parent_id/context" \
                "$token" \
                200 || true
        )"

        id="$(
            JSON_PAYLOAD="$result" TARGET_URI="$uri" python3 - <<'PY' || true
import json
import os
import sys

try:
    data = json.loads(os.environ["JSON_PAYLOAD"])
except json.JSONDecodeError:
    raise SystemExit(1)

target = os.environ["TARGET_URI"]


def uri_variants(value):
    import urllib.parse

    if not value:
        return set()

    values = {value}
    parts = urllib.parse.urlsplit(value)

    if parts.scheme in ("http", "https"):
        values.add(urllib.parse.urlunsplit(("http", parts.netloc, parts.path, parts.query, parts.fragment)))
        values.add(urllib.parse.urlunsplit(("https", parts.netloc, parts.path, parts.query, parts.fragment)))

    return values


targets = uri_variants(target)

for status in data.get("ancestors", []) + data.get("descendants", []):
    if uri_variants(status.get("uri")) & targets or uri_variants(status.get("url")) & targets:
        print(status["id"])
        raise SystemExit(0)

raise SystemExit(1)
PY
        )"

        if [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

poll_be_object_unliked() {
    local object_ap_id="$1"
    local actor_ap_id="$2"
    local message="$3"
    local object_sql actor_sql result

    object_sql="$(sql_escape "$object_ap_id")"
    actor_sql="$(sql_escape "$actor_ap_id")"

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(
            docker exec "$BE_PREFIX-db" psql -U postgres -d pleroma_smoke_a -Atc "
                select case
                    when coalesce((data->>'like_count')::int, 0) = 0
                         and not (coalesce(data->'likes', '[]'::jsonb) ? '$actor_sql')
                    then 'ok'
                    else coalesce(data->>'like_count', 'null') || ' ' || coalesce((data->'likes')::text, 'null')
                end
                from objects
                where data->>'id' = '$object_sql';
            "
        )"

        if [ "$result" = "ok" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message: backend object still shows like state $result"
}

prepare_discourse_source() {
    if [ -d "$DISCOURSE_SOURCE_DIR/.git" ]; then
        return
    fi

    mkdir -p "$(dirname "$DISCOURSE_SOURCE_DIR")"

    log "Cloning stock Discourse and official ActivityPub plugin"
    git clone --depth 1 https://github.com/discourse/discourse.git "$DISCOURSE_SOURCE_DIR" >/dev/null 2>&1
    git clone --depth 1 \
        https://github.com/discourse/discourse-activity-pub.git \
        "$DISCOURSE_SOURCE_DIR/plugins/discourse-activity-pub" >/dev/null 2>&1
}

write_discourse_proxy_config() {
    mkdir -p "$DISCOURSE_CERT_DIR"

    cat >"$DISCOURSE_CERT_DIR/openssl.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = $DISCOURSE_HOST

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DISCOURSE_HOST
EOF

    if [ ! -f "$DISCOURSE_CERT_DIR/ca.crt" ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
            -subj "/CN=$PREFIX-discourse-ca" \
            -keyout "$DISCOURSE_CERT_DIR/ca.key" \
            -out "$DISCOURSE_CERT_DIR/ca.crt" >/dev/null 2>&1

        openssl req -new -newkey rsa:2048 -nodes \
            -keyout "$DISCOURSE_CERT_DIR/discourse.key" \
            -out "$DISCOURSE_CERT_DIR/discourse.csr" \
            -config "$DISCOURSE_CERT_DIR/openssl.cnf" >/dev/null 2>&1

        openssl x509 -req \
            -in "$DISCOURSE_CERT_DIR/discourse.csr" \
            -CA "$DISCOURSE_CERT_DIR/ca.crt" \
            -CAkey "$DISCOURSE_CERT_DIR/ca.key" \
            -CAcreateserial \
            -days 2 \
            -out "$DISCOURSE_CERT_DIR/discourse.crt" \
            -extensions req_ext \
            -extfile "$DISCOURSE_CERT_DIR/openssl.cnf" >/dev/null 2>&1
    fi

    cat "$DISCOURSE_CERT_DIR/ca.crt" /etc/ssl/certs/ca-certificates.crt \
        >"$DISCOURSE_CERT_DIR/be-ca-bundle.pem"

    cat >"$WORK_DIR/discourse-nginx.conf" <<EOF
events {}
http {
  server {
    listen 80;
    client_max_body_size 100m;

    location / {
      proxy_pass http://$DISCOURSE_APP_HOST:3000;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto http;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }

  server {
    listen 443 ssl;
    client_max_body_size 100m;

    ssl_certificate /etc/nginx/smoke-certs/discourse.crt;
    ssl_certificate_key /etc/nginx/smoke-certs/discourse.key;

    location / {
      proxy_pass http://$DISCOURSE_APP_HOST:3000;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }
}
EOF
}

trust_discourse_ca_in_be() {
    for container in "$BE_PREFIX-a" "$BE_PREFIX-b"; do
        docker cp "$DISCOURSE_CERT_DIR/ca.crt" \
            "$container:/usr/local/share/ca-certificates/unfathomably-discourse-smoke-ca.crt"
        docker exec "$container" sh -lc 'update-ca-certificates >/dev/null 2>&1 || true'
    done
}

start_discourse() {
    prepare_discourse_source
    write_discourse_proxy_config

    docker rm -f "$PREFIX-discourse-proxy" "$PREFIX-discourse" >/dev/null 2>&1 || true

    docker run -d \
        --name "$PREFIX-discourse" \
        --network "$NETWORK" \
        --network-alias "$DISCOURSE_APP_HOST" \
        -e RAILS_ENV=development \
        -e LOAD_PLUGINS=1 \
        -e RAILS_DEVELOPMENT_HOSTS="$DISCOURSE_HOST" \
        -e DISCOURSE_HOSTNAME="$DISCOURSE_HOST" \
        -e DISCOURSE_DEV_DB="$DISCOURSE_DB" \
        -e DISCOURSE_ACTIVITY_PUB_DELIVERY_DELAY=0 \
        -v "$DISCOURSE_SOURCE_DIR:/src" \
        "$DISCOURSE_IMAGE" \
        bash -lc '
            if [ ! -d /shared/postgres_data ]; then
                cp -a /shared/postgres_data_orig /shared/postgres_data
            fi
            chown -R postgres:postgres /shared/postgres_data
            runsvdir /etc/service &
            sleep infinity
        ' >/dev/null

    log "Waiting for Discourse services"
    for _ in $(seq 1 120); do
        if docker exec "$PREFIX-discourse" pg_isready -U postgres >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    docker exec "$PREFIX-discourse" pg_isready -U postgres >/dev/null 2>&1 ||
        fail "Timed out waiting for Discourse PostgreSQL"

    docker exec "$PREFIX-discourse" bash -lc 'sudo -u postgres createuser root -s 2>/dev/null || true'
    docker exec "$PREFIX-discourse" bash -lc 'git config --global --add safe.directory /src'

    log "Installing Discourse frontend dependencies"
    docker exec "$PREFIX-discourse" bash -lc \
        'cd /src && pnpm install --frozen-lockfile >/tmp/discourse-pnpm.log 2>&1' || {
            docker exec "$PREFIX-discourse" cat /tmp/discourse-pnpm.log >&2 || true
            fail "Discourse pnpm install failed"
        }

    log "Installing Discourse Ruby dependencies"
    docker exec "$PREFIX-discourse" bash -lc \
        'cd /src && bundle install >/tmp/discourse-bundle.log 2>&1' || {
            docker exec "$PREFIX-discourse" cat /tmp/discourse-bundle.log >&2 || true
            fail "Discourse bundle install failed"
        }

    log "Migrating Discourse"
    docker exec "$PREFIX-discourse" bash -lc \
        'cd /src && bundle exec rake db:create db:migrate >/tmp/discourse-migrate.log 2>&1' || {
            docker exec "$PREFIX-discourse" cat /tmp/discourse-migrate.log >&2 || true
            fail "Discourse migration failed"
        }

    docker exec -d "$PREFIX-discourse" bash -lc \
        'cd /src && bundle exec rails server -b 0.0.0.0 -p 3000 >/tmp/discourse-web.log 2>&1'
    docker exec -d "$PREFIX-discourse" bash -lc \
        'cd /src && bundle exec sidekiq >/tmp/discourse-sidekiq.log 2>&1'

    docker run -d \
        --name "$PREFIX-discourse-proxy" \
        --network "$NETWORK" \
        --network-alias "$DISCOURSE_HOST" \
        -p "127.0.0.1:$DISCOURSE_PORT:80" \
        -v "$WORK_DIR/discourse-nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$DISCOURSE_CERT_DIR:/etc/nginx/smoke-certs:ro" \
        "$NGINX_IMAGE" >/dev/null

    wait_http "$DISCOURSE_URL/srv/status" "Discourse"
    trust_discourse_ca_in_be
}

rails_json() {
    local output

    output="$(docker exec -i "$PREFIX-discourse" bash -lc 'cd /src && bundle exec rails runner -' | tail -n 1)"
    printf '%s\n' "$output"
}

setup_discourse_site() {
    docker exec -i \
        -e SMOKE_PASSWORD="$PASSWORD" \
        -e DISCOURSE_HOST="$DISCOURSE_HOST" \
        -e DISCOURSE_REQUIRE_SIGNED="$DISCOURSE_REQUIRE_SIGNED" \
        -e DISCOURSE_ALLOWED_INTERNAL_HOSTS="$DISCOURSE_ALLOWED_INTERNAL_HOSTS" \
        "$PREFIX-discourse" \
        bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1
require "json"

def force_http_activity_pub_urls!(record)
  host = ENV.fetch("DISCOURSE_HOST")

  record.attributes.each do |attribute, value|
    next unless value.is_a?(String)
    next unless value.start_with?("https://#{host}")
    next unless record.respond_to?("#{attribute}=")

    record.public_send("#{attribute}=", value.sub(/\Ahttps:/, "http:"))
  end

  record.save!(validate: false) if record.changed?
  record.reload
end

def force_http_activity_pub_actor_urls!
  host = ENV.fetch("DISCOURSE_HOST")
  actor_class = defined?(DiscourseActivityPubActor) ? DiscourseActivityPubActor : nil
  return unless actor_class&.respond_to?(:where)

  actor_class
    .where("ap_id LIKE ?", "https://#{host}%")
    .find_each { |actor| force_http_activity_pub_urls!(actor) }
end

SiteSetting.title = "Discourse Smoke"
SiteSetting.login_required = false
SiteSetting.force_https = false
SiteSetting.activity_pub_enabled = true
SiteSetting.activity_pub_require_signed_requests = ENV["DISCOURSE_REQUIRE_SIGNED"] == "1"
SiteSetting.allowed_internal_hosts = ENV.fetch("DISCOURSE_ALLOWED_INTERNAL_HOSTS")

user =
  User.find_by(username: "discourseauthor") ||
  User.create!(
    username: "discourseauthor",
    email: "discourseauthor@example.com",
    password: ENV.fetch("SMOKE_PASSWORD"),
    active: true,
    approved: true,
    trust_level: TrustLevel[2]
  )

user.activate unless user.active?
user.update!(approved: true, trust_level: TrustLevel[2]) if user.respond_to?(:approved)

category =
  Category.find_by(slug: "discourse-smoke") ||
  Category.create!(
    name: "Discourse Smoke",
    slug: "discourse-smoke",
    user_id: Discourse.system_user.id,
    color: "0088CC",
    text_color: "FFFFFF"
  )

category.set_permissions(everyone: :full)
category.save!

category_actor =
  DiscourseActivityPub::ActorHandler
    .new(model: category)
    .update_or_create_actor(
      username: "discoursecategory",
      name: "Discourse Smoke",
      default_visibility: "public",
      publication_type: "full_topic",
      post_object_type: "Note",
      enabled: true
    )

user_actor =
  DiscourseActivityPub::ActorHandler
    .new(model: user)
    .update_or_create_actor(
      username: "discourseauthor",
      name: "Discourse Smoke User",
      default_visibility: "public",
      enabled: true
    )

category_actor = force_http_activity_pub_urls!(category_actor)
user_actor = force_http_activity_pub_urls!(user_actor)
force_http_activity_pub_actor_urls!

puts JSON.generate(
  user_id: user.id,
  user_actor_id: user_actor.id,
  user_actor_ap_id: user_actor.ap_id,
  category_id: category.id,
  category_actor_id: category_actor.id,
  category_actor_ap_id: category_actor.ap_id,
  category_actor_handle: category_actor.handle
)
RUBY
}

discourse_follow_remote_actor() {
    local local_actor_id="$1"
    local remote_ref="$2"
    local label="$3"

    docker exec -i \
        -e LOCAL_ACTOR_ID="$local_actor_id" \
        -e REMOTE_REF="$remote_ref" \
        -e FOLLOW_LABEL="$label" \
        "$PREFIX-discourse" \
        bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1
require "json"

local_actor = DiscourseActivityPubActor.find(ENV.fetch("LOCAL_ACTOR_ID"))
remote_ref = ENV.fetch("REMOTE_REF")
remote_actor =
  if remote_ref.include?("@")
    DiscourseActivityPubActor.find_by_handle(remote_ref, refresh: true)
  else
    DiscourseActivityPubActor.find_by_ap_id(remote_ref, refresh: true)
  end

raise "Could not resolve #{ENV.fetch("FOLLOW_LABEL")}: #{remote_ref}" unless remote_actor
raise "#{local_actor.handle} cannot follow #{remote_actor.ap_type}" unless local_actor.can_follow?(remote_actor)

DiscourseActivityPub::FollowHandler.follow(local_actor.id, remote_actor.id) unless local_actor.following?(remote_actor)

puts JSON.generate(
  remote_actor_id: remote_actor.id,
  remote_actor_ap_id: remote_actor.ap_id,
  remote_actor_handle: remote_actor.handle,
  following: local_actor.reload.following?(remote_actor)
)
RUBY
}

discourse_following_state() {
    local local_actor_id="$1"
    local remote_actor_id="$2"

    docker exec -i \
        -e LOCAL_ACTOR_ID="$local_actor_id" \
        -e REMOTE_ACTOR_ID="$remote_actor_id" \
        "$PREFIX-discourse" \
        bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1
require "json"

local_actor = DiscourseActivityPubActor.find(ENV.fetch("LOCAL_ACTOR_ID"))
remote_actor = DiscourseActivityPubActor.find(ENV.fetch("REMOTE_ACTOR_ID"))

puts JSON.generate(following: local_actor.reload.following?(remote_actor))
RUBY
}

poll_discourse_following() {
    local local_actor_id="$1"
    local remote_actor_id="$2"
    local expected="$3"
    local message="$4"
    local expr result

    if [ "$expected" = "true" ]; then
        expr='data.get("following") is True'
    else
        expr='data.get("following") is False'
    fi

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(discourse_following_state "$local_actor_id" "$remote_actor_id" || true)"

        if [ -n "$result" ] && json_matches "$result" "$expr"; then
            echo "$result"
            return 0
        fi

        sleep 2
    done

    echo "$result" >&2
    fail "$message"
}

discourse_unfollow_remote_actor() {
    local local_actor_id="$1"
    local remote_actor_id="$2"

    docker exec -i \
        -e LOCAL_ACTOR_ID="$local_actor_id" \
        -e REMOTE_ACTOR_ID="$remote_actor_id" \
        "$PREFIX-discourse" \
        bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1
require "json"

local_actor = DiscourseActivityPubActor.find(ENV.fetch("LOCAL_ACTOR_ID"))
remote_actor = DiscourseActivityPubActor.find(ENV.fetch("REMOTE_ACTOR_ID"))

DiscourseActivityPub::FollowHandler.unfollow(local_actor.id, remote_actor.id) if local_actor.following?(remote_actor)

puts JSON.generate(following: local_actor.reload.following?(remote_actor))
RUBY
}

discourse_create_topic() {
    local title="$1"
    local raw="$2"

    docker exec -i \
        -e DISCOURSE_USER_ID="$DISCOURSE_USER_ID" \
        -e DISCOURSE_CATEGORY_ID="$DISCOURSE_CATEGORY_ID" \
        -e DISCOURSE_HOST="$DISCOURSE_HOST" \
        -e TOPIC_TITLE="$title" \
        -e TOPIC_RAW="$raw" \
        "$PREFIX-discourse" \
        bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1
require "json"

def force_http_activity_pub_urls!(record)
  host = ENV.fetch("DISCOURSE_HOST")

  record.attributes.each do |attribute, value|
    next unless value.is_a?(String)
    next unless value.start_with?("https://#{host}")
    next unless record.respond_to?("#{attribute}=")

    record.public_send("#{attribute}=", value.sub(/\Ahttps:/, "http:"))
  end

  record.save!(validate: false) if record.changed?
  record.reload
end

def force_http_activity_pub_actor_urls!
  host = ENV.fetch("DISCOURSE_HOST")
  actor_class = defined?(DiscourseActivityPubActor) ? DiscourseActivityPubActor : nil
  return unless actor_class&.respond_to?(:where)

  actor_class
    .where("ap_id LIKE ?", "https://#{host}%")
    .find_each { |actor| force_http_activity_pub_urls!(actor) }
end

user = User.find(ENV.fetch("DISCOURSE_USER_ID"))
post =
  PostCreator.create!(
    user,
    title: ENV.fetch("TOPIC_TITLE"),
    raw: ENV.fetch("TOPIC_RAW"),
    category: ENV.fetch("DISCOURSE_CATEGORY_ID").to_i
  )

post.activity_pub_publish! unless post.activity_pub_object
force_http_activity_pub_urls!(post.activity_pub_object)
force_http_activity_pub_urls!(post.activity_pub_activity) if post.respond_to?(:activity_pub_activity) && post.activity_pub_activity
force_http_activity_pub_actor_urls!
post.activity_pub_deliver!

puts JSON.generate(
  post_id: post.id,
  topic_id: post.topic_id,
  post_number: post.post_number,
  object_ap_id: post.activity_pub_object.ap_id
)
RUBY
}

discourse_create_reply() {
    local topic_id="$1"
    local reply_to_post_number="$2"
    local raw="$3"

    docker exec -i \
        -e DISCOURSE_USER_ID="$DISCOURSE_USER_ID" \
        -e DISCOURSE_HOST="$DISCOURSE_HOST" \
        -e TOPIC_ID="$topic_id" \
        -e REPLY_TO_POST_NUMBER="$reply_to_post_number" \
        -e REPLY_RAW="$raw" \
        "$PREFIX-discourse" \
        bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1
require "json"

def force_http_activity_pub_urls!(record)
  host = ENV.fetch("DISCOURSE_HOST")

  record.attributes.each do |attribute, value|
    next unless value.is_a?(String)
    next unless value.start_with?("https://#{host}")
    next unless record.respond_to?("#{attribute}=")

    record.public_send("#{attribute}=", value.sub(/\Ahttps:/, "http:"))
  end

  record.save!(validate: false) if record.changed?
  record.reload
end

def force_http_activity_pub_actor_urls!
  host = ENV.fetch("DISCOURSE_HOST")
  actor_class = defined?(DiscourseActivityPubActor) ? DiscourseActivityPubActor : nil
  return unless actor_class&.respond_to?(:where)

  actor_class
    .where("ap_id LIKE ?", "https://#{host}%")
    .find_each { |actor| force_http_activity_pub_urls!(actor) }
end

user = User.find(ENV.fetch("DISCOURSE_USER_ID"))
post =
  PostCreator.create!(
    user,
    topic_id: ENV.fetch("TOPIC_ID").to_i,
    raw: ENV.fetch("REPLY_RAW"),
    reply_to_post_number: ENV.fetch("REPLY_TO_POST_NUMBER").to_i
  )

post.activity_pub_publish! unless post.activity_pub_object
force_http_activity_pub_urls!(post.activity_pub_object)
force_http_activity_pub_urls!(post.activity_pub_activity) if post.respond_to?(:activity_pub_activity) && post.activity_pub_activity
force_http_activity_pub_actor_urls!
post.activity_pub_deliver!

puts JSON.generate(
  post_id: post.id,
  topic_id: post.topic_id,
  post_number: post.post_number,
  object_ap_id: post.activity_pub_object.ap_id
)
RUBY
}

discourse_delete_post() {
    local post_id="$1"

    docker exec -i \
        -e DISCOURSE_USER_ID="$DISCOURSE_USER_ID" \
        -e POST_ID="$post_id" \
        "$PREFIX-discourse" \
        bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1
require "json"

user = User.find(ENV.fetch("DISCOURSE_USER_ID"))
post = Post.with_deleted.find(ENV.fetch("POST_ID"))

PostDestroyer.new(user, post, context: "ActivityPub smoke delete").destroy unless post.trashed?

post = Post.with_deleted.find(post.id)
actor = post.respond_to?(:activity_pub_actor) ? post.activity_pub_actor : nil
delete_activity =
  actor
    &.activities
    &.unscoped
    &.where(ap_type: "Delete")
    &.order(:created_at)
    &.last

delete_json =
  begin
    delete_activity ? delete_activity.ap.json : {}
  rescue StandardError
    {}
  end

delete_object = delete_json.is_a?(Hash) ? delete_json["object"] : nil
delete_object_present = !(delete_object.nil? || delete_object == "")

puts JSON.generate(
  deleted: post.trashed? || post.deleted_at.present? || post.raw == "(post deleted by author)",
  delete_activity_ap_id: delete_activity&.ap_id,
  delete_activity_publishable: delete_activity ? delete_activity.publish? : false,
  delete_activity_ready: delete_activity ? !!delete_activity.ready? : false,
  delete_object_present: delete_object_present
)
RUBY
}

discourse_delete_is_deliverable() {
    local result="$1"

    json_matches \
        "$result" \
        'data.get("delete_object_present") is True and data.get("delete_activity_publishable") is True' \
        >/dev/null 2>&1
}

log_discourse_delete_not_supported() {
    local subject="$1"
    local result="$2"

    log "Stock Discourse generated a non-deliverable ActivityPub Delete for $subject; marking that delete direction not_supported"
    printf '%s\n' "$result" >&2
}

discourse_like_post() {
    local post_id="$1"

    docker exec -i \
        -e DISCOURSE_USER_ID="$DISCOURSE_USER_ID" \
        -e POST_ID="$post_id" \
        "$PREFIX-discourse" \
        bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1
require "json"

user = User.find(ENV.fetch("DISCOURSE_USER_ID"))
post = Post.find(ENV.fetch("POST_ID"))
result = PostActionCreator.like(user, post)

puts JSON.generate(success: result.success?, like_count: post.reload.like_count)
RUBY
}

discourse_unlike_post() {
    local post_id="$1"

    docker exec -i \
        -e DISCOURSE_USER_ID="$DISCOURSE_USER_ID" \
        -e POST_ID="$post_id" \
        "$PREFIX-discourse" \
        bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1
require "json"

user = User.find(ENV.fetch("DISCOURSE_USER_ID"))
post = Post.find(ENV.fetch("POST_ID"))
result = PostActionDestroyer.destroy(user, post, :like)

puts JSON.generate(success: result.success?, like_count: post.reload.like_count)
RUBY
}

poll_discourse_post_text() {
    local text="$1"
    local message="$2"
    local result

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(
            docker exec -i \
                -e RAW_TEXT="$text" \
                "$PREFIX-discourse" \
                bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1 || true
require "json"

pattern = "%#{ActiveRecord::Base.sanitize_sql_like(ENV.fetch("RAW_TEXT"))}%"
post =
  Post
    .with_deleted
    .where("raw LIKE ?", pattern)
    .order(:created_at)
    .last

if post
  object = post.activity_pub_object
  puts JSON.generate(
    found: true,
    post_id: post.id,
    topic_id: post.topic_id,
    post_number: post.post_number,
    deleted: post.trashed?,
    object_ap_id: object&.ap_id
  )
else
  puts JSON.generate(found: false)
end
RUBY
        )"

        if [ -n "$result" ] && json_matches "$result" 'data.get("found") is True' >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_discourse_post_deleted() {
    local post_id="$1"
    local message="$2"
    local result

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(
            docker exec -i \
                -e POST_ID="$post_id" \
                "$PREFIX-discourse" \
                bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1 || true
require "json"

post = Post.with_deleted.find_by(id: ENV.fetch("POST_ID"))
puts JSON.generate(found: !!post, deleted: post ? post.trashed? : true)
RUBY
        )"

        if [ -n "$result" ] && json_matches "$result" 'data.get("deleted") is True' >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_discourse_like_count() {
    local post_id="$1"
    local expr="$2"
    local message="$3"
    local result

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(
            docker exec -i \
                -e POST_ID="$post_id" \
                "$PREFIX-discourse" \
                bash -lc 'cd /src && bundle exec rails runner -' <<'RUBY' | tail -n 1 || true
require "json"

post = Post.with_deleted.find(ENV.fetch("POST_ID"))
puts JSON.generate(like_count: post.like_count)
RUBY
        )"

        if [ -n "$result" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

docker rm -f "$PREFIX-discourse-proxy" "$PREFIX-discourse" >/dev/null 2>&1 || true
write_discourse_proxy_config

log "Bootstrapping Unfathomably smoke pair"
KEEP_SMOKE=1 \
SMOKE_PREFIX="$BE_PREFIX" \
SMOKE_NETWORK="$NETWORK" \
SMOKE_NETWORK_SUBNET="$DISCOURSE_SMOKE_NETWORK_SUBNET" \
SMOKE_A_HOST="$A_HOST" \
SMOKE_B_HOST="$B_HOST" \
SMOKE_A_PORT="$A_PORT" \
SMOKE_B_PORT="$B_PORT" \
SMOKE_IMAGE="$IMAGE" \
SMOKE_USER_PASSWORD="$PASSWORD" \
SMOKE_EXTRA_CA_CERT="$DISCOURSE_CERT_DIR/be-ca-bundle.pem" \
bash build_scripts/two-instance-federation-smoke.sh >/tmp/unfathomably-discourse-bootstrap.log 2>&1 || {
    cat /tmp/unfathomably-discourse-bootstrap.log >&2 || true
    fail "Unfathomably bootstrap smoke failed"
}

log "Starting Discourse"
start_discourse

log "Creating API credentials and ActivityPub actors"
ALICE_TOKEN="$(be_token alice)"

DISCOURSE_SETUP="$(setup_discourse_site)"
DISCOURSE_USER_ID="$(json_get "$DISCOURSE_SETUP" user_id)"
DISCOURSE_USER_ACTOR_AP_ID="$(json_get "$DISCOURSE_SETUP" user_actor_ap_id)"
DISCOURSE_CATEGORY_ID="$(json_get "$DISCOURSE_SETUP" category_id)"
DISCOURSE_CATEGORY_ACTOR_ID="$(json_get "$DISCOURSE_SETUP" category_actor_id)"
DISCOURSE_CATEGORY_ACTOR_AP_ID="$(json_get "$DISCOURSE_SETUP" category_actor_ap_id)"

BE_GROUP_NAME="unfathomably_discourse_smoke"
BE_GROUP="$(
    http_form POST "$BASE_URL/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably Discourse Smoke" \
        "name=$BE_GROUP_NAME"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_AP_ID="$(json_get "$BE_GROUP" ap_id)"
BE_GROUP_HANDLE="$BE_GROUP_NAME@$A_HOST"
ALICE_HANDLE="alice@$A_HOST"
ALICE_AP_ID="http://$A_HOST:4000/users/alice"

log "Following groups in both directions"
BE_REMOTE_DISCOURSE_GROUP="$(
    http_form GET "$BASE_URL/api/v1/groups/lookup?uri=$(urlencode "$DISCOURSE_CATEGORY_ACTOR_AP_ID")" \
        "$ALICE_TOKEN" \
        200
)"
BE_REMOTE_DISCOURSE_GROUP_ID="$(json_get "$BE_REMOTE_DISCOURSE_GROUP" id)"
BE_JOIN_DISCOURSE="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_DISCOURSE_GROUP_ID/join" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_JOIN_DISCOURSE" 'data.get("member") is True or data.get("requested") is True' \
    "Unfathomably could not follow the Discourse category actor"

DISCOURSE_FOLLOW_BE_GROUP="$(discourse_follow_remote_actor "$DISCOURSE_CATEGORY_ACTOR_ID" "$BE_GROUP_AP_ID" "Unfathomably group")"
DISCOURSE_REMOTE_BE_GROUP_ID="$(json_get "$DISCOURSE_FOLLOW_BE_GROUP" remote_actor_id)"
poll_discourse_following \
    "$DISCOURSE_CATEGORY_ACTOR_ID" \
    "$DISCOURSE_REMOTE_BE_GROUP_ID" \
    true \
    "Discourse category actor could not follow the Unfathomably group" >/dev/null

DISCOURSE_FOLLOW_ALICE="$(discourse_follow_remote_actor "$DISCOURSE_CATEGORY_ACTOR_ID" "$ALICE_AP_ID" "Unfathomably posting user")"
DISCOURSE_REMOTE_ALICE_ID="$(json_get "$DISCOURSE_FOLLOW_ALICE" remote_actor_id)"
poll_discourse_following \
    "$DISCOURSE_CATEGORY_ACTOR_ID" \
    "$DISCOURSE_REMOTE_ALICE_ID" \
    true \
    "Discourse category actor could not follow the Unfathomably posting user" >/dev/null

log "Testing Discourse post delivery into Unfathomably"
DISCOURSE_TO_BE_TITLE="Discourse to Unfathomably smoke $(basename "$WORK_DIR")"
DISCOURSE_TO_BE_BODY="Discourse top-level body $(basename "$WORK_DIR")"
DISCOURSE_POST="$(discourse_create_topic "$DISCOURSE_TO_BE_TITLE" "$DISCOURSE_TO_BE_BODY")"
DISCOURSE_POST_ID="$(json_get "$DISCOURSE_POST" post_id)"
DISCOURSE_POST_AP_ID="$(json_get "$DISCOURSE_POST" object_ap_id)"
BE_VIEW_OF_DISCOURSE_POST_ID="$(resolve_be_status_id "$DISCOURSE_POST_AP_ID" "$ALICE_TOKEN" "Unfathomably resolves Discourse category post")"

BE_LIKE_DISCOURSE="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_DISCOURSE_POST_ID/favourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LIKE_DISCOURSE" 'data.get("favourited") is True' "Unfathomably could not like Discourse post"
poll_discourse_like_count \
    "$DISCOURSE_POST_ID" \
    'int(data.get("like_count") or 0) >= 1' \
    "Discourse sees Unfathomably like on Discourse post" >/dev/null

BE_UNLIKE_DISCOURSE="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_DISCOURSE_POST_ID/unfavourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_UNLIKE_DISCOURSE" 'data.get("favourited") is False' "Unfathomably could not unlike Discourse post"
poll_discourse_like_count \
    "$DISCOURSE_POST_ID" \
    'int(data.get("like_count") or 0) == 0' \
    "Discourse sees Unfathomably unlike on Discourse post" >/dev/null

BE_REPLY_TEXT="Unfathomably reply to Discourse $(basename "$WORK_DIR")"
BE_REPLY="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_REPLY_TEXT" \
        "in_reply_to_id=$BE_VIEW_OF_DISCOURSE_POST_ID"
)"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
DISCOURSE_VIEW_OF_BE_REPLY="$(poll_discourse_post_text "$BE_REPLY_TEXT" "Discourse receives Unfathomably reply under Discourse post")"
DISCOURSE_VIEW_OF_BE_REPLY_ID="$(json_get "$DISCOURSE_VIEW_OF_BE_REPLY" post_id)"

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_discourse_post_deleted \
    "$DISCOURSE_VIEW_OF_BE_REPLY_ID" \
    "Discourse sees Unfathomably deleted reply"

log "Testing Unfathomably post delivery into Discourse"
BE_TO_DISCOURSE_TEXT="Unfathomably to Discourse post $(basename "$WORK_DIR")"
BE_TO_DISCOURSE_POST="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_TO_DISCOURSE_TEXT" \
        "group_id=$BE_REMOTE_DISCOURSE_GROUP_ID"
)"
BE_TO_DISCOURSE_POST_ID="$(json_get "$BE_TO_DISCOURSE_POST" id)"
BE_TO_DISCOURSE_POST_AP_ID="$(json_get "$BE_TO_DISCOURSE_POST" uri)"
DISCOURSE_VIEW_OF_BE_POST="$(poll_discourse_post_text "$BE_TO_DISCOURSE_TEXT" "Discourse receives Unfathomably top-level group post")"
DISCOURSE_VIEW_OF_BE_POST_ID="$(json_get "$DISCOURSE_VIEW_OF_BE_POST" post_id)"
DISCOURSE_VIEW_OF_BE_POST_TOPIC_ID="$(json_get "$DISCOURSE_VIEW_OF_BE_POST" topic_id)"
DISCOURSE_VIEW_OF_BE_POST_NUMBER="$(json_get "$DISCOURSE_VIEW_OF_BE_POST" post_number)"

DISCOURSE_REPLY_TEXT="Discourse reply to Unfathomably $(basename "$WORK_DIR")"
DISCOURSE_REPLY="$(
    discourse_create_reply \
        "$DISCOURSE_VIEW_OF_BE_POST_TOPIC_ID" \
        "$DISCOURSE_VIEW_OF_BE_POST_NUMBER" \
        "$DISCOURSE_REPLY_TEXT"
)"
DISCOURSE_REPLY_ID="$(json_get "$DISCOURSE_REPLY" post_id)"
DISCOURSE_REPLY_AP_ID="$(json_get "$DISCOURSE_REPLY" object_ap_id)"
BE_VIEW_OF_DISCOURSE_REPLY_ID="$(
    resolve_be_context_status_id \
        "$BE_TO_DISCOURSE_POST_ID" \
        "$DISCOURSE_REPLY_AP_ID" \
        "$ALICE_TOKEN" \
        "Unfathomably receives Discourse reply under Unfathomably post"
)"
poll_json_assert GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_DISCOURSE_POST_ID/context" \
    "$ALICE_TOKEN" \
    200 \
    "'$DISCOURSE_REPLY_TEXT' in str(data)" \
    "Unfathomably sees Discourse reply under Unfathomably post" >/dev/null

DISCOURSE_DELETE_REPLY="$(discourse_delete_post "$DISCOURSE_REPLY_ID")"
if discourse_delete_is_deliverable "$DISCOURSE_DELETE_REPLY"; then
    poll_http_status GET \
        "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_DISCOURSE_REPLY_ID" \
        "$ALICE_TOKEN" \
        404 \
        "Unfathomably sees Discourse deleted reply"
    DISCOURSE_REPLY_DELETE_SUMMARY="* supported: Discourse-origin reply Delete propagation"
else
    log_discourse_delete_not_supported "the Discourse reply" "$DISCOURSE_DELETE_REPLY"
    DISCOURSE_REPLY_DELETE_SUMMARY="* not_supported: stock Discourse generated a non-deliverable Delete for its reply"
fi

DISCOURSE_LIKE_BE="$(discourse_like_post "$DISCOURSE_VIEW_OF_BE_POST_ID")"
json_assert "$DISCOURSE_LIKE_BE" 'data.get("success") is True and int(data.get("like_count") or 0) >= 1' \
    "Discourse could not like Unfathomably post"
poll_json_assert GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_DISCOURSE_POST_ID" \
    "$ALICE_TOKEN" \
    200 \
    'int(data.get("favourites_count") or 0) >= 1' \
    "Unfathomably sees Discourse like on Unfathomably post" >/dev/null

DISCOURSE_UNLIKE_BE="$(discourse_unlike_post "$DISCOURSE_VIEW_OF_BE_POST_ID")"
json_assert "$DISCOURSE_UNLIKE_BE" 'data.get("success") is True and int(data.get("like_count") or 0) == 0' \
    "Discourse could not unlike Unfathomably post"
poll_be_object_unliked \
    "$BE_TO_DISCOURSE_POST_AP_ID" \
    "$DISCOURSE_USER_ACTOR_AP_ID" \
    "Unfathomably sees Discourse unlike on Unfathomably post"

log "Deleting posts and unfollowing groups"
DISCOURSE_DELETE_POST="$(discourse_delete_post "$DISCOURSE_POST_ID")"
if discourse_delete_is_deliverable "$DISCOURSE_DELETE_POST"; then
    poll_http_status GET \
        "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_DISCOURSE_POST_ID" \
        "$ALICE_TOKEN" \
        404 \
        "Unfathomably sees deleted Discourse post"
    DISCOURSE_POST_DELETE_SUMMARY="* supported: Discourse-origin top-level post Delete propagation"
else
    log_discourse_delete_not_supported "the Discourse top-level post" "$DISCOURSE_DELETE_POST"
    DISCOURSE_POST_DELETE_SUMMARY="* not_supported: stock Discourse generated a non-deliverable Delete for its top-level post"
fi

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_TO_DISCOURSE_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_discourse_post_deleted \
    "$DISCOURSE_VIEW_OF_BE_POST_ID" \
    "Discourse sees deleted Unfathomably post"

BE_LEAVE_DISCOURSE="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_DISCOURSE_GROUP_ID/leave" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LEAVE_DISCOURSE" 'data.get("member") is False and data.get("requested") is False' \
    "Unfathomably could not unfollow Discourse category actor"

DISCOURSE_UNFOLLOW_BE_GROUP="$(discourse_unfollow_remote_actor "$DISCOURSE_CATEGORY_ACTOR_ID" "$DISCOURSE_REMOTE_BE_GROUP_ID")"
poll_discourse_following \
    "$DISCOURSE_CATEGORY_ACTOR_ID" \
    "$DISCOURSE_REMOTE_BE_GROUP_ID" \
    false \
    "Discourse category actor could not unfollow Unfathomably group" >/dev/null
DISCOURSE_UNFOLLOW_ALICE="$(discourse_unfollow_remote_actor "$DISCOURSE_CATEGORY_ACTOR_ID" "$DISCOURSE_REMOTE_ALICE_ID")"
poll_discourse_following \
    "$DISCOURSE_CATEGORY_ACTOR_ID" \
    "$DISCOURSE_REMOTE_ALICE_ID" \
    false \
    "Discourse category actor could not unfollow Unfathomably posting user" >/dev/null

log "Checking logs for obvious crashes"
for container in "$PREFIX-discourse-proxy" "$BE_PREFIX-a"; do
    if docker logs "$container" 2>&1 |
        grep -E "status=500|Internal Server Error|panicked at|thread '.*' panicked|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError" >/dev/null; then
        docker logs --tail 240 "$container" >&2
        fail "$container logged errors during Discourse smoke run"
    fi
done

if docker exec "$PREFIX-discourse" bash -lc \
    'cat /tmp/discourse-web.log /tmp/discourse-sidekiq.log 2>/dev/null' |
    grep -E "500 Internal Server Error|NoMethodError|NameError|ActiveRecord::StatementInvalid|Sidekiq::JobRetry|ERROR --|FATAL --" >/dev/null; then
    docker exec "$PREFIX-discourse" bash -lc \
        'cat /tmp/discourse-web.log /tmp/discourse-sidekiq.log 2>/dev/null | tail -240' >&2 || true
    fail "Discourse logged errors during smoke run"
fi

cat <<EOF

Unfathomably/Discourse federation smoke test passed.

Covered:
  * supported: stock Discourse dev Docker boot with the official ActivityPub plugin
  * supported: Unfathomably follow of a Discourse category Group actor
  * supported: Discourse category follow of an Unfathomably group and posting user
  * supported: Discourse-to-Unfathomably category post, like, unlike, and reply lifecycle
  * supported: Unfathomably-to-Discourse group post, like, unlike, reply, reply Delete, and post Delete
  $DISCOURSE_REPLY_DELETE_SUMMARY
  $DISCOURSE_POST_DELETE_SUMMARY
  * supported: group unfollow both directions
  * supported: basic log scan for 500/crash output

Run with KEEP_SMOKE=1 to leave both servers available for manual browser/API work.
EOF

# end of unfathomably-discourse-smoke.sh
