#!/usr/bin/env bash
# inspect-usbhome.sh (HOST wrapper) - read a file out of the virtual USB home
# qcow2 from the host, for Step 5 verification. macOS cannot mount ext4, so
# this converts the qcow2 to raw and runs scripts/build/inspect-usbhome.sh inside
# the same archlinux:latest (linux/amd64) Docker container the image was built
# in, using debugfs (no loop mount).
#
# Usage:
#   inspect-usbhome.sh QCOW2 [FILE]
# Prints the file contents (with an INSPECT-FOUND marker) and exits 0 if present,
# non-zero otherwise.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

QCOW2="${1:?usage: inspect-usbhome.sh QCOW2 [FILE]}"
FILE="${2:-.partyos-sync-token}"
IMAGE="${ARCH_IMAGE:-archlinux:latest}"
BUILD_DIR="${REPO_ROOT}/scripts/build"

[ -f "${QCOW2}" ] || { echo "INSPECT-ERROR: no qcow2 ${QCOW2}" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/partyos-inspect.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# qcow2 -> raw so debugfs (which speaks plain block devices) can read the ext4.
"${QEMU_IMG}" convert -f qcow2 -O raw "${QCOW2}" "${WORK}/usbhome.img"

if command -v debugfs >/dev/null 2>&1; then
    # Native Linux host: read the ext4 directly with debugfs,
    # no Docker. Same logic as the in-container reader.
    IMG="${WORK}/usbhome.img" FILE="${FILE}" /bin/bash "${BUILD_DIR}/inspect-usbhome.sh"
else
    # macOS / no native debugfs: read it inside the Linux container.
    command -v docker >/dev/null 2>&1 || { echo "INSPECT-ERROR: docker or debugfs required" >&2; exit 2; }
    docker info >/dev/null 2>&1 || { echo "INSPECT-ERROR: docker daemon not running" >&2; exit 2; }
    docker run --rm --platform linux/amd64 \
        -e IMG="/work/usbhome.img" -e FILE="${FILE}" \
        -v "${BUILD_DIR}:/scripts:ro" \
        -v "${WORK}:/work" \
        "${IMAGE}" \
        /bin/bash /scripts/inspect-usbhome.sh
fi
