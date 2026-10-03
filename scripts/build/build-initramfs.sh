#!/usr/bin/env bash
# build-initramfs.sh - HOST orchestrator that regenerates the SERVED initramfs.
#
# `make image` rebuilds only the squashfs; the served initramfs
# (server/images/initramfs-linux.img) is a SEPARATE artifact that must be
# regenerated whenever an initramfs hook or mkinitcpio drop-in changes - notably
# the FILES+=(/etc/partyos/ca.pem) drop-in that bundles the pinned CA and
# the archiso_pxe_http `--cacert` override. Without that, the all-HTTPS copytoram
# boot fails CLOSED.
#
# This runs scripts/build/slim-initramfs.sh inside a PRIVILEGED linux/amd64 Arch
# container (mount + chroot + mkinitcpio -g need privileges; macOS has no pacman /
# chroot), the same container style as build-image.sh. slim-initramfs.sh unsquashes
# the freshly-built sfs, honors the mkinitcpio drop-ins, and writes
# initramfs-linux.img.new. This script then installs that ATOMICALLY over the served
# initramfs (write to a temp on the same dir, then mv) and runs the guard
# (scripts/deploy/check-initramfs.sh) to self-verify the result is CA-pinned + fresh.
#
# Correct rebuild sequence: `make image && make initramfs` (or `make boot-artifacts`).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
IMAGE="${ARCH_IMAGE:-archlinux:latest}"

IMAGES_DIR="${REPO_ROOT}/server/images"
SFS="${IMAGES_DIR}/custom/arch/x86_64/airootfs.sfs"
SERVED="${IMAGES_DIR}/initramfs-linux.img"
GUARD="${REPO_ROOT}/scripts/deploy/check-initramfs.sh"

[ -f "${SFS}" ] || { echo "ERROR: custom sfs not found: ${SFS} (run \`make image\` first)" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon not running" >&2; exit 1; }

# Keep a backup of the currently-served (known-good) initramfs before we overwrite,
# so a bad regeneration can be rolled back instead of stranding the boot.
BAK="${SERVED}.bak-preverify"
if [ -f "${SERVED}" ]; then
    cp -p "${SERVED}" "${BAK}"
    echo "[initramfs] backed up current served initramfs -> ${BAK}"
fi

echo "[initramfs] regenerating in ${IMAGE} (amd64, privileged), honoring mkinitcpio drop-ins"
echo "[initramfs] sfs   : ${SFS}"
echo "[initramfs] output: ${SERVED}"

# slim-initramfs.sh runs from /srv: it reads custom/arch/x86_64/airootfs.sfs and
# writes /srv/initramfs-linux.img.new. Mount the images dir at /srv (rw for the
# .new), the build scripts read-only. --privileged for the chroot bind mounts.
docker run --rm --platform linux/amd64 --privileged \
    -v "${IMAGES_DIR}:/srv" \
    -v "${SELF_DIR}:/scripts:ro" \
    "${IMAGE}" \
    /bin/bash /scripts/slim-initramfs.sh

NEW="${IMAGES_DIR}/initramfs-linux.img.new"
[ -f "${NEW}" ] || { echo "ERROR: slim-initramfs produced no ${NEW}" >&2; exit 1; }

# Atomic install: tmp on the SAME directory (same filesystem) then mv over.
TMP="${SERVED}.tmp.$$"
cp "${NEW}" "${TMP}"
mv -f "${TMP}" "${SERVED}"
rm -f "${NEW}"
# Stamp it newer than the sfs so the freshness guard is satisfied right after a build.
touch "${SERVED}"
echo "[initramfs] installed atomically -> ${SERVED}"

# Self-verify with the guard. If it fails, roll back to the backup so we never
# leave a broken served initramfs in place.
if [ -f "${GUARD}" ]; then
    if bash "${GUARD}" "${SERVED}" "${SFS}"; then
        echo "[initramfs] guard PASSED - served initramfs is CA-pinned and fresh"
    else
        echo "ERROR: regenerated initramfs FAILED the guard" >&2
        if [ -f "${BAK}" ]; then
            mv -f "${BAK}" "${SERVED}"
            touch "${SERVED}"
            echo "ERROR: restored the previous good initramfs from ${BAK}" >&2
        fi
        exit 1
    fi
fi

echo "[initramfs] sha256: $( { shasum -a 256 "${SERVED}" 2>/dev/null || sha256sum "${SERVED}"; } | awk '{print $1}' )"
echo "[initramfs] done."
