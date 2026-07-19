#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-wide-federation-smoke.sh
#
# Purpose:
#
#   Run the broad platform federation lane across disposable stock peers and
#   public targets where a locally controlled peer is not available.
#
# Responsibilities:
#
#   * run the shared moderation and defederation safety contract
#   * exercise public target discovery, follow, content hydration,
#     favourite, unfavourite, and follow cleanup through Unfathomably
#   * run the locally controlled peer adapters and retain their full logs
#   * optionally exercise reply and reply-delete against public targets
#   * record which full-matrix capabilities still require a local peer
#   * distinguish unsupported platform behavior from behavior that was
#     testable but not tested
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * private OAuth tokens
#   * hidden success for untested reverse-direction federation paths
#   * duplicated service setup that belongs in a platform adapter
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_URL="${FEDERATION_WIDE_BASE_URL:-https://social.fbxl.net}"
TOKEN="${FEDERATION_WIDE_TOKEN:-${FEDERATION_AUDIT_TOKEN:-}}"
PLATFORMS="${FEDERATION_WIDE_PLATFORMS:-peertube,nodebb,discourse,fedigroups,hubzilla,friendica}"
LIMIT="${FEDERATION_WIDE_LIMIT:-6}"
TIMEOUT="${FEDERATION_WIDE_TIMEOUT:-45}"
REPORT_DIR="${FEDERATION_WIDE_REPORT_DIR:-/tmp/unfathomably-wide-federation-smoke}"
ACTIONS="${FEDERATION_WIDE_ACTIONS:-1}"
PUBLIC_REPLIES="${FEDERATION_WIDE_PUBLIC_REPLIES:-0}"
REQUIRE_FULL="${FEDERATION_WIDE_REQUIRE_FULL:-1}"
RUN_LOCAL_ADAPTERS="${FEDERATION_WIDE_LOCAL_ADAPTERS:-1}"
RUN_PUBLIC_AUDIT="${FEDERATION_WIDE_PUBLIC_AUDIT:-1}"
LOCAL_PLATFORMS="${FEDERATION_WIDE_LOCAL_PLATFORMS:-bookwyrm,forgefed,manyfold,ibis,neodb,wanderer,dokieli,flohmarkt,castling,bonfire-valueflows,zenpub,activitypods,mutual-aid,fedigroups,gancio,mobilizon,wordpress,xwiki,writefreely,snac,mitra,owncast,sharkey,wafrn,postmarks}"
LOCAL_KEEP_CONTAINERS="${FEDERATION_WIDE_KEEP_CONTAINERS:-0}"
RUN_SAFETY="${FEDERATION_WIDE_SAFETY:-1}"
SAFETY_BE_IMAGE="${FEDERATION_WIDE_SAFETY_BE_IMAGE:-${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}}"

