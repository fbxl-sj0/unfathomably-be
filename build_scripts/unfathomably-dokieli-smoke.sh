#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-dokieli-smoke.sh
#
# Purpose:
#
#   Run stock dokieli against a real Unfathomably public object and exercise
#   dokieli's document-level Linked Data Notification interoperability.
#
# Responsibilities:
#
#   * build the pinned stock dokieli source without patching its implementation
#   * run dokieli in Chromium and use its own inbox discovery and serializer
#   * announce, like, and reply to a real public Unfathomably object by IRI
#   * verify bounded LDN requests, content negotiation, and canonical identity
#   * report account-level ActivityPub operations that dokieli does not provide
#
# This file intentionally does NOT contain:
#
#   * a synthetic dokieli actor or ActivityPub inbox
#   * hand-authored replacement activities attributed to dokieli
#   * acceptance of unsigned LDN traffic by an ActivityPub actor inbox
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-dokieli-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-dokieli.example.com}"
export BE_PORT="${BE_PORT:-5091}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_dokieli_smoke_be}"
export GTS_HOST="${GTS_HOST:-dokieli-stock.example.com}"
export GTS_PORT="${GTS_PORT:-5092}"
export GTS_APP_PORT=80
export GTS_FORWARDED_PROTO=http
export GTS_LABEL=dokieli
export GTS_USERNAME=dokieli
export SMOKE_TLS=0
export BE_FEDERATION_SCHEME=http
export BE_FEDERATION_PORT=80

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

DOKIELI_REPOSITORY="${DOKIELI_REPOSITORY:-https://github.com/dokieli/dokieli.git}"
DOKIELI_COMMIT="${DOKIELI_COMMIT:-ac7057c1ed457f2574da505f05d2ed1b32754c7b}"
DOKIELI_VERSION="${DOKIELI_VERSION:-0.3.1475}"
DOKIELI_REFERENCE_SOURCE="${DOKIELI_REFERENCE_SOURCE:-}"
DOKIELI_NODE_IMAGE="${DOKIELI_NODE_IMAGE:-node:26-bookworm-slim}"
DOKIELI_PLAYWRIGHT_IMAGE="${DOKIELI_PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v1.60.0-noble}"
DOKIELI_NGINX_IMAGE="${DOKIELI_NGINX_IMAGE:-nginx:1.27-alpine}"
DOKIELI_SOURCE="$WORK_DIR/dokieli"
DOKIELI_CONTAINER="$GTS_CONTAINER"
DOKIELI_LDN_CONTAINER="${PREFIX}-ldn"
DOKIELI_LDN_CAPTURE="$WORK_DIR/ldn-capture"
DOKIELI_LDN_SERVER="$WORK_DIR/ldn-server.mjs"

cleanup_dokieli_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f "$DOKIELI_LDN_CONTAINER" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_dokieli_smoke EXIT

prepare_dokieli_source() {
    if [ -n "$DOKIELI_REFERENCE_SOURCE" ]; then
        [ -d "$DOKIELI_REFERENCE_SOURCE/.git" ] || \
            fail "DOKIELI_REFERENCE_SOURCE is not a dokieli checkout"
        mkdir -p "$DOKIELI_SOURCE"
        cp -a "$DOKIELI_REFERENCE_SOURCE/." "$DOKIELI_SOURCE/"
    else
        git clone --quiet --no-checkout "$DOKIELI_REPOSITORY" "$DOKIELI_SOURCE"
    fi

    git -C "$DOKIELI_SOURCE" checkout --quiet --detach "$DOKIELI_COMMIT"

    local actual_commit actual_version
    actual_commit="$(git -C "$DOKIELI_SOURCE" rev-parse HEAD)"
    actual_version="$(python3 - "$DOKIELI_SOURCE/package.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["version"])
PY
    )"

    [ "$actual_commit" = "$DOKIELI_COMMIT" ] || \
        fail "dokieli checkout did not resolve the pinned commit"
    [ "$actual_version" = "$DOKIELI_VERSION" ] || \
        fail "dokieli package version did not match $DOKIELI_VERSION"
}

