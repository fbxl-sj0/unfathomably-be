#!/usr/bin/env bash
# Unfathomably secure FFmpeg installer
#
# File: install-secure-ffmpeg.sh
#
# Purpose:
#   Build and install a signed upstream FFmpeg maintenance release when the
#   operating-system package has not yet received a required security fix.
#
# Responsibilities:
#   - download FFmpeg source and detached signature from ffmpeg.org
#   - verify the official release-signing fingerprint
#   - build ffmpeg and ffprobe under a versioned prefix
#   - atomically select the new binaries through /usr/local/bin
#
# This file intentionally does not install compiler packages or remove distro
# FFmpeg libraries used by unrelated applications.

set -euo pipefail

VERSION="${1:-6.1.6}"
PREFIX="${2:-/opt/ffmpeg-${VERSION}}"
SIGNING_FINGERPRINT="FCF986EA15E6E293A5644F10B4322F04D67658D8"
ARCHIVE="ffmpeg-${VERSION}.tar.xz"
BASE_URL="https://ffmpeg.org/releases"

for command in curl gpg tar make cc nasm; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'Required build command is missing: %s\n' "${command}" >&2
    exit 1
  fi
done

if [ "$(id -u)" -ne 0 ]; then
  printf 'Run this installer as root so it can write %s and /usr/local/bin.\n' "${PREFIX}" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d -t unfathomably-ffmpeg.XXXXXXXX)"
trap 'rm -rf -- "${WORK_DIR}"' EXIT

export GNUPGHOME="${WORK_DIR}/gnupg"
mkdir -m 0700 "${GNUPGHOME}"

curl --fail --location --proto '=https' --tlsv1.2 \
  "https://ffmpeg.org/ffmpeg-devel.asc" -o "${WORK_DIR}/ffmpeg-devel.asc"
curl --fail --location --proto '=https' --tlsv1.2 \
  "${BASE_URL}/${ARCHIVE}" -o "${WORK_DIR}/${ARCHIVE}"
curl --fail --location --proto '=https' --tlsv1.2 \
  "${BASE_URL}/${ARCHIVE}.asc" -o "${WORK_DIR}/${ARCHIVE}.asc"

gpg --batch --import "${WORK_DIR}/ffmpeg-devel.asc" >/dev/null 2>&1

ACTUAL_FINGERPRINT="$(
  gpg --batch --with-colons --fingerprint "${SIGNING_FINGERPRINT}" |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"

if [ "${ACTUAL_FINGERPRINT}" != "${SIGNING_FINGERPRINT}" ]; then
  printf 'FFmpeg signing-key fingerprint mismatch.\n' >&2
  exit 1
fi

gpg --batch --verify "${WORK_DIR}/${ARCHIVE}.asc" "${WORK_DIR}/${ARCHIVE}"
tar -C "${WORK_DIR}" -xf "${WORK_DIR}/${ARCHIVE}"

cd "${WORK_DIR}/ffmpeg-${VERSION}"
./configure \
  --prefix="${PREFIX}" \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --enable-pic

PROCESSOR_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
MAKE_JOBS="${MAKE_JOBS:-${PROCESSOR_COUNT}}"

if ! [[ "${MAKE_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'MAKE_JOBS must be a positive integer.\n' >&2
  exit 1
fi

make -j"${MAKE_JOBS}"
make install

ln -sfn "${PREFIX}/bin/ffmpeg" /usr/local/bin/ffmpeg
ln -sfn "${PREFIX}/bin/ffprobe" /usr/local/bin/ffprobe

/usr/local/bin/ffmpeg -version | head -n 1
/usr/local/bin/ffprobe -version | head -n 1

# end of install-secure-ffmpeg.sh