usage() {
    cat <<'EOF'
Usage:
  unfathomably-wide-federation-smoke.sh [options]

Options:
  --base-url URL          Unfathomably base URL. Default:
                          FEDERATION_WIDE_BASE_URL or https://social.fbxl.net.
  --token TOKEN           OAuth token with read/write/follow access. May also
                          be provided as FEDERATION_WIDE_TOKEN or
                          FEDERATION_AUDIT_TOKEN.
  --platforms CSV         Comma-separated platform list. Default:
                          peertube,nodebb,discourse,fedigroups,hubzilla,friendica.
  --limit N               Preview/status item limit per platform. Default: 6.
  --timeout SECONDS       HTTP timeout per request. Default: 45.
  --report-dir DIR        Directory for JSON and TSV reports.
  --local-platforms CSV   Comma-separated disposable peer adapters. Default:
                          bookwyrm,forgefed,manyfold,ibis,neodb,wanderer,dokieli,flohmarkt,castling,bonfire-valueflows,zenpub,activitypods,mutual-aid,fedigroups,gancio,mobilizon,
                          wordpress,xwiki,writefreely,snac,mitra,owncast,sharkey,
                          wafrn,postmarks.
  --local-only            Run disposable local adapters without public targets.
  --public-only           Run the earlier public-target lane only.
  --no-safety             Skip the shared moderation/defederation contract.
  --keep-containers       Preserve local adapter containers after each run.
  --public-replies        Post and delete a reply against public remote targets.
                          This is disabled by default.
  --no-actions            Skip favourite/unfavourite checks.
  --allow-partial         Exit zero when public-target checks pass even though
                          reverse-direction full-matrix checks are not tested.
  -h, --help              Show this help.

The wide local lane first runs the shared moderation and defederation safety
contract, then each selected locally controlled stock peer adapter. Those
adapters contain the service-specific setup and broad bidirectional operation
checks. Their supported and not_supported result lines are collected into a
local adapter matrix without duplicating the setup here.

The public-target portion is deliberately stricter than a resolver probe, but
it is limited by public-target access. For each platform it writes a matrix row for
discovery, follow, inbound remote content, local favourite/unfavourite,
optional local reply/delete, follow cleanup, reverse follow, reverse posting,
reverse comments, reverse reactions, reverse deletes, moderation, and modlog
visibility. Capabilities that require an authenticated local peer are marked
not_tested here and should be covered by the platform-specific Docker harnesses.

All 39 names accepted by --local-platforms dispatch to their authoritative
peer-specific Docker harness. The default list is the 25 newest adapters so
the older established lanes are not repeated in every ordinary invocation.
The public portion remains available for externally hosted targets. If a
platform cannot perform a capability, the matrix says unsupported. If a
capability cannot be exercised in the selected lane, the matrix says
not_tested and the public audit fails unless --allow-partial is used.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base-url)
            BASE_URL="${2:-}"
            shift 2
            ;;
        --token)
            TOKEN="${2:-}"
            shift 2
            ;;
        --platforms)
            PLATFORMS="${2:-}"
            shift 2
            ;;
        --limit)
            LIMIT="${2:-}"
            shift 2
            ;;
        --timeout)
            TIMEOUT="${2:-}"
            shift 2
            ;;
        --report-dir)
            REPORT_DIR="${2:-}"
            shift 2
            ;;
        --local-platforms)
            LOCAL_PLATFORMS="${2:-}"
            shift 2
            ;;
        --local-only)
            RUN_LOCAL_ADAPTERS=1
            RUN_PUBLIC_AUDIT=0
            shift
            ;;
        --public-only)
            RUN_LOCAL_ADAPTERS=0
            RUN_PUBLIC_AUDIT=1
            shift
            ;;
        --no-safety)
            RUN_SAFETY=0
            shift
            ;;
        --keep-containers)
            LOCAL_KEEP_CONTAINERS=1
            shift
            ;;
        --public-replies)
            PUBLIC_REPLIES=1
            shift
            ;;
        --no-actions)
            ACTIONS=0
            shift
            ;;
        --allow-partial)
            REQUIRE_FULL=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ "$RUN_PUBLIC_AUDIT" = "1" ] && [ -z "$TOKEN" ]; then
    cat >&2 <<'EOF'
FEDERATION_WIDE_TOKEN or FEDERATION_AUDIT_TOKEN is required.

Use a normal local test account token with read, write, and follow scopes.
The wide lane performs reversible follow and favourite checks by default.
EOF
    exit 64
fi

if [ "$RUN_LOCAL_ADAPTERS" = "1" ]; then
    "$SCRIPT_DIR/unfathomably-smoke-image.sh"
fi

mkdir -p "$REPORT_DIR"

IFS=',' read -r -a PLATFORM_LIST <<< "$PLATFORMS"
IFS=',' read -r -a LOCAL_PLATFORM_LIST <<< "$LOCAL_PLATFORMS"

summary_file="$REPORT_DIR/summary.tsv"
matrix_file="$REPORT_DIR/full-matrix.tsv"
local_summary_file="$REPORT_DIR/local-adapter-summary.tsv"
local_matrix_file="$REPORT_DIR/local-adapter-matrix.tsv"

