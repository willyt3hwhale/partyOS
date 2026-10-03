#!/usr/bin/env bash
# inspect-usbhome.sh - IN-CONTAINER reader for the virtual USB home image
# (Step 5 host-side verification). Runs inside archlinux:latest
# (linux/amd64); the host wrapper (scripts/vm/inspect-usbhome.sh) invokes it via
# Docker because macOS cannot mount/read ext4.
#
# It does NOT mount the filesystem (Docker-on-Mac cannot loop-mount partitions
# reliably): it uses debugfs to read a single file out of the ext4 image, which
# is exactly how build-usbhome.sh already verifies its seed. This lets the host
# independently confirm that the guest's RAM->USB sync actually landed the file
# on the stick.
#
# Inputs (env):
#   IMG      path (inside container) to the RAW ext4 image  (/work/usbhome.img)
#   FILE     path of the file to read, relative to fs root   (.partyos-sync-token)
# Output: the file contents on stdout, prefixed with a marker line; non-zero if
# the file is absent.
set -euo pipefail

IMG="${IMG:-/work/usbhome.img}"
FILE="${FILE:-.partyos-sync-token}"

# Install e2fsprogs only when debugfs is missing (the Arch-container path); on a
# native Linux host that already has debugfs, skip pacman (which isn't present).
if ! command -v debugfs >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed e2fsprogs >/dev/null 2>&1 || {
        grep -q '^DisableSandbox$' /etc/pacman.conf || \
            sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
        pacman -Sy --noconfirm --needed e2fsprogs >/dev/null
    }
fi

[ -f "${IMG}" ] || { echo "INSPECT-ERROR: no image ${IMG}" >&2; exit 2; }

echo "[inspect] === ext4 root listing ==="
debugfs -R "ls -l /" "${IMG}" 2>/dev/null || true

# Read the requested file via debugfs 'cat' (no mount). debugfs prints the raw
# bytes; capture them to a temp file so we can detect emptiness/absence.
OUT="$(mktemp)"
if debugfs -R "cat /${FILE}" "${IMG}" > "${OUT}" 2>/dev/null && [ -s "${OUT}" ]; then
    echo "INSPECT-FOUND ${FILE}:"
    cat "${OUT}"
    echo
    rm -f "${OUT}"
    exit 0
fi
echo "INSPECT-MISSING ${FILE}" >&2
rm -f "${OUT}"
exit 1