write_dokieli_probe() {
    cat >"$DOKIELI_SOURCE/smoke-entry.js" <<'EOF'
import { inboxResponse, notifyInbox } from './src/activity.js';
import Config from './src/config.js';
import { HttpStorage, initStorage } from './src/storage/backend.js';

const http = new HttpStorage();
Config.Storage = initStorage({
  default: http,
  backends: { http },
});

window.DokieliSmoke = {
  inboxResponse,
  notifyInbox,
  storageReady: Boolean(Config.Storage),
};
EOF

    cat >"$DOKIELI_SOURCE/smoke-webpack.cjs" <<'EOF'
const makeBaseConfig = require('./webpack.config.cjs');

module.exports = (env) => {
  const config = makeBaseConfig(env);
  config.entry = {
    ...config.entry,
    smoke: './smoke-entry.js',
  };
  return config;
};
EOF

    cat >"$DOKIELI_SOURCE/smoke-driver.cjs" <<'EOF'
const { chromium } = require('playwright');

async function main() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const browserErrors = [];

  page.on('pageerror', (error) => browserErrors.push(String(error)));

  try {
    await page.goto('http://127.0.0.1/demo.html', { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => window.DO?.C?.Storage, null, { timeout: 30000 });
    await page.addScriptTag({ url: 'http://127.0.0.1/scripts/smoke.js' });
    await page.waitForFunction(() => window.DokieliSmoke?.notifyInbox && window.DokieliSmoke?.storageReady, null, { timeout: 10000 });

    const result = await page.evaluate(async ({ objectIRI, resourceIRI }) => {
      const inbox = await window.DokieliSmoke.inboxResponse(resourceIRI, document.body);
      const requests = [
        {
          type: ['as:Announce'],
          object: objectIRI,
          target: objectIRI,
          summary: 'DOKIELI-ANNOUNCE-UNFATHOMABLY',
          to: resourceIRI,
        },
        {
          type: ['as:Like'],
          object: objectIRI,
          context: objectIRI,
          summary: 'DOKIELI-LIKE-UNFATHOMABLY',
          to: resourceIRI,
        },
        {
          type: ['as:Create'],
          object: resourceIRI + '#dokieli-reply',
          inReplyTo: objectIRI,
          summary: 'DOKIELI-REPLY-UNFATHOMABLY',
          to: resourceIRI,
        },
      ];
      const responses = [];

      for (const request of requests) {
        const response = await window.DokieliSmoke.notifyInbox({ ...request, inbox });
        responses.push({
          status: response.status,
          location: response.headers.get('Location'),
        });
      }

      return {
        inbox,
        responses,
        title: document.title,
        dokieliReady: Boolean(window.DO?.C?.Storage),
      };
    }, {
      objectIRI: process.env.UNFATHOMABLY_OBJECT_IRI,
      resourceIRI: 'http://dokieli-ldn:8081/resource',
    });

    if (browserErrors.length) {
      result.browserErrors = browserErrors;
    }
    process.stdout.write(JSON.stringify(result));
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
EOF
}

write_ldn_receiver() {
    mkdir -p "$DOKIELI_LDN_CAPTURE"

    cat >"$DOKIELI_LDN_SERVER" <<'EOF'
/*
    Bounded Linked Data Notification receiver used only by the dokieli smoke
    harness. It records requests so the harness can verify stock dokieli's
    serializer without pretending this receiver is a federated actor.
*/

import http from 'node:http';
import fs from 'node:fs';

const MAX_BODY_BYTES = 1024 * 1024;
const capturePath = '/data/capture.json';
const messages = [];

function corsHeaders(extra = {}) {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS, POST',
    'Access-Control-Allow-Headers': 'Content-Type, Link, Slug',
    'Access-Control-Expose-Headers': 'Accept-Post, Link, Location',
    ...extra,
  };
}

function writeJson(response, status, value, extra = {}) {
  const body = JSON.stringify(value);
  response.writeHead(status, corsHeaders({
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    ...extra,
  }));
  response.end(body);
}

const server = http.createServer((request, response) => {
  if (request.url === '/health') {
    writeJson(response, 200, { ok: true });
    return;
  }

  if (request.url === '/resource' && (request.method === 'GET' || request.method === 'HEAD')) {
    const body = '<!doctype html><title>dokieli LDN resource</title>';
    response.writeHead(200, corsHeaders({
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': Buffer.byteLength(body),
      'Link': '<http://dokieli-ldn:8081/inbox>; rel="http://www.w3.org/ns/ldp#inbox"',
    }));
    response.end(request.method === 'HEAD' ? undefined : body);
    return;
  }

  if (request.url === '/inbox' && request.method === 'OPTIONS') {
    response.writeHead(204, corsHeaders({ 'Accept-Post': 'application/ld+json' }));
    response.end();
    return;
  }

  if (request.url === '/inbox' && request.method === 'POST') {
    const chunks = [];
    let length = 0;
    let rejected = false;

    request.on('data', (chunk) => {
      length += chunk.length;
      if (length > MAX_BODY_BYTES) {
        rejected = true;
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => {
      if (rejected) {
        writeJson(response, 413, { error: 'notification too large' });
        return;
      }

      const body = Buffer.concat(chunks).toString('utf8');
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch {
        writeJson(response, 400, { error: 'notification is not JSON' });
        return;
      }

      const id = messages.length + 1;
      messages.push({
        id,
        contentType: request.headers['content-type'] || '',
        link: request.headers.link || '',
        slug: request.headers.slug || '',
        bodyBytes: Buffer.byteLength(body),
        parsed,
      });
      fs.writeFileSync(capturePath, JSON.stringify({ messages }), { encoding: 'utf8', mode: 0o644 });
      writeJson(response, 201, { stored: id }, { Location: `/inbox/${id}` });
    });
    return;
  }

  if (request.url === '/capture' && request.method === 'GET') {
    writeJson(response, 200, { messages });
    return;
  }

  writeJson(response, 404, { error: 'not found' });
});

server.listen(8081, '0.0.0.0');
EOF
}

build_dokieli() {
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp/dokieli-node-home \
        -v "$DOKIELI_SOURCE:/work" \
        -w /work \
        "$DOKIELI_NODE_IMAGE" \
        bash -lc 'set -euo pipefail; mkdir -p "$HOME"; npx --yes corepack yarn install --immutable; npx --yes corepack yarn webpack --config smoke-webpack.cjs'
}

start_dokieli_services() {
    docker run -d \
        --name "$DOKIELI_LDN_CONTAINER" \
        --network "$NETWORK" \
        --network-alias dokieli-ldn \
        -v "$DOKIELI_LDN_SERVER:/app/ldn-server.mjs:ro" \
        -v "$DOKIELI_LDN_CAPTURE:/data" \
        "$DOKIELI_NODE_IMAGE" \
        node /app/ldn-server.mjs >/dev/null

    docker run -d \
        --name "$DOKIELI_CONTAINER" \
        --network "$NETWORK" \
        --network-alias dokieli-stock \
        -p "127.0.0.1:$GTS_PORT:80" \
        -v "$DOKIELI_SOURCE:/usr/share/nginx/html:ro" \
        "$DOKIELI_NGINX_IMAGE" >/dev/null
}

wait_dokieli_services() {
    for _ in $(seq 1 60); do
        if curl -fsS "$GTS_BASE/demo.html" >/dev/null && \
            docker run --rm --network "$NETWORK" "$DOKIELI_NODE_IMAGE" \
                node -e "fetch('http://dokieli-ldn:8081/health').then(r=>{if(!r.ok)process.exit(1)})"; then
            return 0
        fi
        sleep 2
    done

    fail "dokieli static site or LDN receiver did not become ready"
}

assert_ldn_capture() {
    local capture_file="$DOKIELI_LDN_CAPTURE/capture.json"

    [ -f "$capture_file" ] || fail "dokieli did not write an LDN capture"

    CAPTURE_FILE="$capture_file" OBJECT_IRI="$UNFATHOMABLY_OBJECT_IRI" python3 - <<'PY'
import json
import os

with open(os.environ["CAPTURE_FILE"], encoding="utf-8") as handle:
    messages = json.load(handle).get("messages", [])

if len(messages) != 3:
    raise SystemExit(f"expected three dokieli notifications, got {len(messages)}")

expected_types = ["Announce", "Like", "Create"]
activitystreams = "https://www.w3.org/ns/activitystreams#"


def graph_nodes(message):
    parsed = message.get("parsed") or []
    return parsed if isinstance(parsed, list) else [parsed]


def graph_ids(nodes, property_name):
    values = []
    for node in nodes:
        value = node.get(property_name)
        if value is None:
            continue
        for item in value if isinstance(value, list) else [value]:
            if isinstance(item, dict) and item.get("@id"):
                values.append(item["@id"])
    return values


for index, (message, expected_type) in enumerate(zip(messages, expected_types), start=1):
    if not message.get("contentType", "").startswith("application/ld+json"):
        raise SystemExit(f"message {index} did not use JSON-LD content negotiation")
    if message.get("bodyBytes", 0) <= 0 or message.get("bodyBytes", 0) > 1024 * 1024:
        raise SystemExit(f"message {index} violated the receiver body bound")

    nodes = graph_nodes(message)
    activity_types = []
    for node in nodes:
        node_types = node.get("@type") or []
        activity_types.extend(node_types if isinstance(node_types, list) else [node_types])
    if activitystreams + expected_type not in activity_types:
        raise SystemExit(f"message {index} did not retain {expected_type}")

object_iri = os.environ["OBJECT_IRI"]
for index in (0, 1):
    if object_iri not in graph_ids(graph_nodes(messages[index]), activitystreams + "object"):
        raise SystemExit(f"message {index + 1} lost the Unfathomably object IRI")

reply_nodes = graph_nodes(messages[2])
if object_iri not in graph_ids(reply_nodes, activitystreams + "inReplyTo"):
    raise SystemExit("dokieli Create notification lost its Unfathomably reply target")
PY
}

run_dokieli_smoke() {
    local status status_json browser_result

    write_be_secret
    write_proxy_configs
    prepare_dokieli_source
    write_dokieli_probe
    write_ldn_receiver

    log "Creating isolated dokieli notification network"
    docker rm -f \
        "$DOKIELI_LDN_CONTAINER" \
        "$DOKIELI_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null

    log "Building stock dokieli $DOKIELI_VERSION at $DOKIELI_COMMIT"
    build_dokieli
    start_dokieli_services
    wait_dokieli_services

    log "Migrating and starting Unfathomably"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"

    log "Creating the public Unfathomably object shared by dokieli"
    status="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        'status=DOKIELI-UNFATHOMABLY-PUBLIC-OBJECT' \
        'visibility=public')"
    UNFATHOMABLY_OBJECT_IRI="$(json_get "$status" uri)"
    [ -n "$UNFATHOMABLY_OBJECT_IRI" ] || \
        fail "Unfathomably did not return the public object's canonical IRI"

    status_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$BE_BASE${UNFATHOMABLY_OBJECT_IRI#http://"$BE_HOST"}")"
    json_assert "$status_json" \
        "data.get('id') == '$UNFATHOMABLY_OBJECT_IRI' and data.get('type') == 'Note' and 'DOKIELI-UNFATHOMABLY-PUBLIC-OBJECT' in data.get('content', '')" \
        "Unfathomably did not expose the shared public Note by canonical IRI"

    log "Running stock dokieli inbox discovery and notifications in Chromium"
    browser_result="$(docker run --rm \
        --network "container:$DOKIELI_CONTAINER" \
        -e "UNFATHOMABLY_OBJECT_IRI=$UNFATHOMABLY_OBJECT_IRI" \
        -v "$DOKIELI_SOURCE:/work" \
        -w /work \
        "$DOKIELI_PLAYWRIGHT_IMAGE" \
        node smoke-driver.cjs)"
    json_assert "$browser_result" \
        'data.get("dokieliReady") is True and data.get("title") == "dokieli demo" and data.get("inbox") == "http://dokieli-ldn:8081/inbox" and len(data.get("responses", [])) == 3 and all(item.get("status") == 201 and item.get("location") for item in data.get("responses", [])) and not data.get("browserErrors")' \
        "stock dokieli did not discover and notify the LDN inbox cleanly"
    assert_ldn_capture

    log "Deleting the shared Unfathomably object and verifying lifecycle cleanup"
    http_form DELETE "$BE_BASE/api/v1/statuses/$(json_get "$status" id)" "$ALICE_TOKEN" 200 >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$(json_get "$status" id)" \
        "Unfathomably retained the deleted object shared through dokieli"

    check_logs "$BE_CONTAINER" Unfathomably
    check_logs "$DOKIELI_CONTAINER" dokieli
    check_logs "$DOKIELI_LDN_CONTAINER" "dokieli LDN receiver"

    cat <<EOF

dokieli federation smoke passed.

Covered against stock dokieli $DOKIELI_VERSION at $DOKIELI_COMMIT:
* supported: discovery: dokieli discovers a document LDN inbox through its standard ldp:inbox Link relation
* supported: native representation: stock dokieli serializes Announce, Like, and Create notifications as ActivityStreams JSON-LD
* supported: compatibility representation: notifications retain a real public Unfathomably Note IRI without inventing a dokieli actor
* not_supported: semantic deduplication: dokieli is a client and does not maintain a federated server-side object index
* not_supported: authority: unsigned LDN notifications do not establish ActivityPub actor authority
* supported: lifecycle: the LDN receiver returns durable Location IRIs and the referenced Unfathomably object can be deleted normally
* not_supported: concurrency: dokieli exposes no conditional federated update or conflict API
* not_supported: collections: dokieli has document notification sources, not ActivityPub actor follower collections
* supported: context: Create notifications retain the canonical Unfathomably inReplyTo IRI
* supported: capabilities: the UI and serializer expose only document actions that dokieli actually implements
* supported: round trip: real Chromium sends stock dokieli output through HTTP content negotiation to a real LDN receiver
* not_supported: unknown JSON-LD: this boundary does not claim Unfathomably ingestion of unsigned extension terms
* supported: privacy: no unsigned LDN message is submitted to or accepted by an Unfathomably actor inbox
* not_supported: idempotence: stock dokieli does not assign stable activity IDs to repeated notifications
* supported: failure classification: actor follows, group follows, Undo, Block, Flag, and defederation are labeled unsupported
* supported: resource safety: the receiver enforces a one MiB body limit and all containers run on an isolated network
* supported: UI classification: the stock dokieli document UI loads, while Unfathomably remains an ordinary public Note target
* supported: cleanup: the Unfathomably object, browser, containers, network, build tree, and captures are removed by the harness
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_dokieli_smoke
fi

# end of build_scripts/unfathomably-dokieli-smoke.sh