printf 'platform\tpublic_result\tresolved\tfollowed\titems\tnative_status\tactions\tfollow_cleanup\tfull_result\tnote\n' > "$summary_file"
printf 'platform\tcapability\tresult\tnote\n' > "$matrix_file"
printf 'platform\tresult\tlog\n' > "$local_summary_file"
printf 'platform\tresult\tcapability\n' > "$local_matrix_file"

failures=0

adapter_script() {
    case "$1" in
        activitypods|bonfire-valueflows|bookwyrm|castling|discourse|dokieli|fedigroups|flohmarkt|forgefed|friendica|funkwhale|gancio|gotosocial|hubzilla|ibis|iceshrimp|lemmy|manyfold|mastodon|mbin|misskey|mitra|mobilizon|mutual-aid|neodb|nodebb|owncast|peertube|piefed|pixelfed|postmarks|sharkey|snac|wafrn|wanderer|wordpress|writefreely|xwiki|zenpub)
            printf '%s/unfathomably-%s-smoke.sh\n' "$SCRIPT_DIR" "$1"
            ;;
        *)
            return 1
            ;;
    esac
}

record_local_adapter() {
    local platform="$1"
    local result="$2"
    local output="$3"

    python3 - "$platform" "$result" "$output" "$local_summary_file" "$local_matrix_file" <<'PY'
import pathlib
import sys

platform, result, output_path, summary_path, matrix_path = sys.argv[1:]
output = pathlib.Path(output_path)
lines = output.read_text(encoding="utf-8", errors="replace").splitlines() if output.exists() else []
capabilities = []

for line in lines:
    stripped = line.strip()
    if stripped.startswith("* supported:"):
        capabilities.append(("passed", stripped.removeprefix("* supported:").strip()))
    elif stripped.startswith("* not_supported:"):
        capabilities.append(("unsupported", stripped.removeprefix("* not_supported:").strip()))
    elif stripped.startswith("* stock_limitation:"):
        note = stripped.removeprefix("* stock_limitation:").strip()
        capabilities.append(("unsupported", f"stock limitation: {note}"))

missing_explicit_results = False
if not capabilities:
    missing_explicit_results = result == "passed"
    note = "adapter exited successfully without explicit supported or not_supported capability lines" if missing_explicit_results else "adapter did not complete"
    capabilities.append(("failed", note))

effective_result = "failed" if missing_explicit_results else result

with open(summary_path, "a", encoding="utf-8") as handle:
    handle.write(f"{platform}\t{effective_result}\t{output_path}\n")

with open(matrix_path, "a", encoding="utf-8") as handle:
    for status, capability in capabilities:
        clean = capability.replace("\t", " ").replace("\n", " ")[:300]
        handle.write(f"{platform}\t{status}\t{clean}\n")

if missing_explicit_results:
    raise SystemExit(2)
PY
}

run_safety_contract() {
    local output="$REPORT_DIR/local-shared-safety.log"

    echo "checking shared moderation and defederation safety contract"

    if FEDERATION_SAFETY_BE_IMAGE="$SAFETY_BE_IMAGE" \
        bash "$SCRIPT_DIR/unfathomably-federation-safety-smoke.sh" >"$output" 2>&1; then
        if record_local_adapter shared-safety passed "$output"; then
            return 0
        fi

        tail -n 40 "$output" >&2 || true
        return 1
    fi

    record_local_adapter shared-safety failed "$output"
    tail -n 40 "$output" >&2 || true
    return 1
}

