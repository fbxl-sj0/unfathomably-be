#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-nostr-smoke.sh
#
# Purpose:
#
#   Verify the completed two-container native Nostr and NIP-29 smoke fixture.
#
# Responsibilities:
#
#   * verify the Unfathomably and stock NIP-29 relay containers are healthy
#   * validate the local relay's NIP-11 capability document
#   * prove retained bidirectional bridge and group lifecycle evidence
#   * reject stale replacement keys and non-terminal Nostr worker queues
#
# This file intentionally does NOT contain:
#
#   * production deployment or Mostr migration logic
#   * private Nostr keys
#   * relay provisioning or destructive fixture cleanup
#

set -euo pipefail

BE_CONTAINER="${BE_CONTAINER:-unfathomably-nostr-smoke}"
RELAY_CONTAINER="${RELAY_CONTAINER:-unfathomably-nip29-relay}"
BE_BASE="${BE_BASE:-http://127.0.0.1:45000}"
RELAY_URL="${RELAY_URL:-ws://127.0.0.1:43000}"
NOSTR_GROUP_ID="${NOSTR_GROUP_ID:-}"
NOSTR_OWNER_PUBKEY="${NOSTR_OWNER_PUBKEY:-}"
WORK_DIR="${SMOKE_WORK_DIR:-}"

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-nostr-smoke.XXXXXX")"
fi

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_command base64
require_command curl
require_command docker
require_command node
require_command python3

[ -n "$NOSTR_GROUP_ID" ] || fail "NOSTR_GROUP_ID is required"
[ -n "$NOSTR_OWNER_PUBKEY" ] || fail "NOSTR_OWNER_PUBKEY is required"

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

container_running "$BE_CONTAINER" || fail "$BE_CONTAINER is not running"
container_running "$RELAY_CONTAINER" || fail "$RELAY_CONTAINER is not running"

rpc() {
    local code="$1"
    local encoded

    encoded="$(printf '%s' "$code" | base64 | tr -d '\r\n')"
    docker exec "$BE_CONTAINER" \
        /opt/pleroma/bin/pleroma rpc \
        "Code.eval_string(Base.decode64!(\"$encoded\"))"
}

nostr_query() {
    local relay_url="$1"
    local filter="$2"
    local output="$3"

    node --input-type=module - "$relay_url" "$filter" "$output" <<'NODE'
import fs from 'node:fs';

const [relayUrl, encodedFilter, output] = process.argv.slice(2);
const filter = JSON.parse(encodedFilter);
const events = [];
const socket = new WebSocket(relayUrl);
const timeout = setTimeout(() => {
  console.error('Timed out waiting for relay EOSE');
  process.exit(2);
}, 10000);

socket.addEventListener('open', () => {
  socket.send(JSON.stringify(['REQ', 'unfathomably-smoke', filter]));
});

socket.addEventListener('message', ({ data }) => {
  const frame = JSON.parse(String(data));

  if (frame[0] === 'EVENT' && frame[1] === 'unfathomably-smoke') {
    events.push(frame[2]);
  }

  if (frame[0] === 'EOSE' && frame[1] === 'unfathomably-smoke') {
    clearTimeout(timeout);
    fs.writeFileSync(output, JSON.stringify(events));
    socket.close();
  }

  if (frame[0] === 'CLOSED' && frame[1] === 'unfathomably-smoke') {
    clearTimeout(timeout);
    console.error(`Relay closed smoke subscription: ${frame[2] || 'no reason'}`);
    process.exit(1);
  }
});

socket.addEventListener('error', () => {
  clearTimeout(timeout);
  process.exit(1);
});
NODE
}

log "Checking NIP-11 relay metadata"

nip11="$(curl -fsS -H 'Accept: application/nostr+json' "$BE_BASE/relay")"

NIP11="$nip11" python3 - <<'PY'
import json
import os

document = json.loads(os.environ["NIP11"])
required = {1, 2, 9, 11, 18, 19, 22, 25, 29, 42, 45, 48}
actual = set(document.get("supported_nips", []))

if not required.issubset(actual):
    raise SystemExit(f"missing supported NIPs: {sorted(required - actual)}")

