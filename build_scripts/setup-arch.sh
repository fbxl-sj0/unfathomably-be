#!/usr/bin/env bash

# Unfathomably BE Arch bootstrap
# ------------------------------
#
# File: build_scripts/setup-arch.sh
#
# Purpose:
#
#     Prepare a fresh Arch-family host to build and work on unfathomably-be.
#
# Responsibilities:
#
#     * install operating-system packages through pacman
#     * install the pinned Erlang/OTP and Elixir versions from .tool-versions
#     * install local Hex/Rebar helpers
#     * optionally fetch Mix dependencies and compile the project
#
# This file intentionally does NOT contain:
#
#     * production database provisioning
#     * service user creation
#     * reverse proxy configuration
#     * deployment secrets
#
# Arch is a rolling distribution. This script uses pacman -Syu because partial
# upgrades are not supported on Arch and are more dangerous than a normal full
# package transaction on a fresh development machine.

set -euo pipefail

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"

install_os_packages=1
install_runtime=1
run_deps=1
run_compile=0
run_tests=0

usage() {
    cat <<'EOF'
Usage: build_scripts/setup-arch.sh [options]

Options:
    --no-os-packages   Skip pacman package installation.
    --no-runtime       Skip Erlang/Elixir installation.
    --no-deps          Skip mix deps.get.
    --compile          Run mix compile after dependency installation.
    --test             Run mix test after dependency installation.
    --check-only       Print detected versions and exit after setup checks.
    -h, --help         Show this help.

Environment:
    MIX_ENV            Mix environment to use. Defaults to dev.
    CI                 Enables warnings-as-errors through mix.exs when truthy.
    WARNINGS_AS_ERRORS Enables warnings-as-errors through mix.exs when truthy.
    MAKE_JOBS          Override parallel jobs used when Erlang builds from source.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-os-packages)
            install_os_packages=0
            ;;
        --no-runtime)
            install_runtime=0
            ;;
        --no-deps)
            run_deps=0
            ;;
        --compile)
            run_compile=1
            ;;
        --test)
            run_tests=1
            ;;
        --check-only)
            run_deps=0
            run_compile=0
            run_tests=0
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
    shift
done

require_arch_family() {
    if ! command -v pacman >/dev/null 2>&1; then
        echo "This bootstrap supports Arch-family distributions with pacman only." >&2
        exit 1
    fi
}

sudo_cmd() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "This step requires root privileges. Install sudo or run as root." >&2
        exit 1
    fi
}

read_tool_version() {
    local name="$1"
    awk -v wanted="$name" '$1 == wanted { print $2; exit }' "$repo_root/.tool-versions"
}

install_packages() {
    sudo_cmd pacman -Syu --needed --noconfirm \
        autoconf \
        automake \
        base-devel \
        bash \
        ca-certificates \
        cmake \
        curl \
        ffmpeg \
        file \
        git \
        imagemagick \
        inotify-tools \
        libpng \
        libssh \
        libvips \
        libxml2 \
        lksctp-tools \
        m4 \
        ncurses \
        openssl \
        perl-image-exiftool \
        pkgconf \
        postgresql \
        unixodbc \
        unzip \
        xz \
        zip
}

install_elixir_release_zip() {
    local archive elixir_base_version elixir_dir elixir_version installs_dir otp_suffix tmpdir url

    elixir_version="$1"
    installs_dir="$HOME/.elixir-install/installs"
    elixir_dir="$installs_dir/elixir/$elixir_version"
    elixir_base_version="${elixir_version%%-otp-*}"
    otp_suffix="${elixir_version##*-otp-}"

    if [ -x "$elixir_dir/bin/elixir" ]; then
        return 0
    fi

    tmpdir="$(mktemp -d)"
    archive="$tmpdir/elixir.zip"
    url="https://github.com/elixir-lang/elixir/releases/download/v$elixir_base_version/elixir-otp-$otp_suffix.zip"

    curl -fsSL "$url" -o "$archive"
    rm -rf "$elixir_dir"
    mkdir -p "$elixir_dir"
    unzip -q "$archive" -d "$elixir_dir"
    rm -rf "$tmpdir"
}

install_erlang_from_source() {
    local archive jobs otp_dir otp_version source_dir tmpdir url

    otp_version="$1"
    otp_dir="$HOME/.elixir-install/installs/otp/$otp_version"

    if [ -x "$otp_dir/bin/erl" ]; then
        return 0
    fi

    tmpdir="$(mktemp -d)"
    archive="$tmpdir/otp_src_$otp_version.tar.gz"
    url="https://github.com/erlang/otp/releases/download/OTP-$otp_version/otp_src_$otp_version.tar.gz"

    curl -fsSL "$url" -o "$archive"
    tar -xzf "$archive" -C "$tmpdir"
    source_dir="$tmpdir/otp_src_$otp_version"
    jobs="${MAKE_JOBS:-$(nproc 2>/dev/null || printf '2')}"
    rm -rf "$otp_dir"
    mkdir -p "$(dirname "$otp_dir")"

    (
        cd "$source_dir"
        ./configure --prefix="$otp_dir" ${ERLANG_CONFIGURE_OPTIONS:---without-javac --without-wx}
        make -j"$jobs"
        make install
    )

    if [ ! -x "$otp_dir/bin/erl" ]; then
        echo "Erlang build completed, but $otp_dir/bin/erl was not installed." >&2
        exit 1
    fi

    rm -rf "$tmpdir"
}

install_elixir_stack() {
    local elixir_version installs_dir otp_version

    if [ ! -r "$repo_root/.tool-versions" ]; then
        echo "Missing $repo_root/.tool-versions; cannot determine pinned runtime." >&2
        exit 1
    fi

    elixir_version="$(read_tool_version elixir)"
    otp_version="$(read_tool_version erlang)"

    if [ -z "$elixir_version" ] || [ -z "$otp_version" ]; then
        echo "Could not read Elixir/Erlang versions from .tool-versions." >&2
        exit 1
    fi

    installs_dir="$HOME/.elixir-install/installs"

    if [ ! -x "$installs_dir/elixir/$elixir_version/bin/elixir" ] || \
       [ ! -x "$installs_dir/otp/$otp_version/bin/erl" ]; then
        install_erlang_from_source "$otp_version"
        install_elixir_release_zip "$elixir_version"
    fi

    export PATH="$installs_dir/otp/$otp_version/bin:$installs_dir/otp/$otp_version/erts-*/bin:$installs_dir/elixir/$elixir_version/bin:$PATH"
}

ensure_mix_helpers() {
    mix local.hex --force
    mix local.rebar --force
}

main() {
    require_arch_family

    if [ "$install_os_packages" -eq 1 ]; then
        install_packages
    fi

    if [ "$install_runtime" -eq 1 ]; then
        install_elixir_stack
    fi

    if command -v elixir >/dev/null 2>&1 && command -v erl >/dev/null 2>&1; then
        elixir --version
    else
        echo "Elixir/Erlang are not on PATH. Re-run without --no-runtime or export the pinned runtime PATH." >&2
        exit 1
    fi

    ensure_mix_helpers

    cd "$repo_root"

    if [ "$run_deps" -eq 1 ]; then
        mix deps.get
    fi

    if [ "$run_compile" -eq 1 ]; then
        mix compile
    fi

    if [ "$run_tests" -eq 1 ]; then
        MIX_ENV=test mix test
    fi

    echo "unfathomably-be Arch setup complete."
}

main "$@"

# end of build_scripts/setup-arch.sh