run_local_adapter() {
    local platform="$1"
    local script output

    if ! script="$(adapter_script "$platform")"; then
        printf 'unknown local adapter: %s\n' "$platform" >&2
        return 1
    fi

    output="$REPORT_DIR/local-$platform.log"
    echo "checking local federation adapter: $platform"

    if env KEEP_CONTAINERS="$LOCAL_KEEP_CONTAINERS" bash "$script" >"$output" 2>&1; then
        # Adapter cleanup must never turn a failed assertion into a pass.  The
        # explicit error marker is a second line of defense for specialized
        # cleanup functions and remains useful for older external adapters.
        if grep -q '^ERROR:' "$output"; then
            record_local_adapter "$platform" failed "$output"
            tail -n 40 "$output" >&2 || true
            return 1
        fi

        if record_local_adapter "$platform" passed "$output"; then
            return 0
        fi

        tail -n 40 "$output" >&2 || true
        return 1
    fi

    record_local_adapter "$platform" failed "$output"
    tail -n 40 "$output" >&2 || true
    return 1
}

run_platform() {
    local platform="$1"
    local report="$REPORT_DIR/$platform.json"
    local output="$REPORT_DIR/$platform.log"
    local action_args=()

    if [ "$ACTIONS" = "1" ]; then
        action_args+=(--actions)
    fi

    if [ "$PUBLIC_REPLIES" = "1" ]; then
        action_args+=(--replies --public-replies)
    fi

    echo "checking broad federation platform: $platform"

    if python3 "$SCRIPT_DIR/live-federation-compat-audit.py" \
        --base-url "$BASE_URL" \
        --token "$TOKEN" \
        --only-lane group \
        --only-platform "$platform" \
        --limit "$LIMIT" \
        --timeout "$TIMEOUT" \
        --cleanup-follow \
        --report "$report" \
        "${action_args[@]}" >"$output" 2>&1; then
        summarize_platform "$platform" "$report" "tested"
        return 0
    fi

    summarize_platform "$platform" "$report" "not_tested"
    return 1
}

