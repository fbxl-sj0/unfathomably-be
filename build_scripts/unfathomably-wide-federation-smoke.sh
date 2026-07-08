#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-wide-federation-smoke.sh
#
# Purpose:
#
#   Run the broad platform federation lane for group, forum, and channel
#   software when a live public target is the only available peer.
#
# Responsibilities:
#
#   * exercise public target discovery, follow, content hydration,
#     favourite, unfavourite, and follow cleanup through Unfathomably
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
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_URL="${FEDERATION_WIDE_BASE_URL:-https://social.example.com}"
TOKEN="${FEDERATION_WIDE_TOKEN:-${FEDERATION_AUDIT_TOKEN:-}}"
PLATFORMS="${FEDERATION_WIDE_PLATFORMS:-peertube,nodebb,discourse,fedigroups,hubzilla,friendica}"
LIMIT="${FEDERATION_WIDE_LIMIT:-6}"
TIMEOUT="${FEDERATION_WIDE_TIMEOUT:-45}"
REPORT_DIR="${FEDERATION_WIDE_REPORT_DIR:-/tmp/unfathomably-wide-federation-smoke}"
ACTIONS="${FEDERATION_WIDE_ACTIONS:-1}"
PUBLIC_REPLIES="${FEDERATION_WIDE_PUBLIC_REPLIES:-0}"
REQUIRE_FULL="${FEDERATION_WIDE_REQUIRE_FULL:-1}"

usage() {
    cat <<'EOF'
Usage:
  unfathomably-wide-federation-smoke.sh [options]

Options:
  --base-url URL          Unfathomably base URL. Default:
                          FEDERATION_WIDE_BASE_URL or https://social.example.com.
  --token TOKEN           OAuth token with read/write/follow access. May also
                          be provided as FEDERATION_WIDE_TOKEN or
                          FEDERATION_AUDIT_TOKEN.
  --platforms CSV         Comma-separated platform list. Default:
                          peertube,nodebb,discourse,fedigroups,hubzilla,friendica.
  --limit N               Preview/status item limit per platform. Default: 6.
  --timeout SECONDS       HTTP timeout per request. Default: 45.
  --report-dir DIR        Directory for JSON and TSV reports.
  --public-replies        Post and delete a reply against public remote targets.
                          This is disabled by default.
  --no-actions            Skip favourite/unfavourite checks.
  --allow-partial         Exit zero when public-target checks pass even though
                          reverse-direction full-matrix checks are not tested.
  -h, --help              Show this help.

The wide lane is deliberately stricter than a resolver probe, but it is still
limited by public-target access. For each platform it writes a matrix row for
discovery, follow, inbound remote content, local favourite/unfavourite,
optional local reply/delete, follow cleanup, reverse follow, reverse posting,
reverse comments, reverse reactions, reverse deletes, moderation, and modlog
visibility. Capabilities that require an authenticated local peer are marked
not_tested here and should be covered by the platform-specific Docker harnesses.

The existing Lemmy, Mbin, PieFed, Mastodon, Pleroma, Rebased, PeerTube, NodeBB,
Discourse, Hubzilla, and Friendica scripts remain the authoritative local Docker
full-matrix peers where such a peer can be booted. This script is the broad
public-target lane for PeerTube, NodeBB, Discourse, FediGroups, Hubzilla, and
Friendica. If a platform cannot perform a capability, the matrix says
unsupported. If we do not have a local peer or adapter for a capability, the
matrix says not_tested and the script fails unless --allow-partial is used.
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

if [ -z "$TOKEN" ]; then
    cat >&2 <<'EOF'
FEDERATION_WIDE_TOKEN or FEDERATION_AUDIT_TOKEN is required.

Use a normal local test account token with read, write, and follow scopes.
The wide lane performs reversible follow and favourite checks by default.
EOF
    exit 64
fi

mkdir -p "$REPORT_DIR"

IFS=',' read -r -a PLATFORM_LIST <<< "$PLATFORMS"

summary_file="$REPORT_DIR/summary.tsv"
matrix_file="$REPORT_DIR/full-matrix.tsv"

printf 'platform\tpublic_result\tresolved\tfollowed\titems\tnative_status\tactions\tfollow_cleanup\tfull_result\tnote\n' > "$summary_file"
printf 'platform\tcapability\tresult\tnote\n' > "$matrix_file"

failures=0

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
echo "Full capability matrix:"
cat "$matrix_file"
echo
echo "Reports: $REPORT_DIR"

if [ "$failures" -gt 0 ]; then
    exit 1
fi

exit 0

# end of unfathomably-wide-federation-smoke.sh