if document.get("limitation", {}).get("max_subscriptions", 0) <= 0:
    raise SystemExit("NIP-11 is missing bounded subscription metadata")
PY

log "Checking bridge database invariants"

rpc '
alias Pleroma.Repo

count = fn sql -> Repo.query!(sql).rows |> hd() |> hd() end

checks = %{
  mirror_groups:
    count.("SELECT count(*) FROM nostr_entities WHERE kind = '\''mirror_group'\''"),
  hosted_groups:
    count.("SELECT count(*) FROM nostr_entities WHERE kind = '\''local_group'\''"),
  imported_content:
    count.("SELECT count(*) FROM nostr_events WHERE local = false AND kind IN (9, 11) AND ap_activity_id IS NOT NULL"),
  exported_content:
    count.("SELECT count(*) FROM nostr_events WHERE local = true AND kind IN (9, 11) AND ap_activity_id IS NOT NULL"),
  reactions:
    count.("SELECT count(*) FROM nostr_events WHERE kind = 7 AND ap_activity_id IS NOT NULL"),
  joins_and_leaves:
    count.("SELECT count(*) FROM nostr_events WHERE kind IN (9021, 9022)"),
  durable_activity_uris:
    count.("SELECT count(*) FROM nostr_events WHERE local = true AND ap_activity_id IS NOT NULL AND ap_activity_uri IS NOT NULL"),
  bad_regular_replacement_keys:
    count.("SELECT count(*) FROM nostr_events WHERE kind IN (1, 2) AND replace_key IS NOT NULL"),
  bad_contact_replacement_keys:
    count.("SELECT count(*) FROM nostr_events WHERE kind = 3 AND replace_key IS DISTINCT FROM '\''3:'\'' || pubkey"),
  active_jobs:
    count.("SELECT count(*) FROM oban_jobs WHERE queue = '\''nostr'\'' AND state NOT IN ('\''completed'\'', '\''cancelled'\'')")
}

required_positive = [
  :mirror_groups,
  :hosted_groups,
  :imported_content,
  :exported_content,
  :reactions,
  :joins_and_leaves,
  :durable_activity_uris
]

failures =
  Enum.filter(required_positive, &(checks[&1] < 1)) ++
    Enum.filter(
      [:bad_regular_replacement_keys, :bad_contact_replacement_keys, :active_jobs],
      &(checks[&1] != 0)
    )

IO.puts("NOSTR_SMOKE_DATABASE=" <> Jason.encode!(checks))

if failures != [] do
  raise "Nostr smoke database invariants failed: #{inspect(failures)}"
end
'

log "Checking stock relay group evidence"

relay_events="$WORK_DIR/relay-events.json"
printf '[]' > "$relay_events"

for kind in 9 11 9021 9022; do
    kind_events="$WORK_DIR/relay-events-$kind.json"

    nostr_query \
        "$RELAY_URL" \
        "{\"kinds\":[$kind],\"#h\":[\"$NOSTR_GROUP_ID\"]}" \
        "$kind_events"

    MERGED="$relay_events" ADDITIONAL="$kind_events" python3 - <<'PY'
import json
import os

with open(os.environ["MERGED"], "r", encoding="utf-8") as handle:
    merged = json.load(handle)

with open(os.environ["ADDITIONAL"], "r", encoding="utf-8") as handle:
    merged.extend(json.load(handle))

with open(os.environ["MERGED"], "w", encoding="utf-8") as handle:
    json.dump(merged, handle)
PY
done

RELAY_EVENTS="$relay_events" OWNER="$NOSTR_OWNER_PUBKEY" python3 - <<'PY'
import json
import os

with open(os.environ["RELAY_EVENTS"], "r", encoding="utf-8") as handle:
    events = json.load(handle)

kinds = {event.get("kind") for event in events}
required = {9, 11, 9021, 9022}

if not required.issubset(kinds):
    raise SystemExit(f"relay lifecycle evidence is incomplete: missing {sorted(required - kinds)}")

owner = os.environ["OWNER"]
if not any(event.get("pubkey") == owner and event.get("kind") in {9, 11} for event in events):
    raise SystemExit("relay does not contain ActivityPub-owner group content")
PY

log "Nostr and NIP-29 smoke verification passed"

# end of unfathomably-nostr-smoke.sh