summarize_platform() {
    local platform="$1"
    local report="$2"
    local fallback_result="$3"

    python3 - "$platform" "$report" "$fallback_result" "$summary_file" "$matrix_file" "$PUBLIC_REPLIES" "$REQUIRE_FULL" <<'PY'
import json
import pathlib
import sys

platform, report_path, fallback_result, summary_path, matrix_path, public_replies, require_full = sys.argv[1:8]
report = pathlib.Path(report_path)
row = {}
result = fallback_result
note = ""

if report.exists():
    try:
        data = json.loads(report.read_text(encoding="utf-8"))
        rows = data.get("rows") or []
        row = rows[0] if rows else {}
        result = "tested" if row.get("ok") else "not_tested"
        note = str(row.get("error") or row.get("preview_warning") or "")
    except Exception as exc:
        note = f"could not parse report: {exc}"
else:
    note = "no report produced"

actions = row.get("actions") if isinstance(row.get("actions"), dict) else {}

def tested(ok, success_note="ok", fail_note="failed"):
    return ("passed", success_note) if ok else ("failed", fail_note)

capabilities = []
capabilities.append(("local_resolve_remote", *tested(row.get("resolved"), "target resolved", "target did not resolve")))
capabilities.append(("local_follow_remote", *tested(row.get("followed"), "join/follow accepted", "join/follow failed")))
capabilities.append(("remote_content_hydrated_locally", *tested(row.get("items_count", 0) > 0, "remote rows present", "no remote rows")))
capabilities.append(("remote_content_rendered_as_status", *tested(row.get("native_status_count", 0) > 0, "native status rows present", "no native status rows")))

if actions:
    capabilities.append(("local_like_remote", *tested(actions.get("favourite") in {"ok", "already favourited"}, str(actions.get("favourite")), str(actions.get("favourite")))))
    capabilities.append(("local_unlike_remote", *tested(actions.get("unfavourite") in {"ok", "preserved"}, str(actions.get("unfavourite")), str(actions.get("unfavourite")))))
else:
    capabilities.append(("local_like_remote", "not_tested", "actions disabled or no status row"))
    capabilities.append(("local_unlike_remote", "not_tested", "actions disabled or no status row"))

if public_replies == "1":
    capabilities.append(("local_reply_remote", *tested(actions.get("reply") == "ok", str(actions.get("reply")), str(actions.get("reply")))))
    capabilities.append(("local_delete_remote_reply", *tested(actions.get("delete_reply") == "ok", str(actions.get("delete_reply")), str(actions.get("delete_reply")))))
else:
    capabilities.append(("local_reply_remote", "not_tested", "public replies disabled"))
    capabilities.append(("local_delete_remote_reply", "not_tested", "public replies disabled"))

capabilities.append(("local_unfollow_remote", *tested("follow_cleanup_error" not in row and bool(row.get("follow_cleanup")), "cleanup accepted", str(row.get("follow_cleanup_error") or "not attempted"))))

unsupported = {
    "fedigroups": {
        "remote_follow_local_group": "FediGroup is a group relay service, not a full local user/forum peer that can follow an arbitrary remote group.",
        "remote_unfollow_local_group": "FediGroup is a group relay service, not a full local user/forum peer that can unfollow an arbitrary remote group.",
        "remote_comment_local_post": "FediGroup boosts mentioned posts rather than exposing a general remote-comment surface for arbitrary local group posts.",
        "local_receive_remote_comment": "FediGroup boosts mentioned posts rather than hosting a threaded comment model.",
        "remote_delete_comment": "FediGroup upstream lists Delete activity support as not implemented.",
        "local_receive_remote_comment_delete": "FediGroup upstream lists Delete activity support as not implemented.",
        "remote_like_local_post": "FediGroup upstream lists like/share support from the web UI as not implemented.",
        "local_receive_remote_like": "FediGroup upstream lists like/share support from the web UI as not implemented.",
        "remote_unlike_local_post": "FediGroup upstream lists like/share support from the web UI as not implemented.",
        "local_receive_remote_unlike": "FediGroup upstream lists like/share support from the web UI as not implemented.",
        "local_delete_post": "FediGroup upstream lists Delete activity support as not implemented.",
        "remote_receive_local_post_delete": "FediGroup upstream lists Delete activity support as not implemented.",
        "remote_moderation_local_group": "FediGroup upstream lists moderation as not implemented.",
        "remote_modlog_visible": "FediGroup upstream lists moderation as not implemented."
    },
    "peertube": {
        "remote_follow_local_group": "PeerTube video channels do not provide Threadiverse-style group membership.",
        "local_post_remote_group": "PeerTube channels are video publishers, not text community groups.",
        "remote_comment_local_post": "PeerTube cannot comment on an arbitrary local group post without a local PeerTube peer adapter.",
        "remote_moderation_local_group": "PeerTube has no compatible group moderator/modlog surface.",
        "remote_modlog_visible": "PeerTube has no compatible group modlog surface."
    },
    "hubzilla": {
        "local_receive_remote_comment": "Stock Hubzilla did not materialize remote replies under Hubzilla-authored content in the smoke-observable item table.",
        "remote_comment_local_post": "Stock Hubzilla item/update returned invalid post id for authenticated replies to imported Unfathomably ActivityPub objects.",
        "remote_like_local_post": "Stock Hubzilla accepted the local like action but did not federate Like to Unfathomably during the smoke window.",
        "local_receive_remote_like": "Stock Hubzilla accepted the local like action but did not federate Like to Unfathomably during the smoke window.",
        "remote_unlike_local_post": "Stock Hubzilla did not expose a completed federated Like state to undo in the smoke window.",
        "local_receive_remote_unlike": "Stock Hubzilla did not expose a completed federated Like state to undo in the smoke window.",
        "remote_receive_local_post_delete": "Stock Hubzilla accepted the Delete inbox delivery but did not mark imported Unfathomably posts deleted in the smoke-observable item table.",
        "remote_unfollow_local_group": "No matching stock Hubzilla CLI/API unfollow helper was available in the local harness surface."
    }
}

reverse_caps = [
    "remote_resolve_local_group",
    "remote_follow_local_group",
    "local_post_remote_group",
    "remote_receive_local_post",
    "remote_comment_local_post",
    "local_receive_remote_comment",
    "remote_delete_comment",
    "local_receive_remote_comment_delete",
    "remote_like_local_post",
    "local_receive_remote_like",
    "remote_unlike_local_post",
    "local_receive_remote_unlike",
    "local_delete_post",
    "remote_receive_local_post_delete",
    "remote_unfollow_local_group",
    "remote_moderation_local_group",
    "remote_modlog_visible",
]

for cap in reverse_caps:
    if cap in unsupported.get(platform, {}):
        capabilities.append((cap, "unsupported", unsupported[platform][cap]))
    else:
        capabilities.append((cap, "not_tested", "no local platform peer or authenticated adapter configured"))

hard_failures = [cap for cap in capabilities if cap[1] == "failed"]
not_tested = [cap for cap in capabilities if cap[1] == "not_tested"]
full_result = "passed"

if hard_failures:
    full_result = "failed"
elif require_full == "1" and not_tested:
    full_result = "not_tested"

with open(matrix_path, "a", encoding="utf-8") as handle:
    for cap, status, cap_note in capabilities:
        cap_note = str(cap_note or "").replace("\t", " ").replace("\n", " ")[:240]
        handle.write(f"{platform}\t{cap}\t{status}\t{cap_note}\n")

summary_note = note
if full_result == "not_tested":
    summary_note = f"{len(not_tested)} full-matrix capabilities need a local peer or adapter"
elif full_result == "failed":
    summary_note = f"{len(hard_failures)} tested capabilities failed"

summary_note = str(summary_note or "").replace("\t", " ").replace("\n", " ")[:240]

with open(summary_path, "a", encoding="utf-8") as handle:
    handle.write(
        "{platform}\t{public_result}\t{resolved}\t{followed}\t{items}\t{native}\t{actions}\t{cleanup}\t{full_result}\t{note}\n".format(
            platform=platform,
            public_result=result,
            resolved="1" if row.get("resolved") else "0",
            followed="1" if row.get("followed") else "0",
            items=row.get("items_count", 0),
            native=row.get("native_status_count", 0),
            actions="1" if actions else "0",
            cleanup="0" if row.get("follow_cleanup_error") else ("1" if row.get("follow_cleanup") else "0"),
            full_result=full_result,
            note=summary_note,
        )
    )

if result != "tested" or full_result == "failed" or (require_full == "1" and full_result == "not_tested"):
    raise SystemExit(1)
PY
}

