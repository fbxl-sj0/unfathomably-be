#!/usr/bin/env bash

#
# Project: Unfathomably release tooling
# ------------------------------------------------------------
#
# File: unfathomably-release-gate.sh
#
# Purpose:
#
#   Run the full pre-release gate for Unfathomably BE and FE without
#   interactive prompts.
#
# Responsibilities:
#
#   * run every configured federation smoke test first
#   * stop immediately and report a federation failure if a smoke test fails
#   * run backend and frontend unit tests only after federation is green
#   * enforce compile, type, lint, and build warning gates
#   * check backend Hex and frontend Yarn package freshness
#   * print "ready to release" only after every gate succeeds
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * automatic dependency upgrades
#   * interactive recovery prompts
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="${BE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ -n "${FE_ROOT:-}" ]; then
    RESOLVED_FE_ROOT="$FE_ROOT"
elif [ -d "$BE_ROOT/../unfathomably-fe" ]; then
    RESOLVED_FE_ROOT="$(cd "$BE_ROOT/../unfathomably-fe" && pwd)"
elif [ -d "$BE_ROOT/../../unfathomably-fe" ]; then
    RESOLVED_FE_ROOT="$(cd "$BE_ROOT/../../unfathomably-fe" && pwd)"
else
    RESOLVED_FE_ROOT=""
fi

FE_ROOT="$RESOLVED_FE_ROOT"

RELEASE_GATE_LOG_DIR="${RELEASE_GATE_LOG_DIR:-$BE_ROOT/release-gate-logs}"
RELEASE_GATE_SKIP_FEDERATION="${RELEASE_GATE_SKIP_FEDERATION:-0}"
RELEASE_GATE_SKIP_FE="${RELEASE_GATE_SKIP_FE:-0}"
RELEASE_GATE_SKIP_PACKAGE_FRESHNESS="${RELEASE_GATE_SKIP_PACKAGE_FRESHNESS:-0}"

FEDERATION_SCRIPTS_DEFAULT=(
    "build_scripts/two-instance-federation-smoke.sh"
    "build_scripts/be-fe-pleroma-smoke.sh"
    "build_scripts/unfathomably-federation-safety-smoke.sh"
    "build_scripts/unfathomably-lemmy-smoke.sh"
    "build_scripts/unfathomably-mbin-smoke.sh"
    "build_scripts/unfathomably-piefed-smoke.sh"
    "build_scripts/unfathomably-mastodon-smoke.sh"
    "build_scripts/unfathomably-gotosocial-smoke.sh"
    "build_scripts/unfathomably-misskey-smoke.sh"
    "build_scripts/unfathomably-iceshrimp-smoke.sh"
    "build_scripts/unfathomably-pixelfed-smoke.sh"
    "build_scripts/unfathomably-funkwhale-smoke.sh"
    "build_scripts/unfathomably-peertube-smoke.sh"
    "build_scripts/unfathomably-nodebb-smoke.sh"
    "build_scripts/unfathomably-discourse-smoke.sh"
    "build_scripts/unfathomably-hubzilla-smoke.sh"
    "build_scripts/unfathomably-friendica-smoke.sh"
    "build_scripts/unfathomably-wide-federation-smoke.sh"
)

mkdir -p "$RELEASE_GATE_LOG_DIR"

log() {
    printf '\n==> %s\n' "$*"
}

run_logged() {
    local name="$1"
    shift

    local logfile="$RELEASE_GATE_LOG_DIR/$name.log"

    log "$name"
    {
        printf 'Command:'
        printf ' %q' "$@"
        printf '\n\n'
        "$@"
    } 2>&1 | tee "$logfile"
}

fail_federation() {
    local script="$1"
    local status="$2"

    printf '\nFEDERATION FAILURE: %s exited with status %s\n' "$script" "$status" >&2
    printf 'See logs in %s\n' "$RELEASE_GATE_LOG_DIR" >&2
    exit "$status"
}

require_frontend_root() {
    if [ -z "$FE_ROOT" ]; then
        printf '\nFrontend checkout was not found. Set FE_ROOT or RELEASE_GATE_SKIP_FE=1.\n' >&2
        exit 1
    fi
}

parse_federation_scripts() {
    if [ -n "${RELEASE_GATE_FEDERATION_SCRIPTS:-}" ]; then
        # shellcheck disable=SC2206
        FEDERATION_SCRIPTS=($RELEASE_GATE_FEDERATION_SCRIPTS)
    else
        FEDERATION_SCRIPTS=("${FEDERATION_SCRIPTS_DEFAULT[@]}")
    fi
}

run_federation_gate() {
    if [ "$RELEASE_GATE_SKIP_FEDERATION" = "1" ]; then
        log "skipping federation gate"
        return
    fi

    run_logged \
        "federation-smoke-image" \
        bash "$BE_ROOT/build_scripts/unfathomably-smoke-image.sh"

    parse_federation_scripts

    for script in "${FEDERATION_SCRIPTS[@]}"; do
        local script_path="$BE_ROOT/$script"
        local script_name

        script_name="$(basename "$script" .sh)"

        if [ ! -f "$script_path" ]; then
            printf '\nFEDERATION FAILURE: missing federation script %s\n' "$script_path" >&2
            exit 1
        fi

        set +e
        run_logged "federation-$script_name" bash "$script_path"
        local status=$?
        set -e

        if [ "$status" -ne 0 ]; then
            fail_federation "$script" "$status"
        fi
    done
}

run_backend_unit_gate() {
    log "backend unit tests"

    (
        cd "$BE_ROOT"
        MIX_ENV=test mix test
    )
}

run_frontend_unit_gate() {
    if [ "$RELEASE_GATE_SKIP_FE" = "1" ]; then
        log "skipping frontend unit tests"
        return
    fi

    log "frontend unit tests"

    (
        require_frontend_root
        cd "$FE_ROOT"
        corepack yarn test:run
    )
}

run_compile_warning_gate() {
    log "backend compile warnings"

    (
        cd "$BE_ROOT"
        MIX_ENV=test WARNINGS_AS_ERRORS=1 mix compile --force
    )

    if [ "$RELEASE_GATE_SKIP_FE" = "1" ]; then
        log "skipping frontend compile warning gate"
        return
    fi

    log "frontend lint/type/build warnings"

    (
        require_frontend_root
        cd "$FE_ROOT"
        corepack yarn lint
        corepack yarn check
        corepack yarn build
    )
}

run_package_freshness_gate() {
    if [ "$RELEASE_GATE_SKIP_PACKAGE_FRESHNESS" = "1" ]; then
        log "skipping package freshness gate"
        return
    fi

    log "backend package freshness"

    (
        cd "$BE_ROOT"
        mix hex.outdated --all --within-requirements
    )

    if [ "$RELEASE_GATE_SKIP_FE" = "1" ]; then
        log "skipping frontend package freshness"
        return
    fi

    log "frontend package freshness"

    (
        require_frontend_root
        cd "$FE_ROOT"
        corepack yarn npm outdated --recursive
    )
}

main() {
    log "release gate logs: $RELEASE_GATE_LOG_DIR"

    run_federation_gate
    run_backend_unit_gate
    run_frontend_unit_gate
    run_compile_warning_gate
    run_package_freshness_gate

    printf '\nready to release\n'
}

main "$@"

# end of unfathomably-release-gate.sh