if [ "$RUN_LOCAL_ADAPTERS" = "1" ]; then
    if [ "$RUN_SAFETY" = "1" ] && ! run_safety_contract; then
        failures=$((failures + 1))
    fi

    for raw_platform in "${LOCAL_PLATFORM_LIST[@]}"; do
        platform="$(printf '%s' "$raw_platform" | tr '[:upper:]' '[:lower:]' | xargs)"

        if [ -z "$platform" ]; then
            continue
        fi

        if ! run_local_adapter "$platform"; then
            failures=$((failures + 1))
        fi
    done

    echo
    echo "Local adapter summary:"
    cat "$local_summary_file"
    echo
    echo "Local adapter capability matrix:"
    cat "$local_matrix_file"
fi

if [ "$RUN_PUBLIC_AUDIT" = "1" ]; then
    for raw_platform in "${PLATFORM_LIST[@]}"; do
        platform="$(printf '%s' "$raw_platform" | tr '[:upper:]' '[:lower:]' | xargs)"

        if [ -z "$platform" ]; then
            continue
        fi

        if ! run_platform "$platform"; then
            failures=$((failures + 1))
        fi
    done

    echo
    cat "$summary_file"
    echo
    echo "Full public-target capability matrix:"
    cat "$matrix_file"
fi

echo
echo "Reports: $REPORT_DIR"

if [ "$failures" -gt 0 ]; then
    exit 1
fi

exit 0

# end of unfathomably-wide-federation-smoke.sh
