#!/usr/bin/env bash
# build-image.sh - HOST orchestrator for the partyOS custom OS image (Step 3).
#
# Runs scripts/build/build-custom-image.sh inside an archlinux:latest
# (linux/amd64) Docker container. macOS has no pacman/chroot, so the Linux
# rootfs surgery (install XFCE+drivers, configure autologin, re-squash) happens
# in the container. Output lands in server/images/custom/:
#   airootfs.sfs            the custom squashfs the server serves for Step 3
#   pkglist.x86_64.txt      installed-package list (Step 3 presence assertion)
#   airootfs.sha512         integrity checksum
#
# Reproducible: pinned to the 2025.09 Arch archive snapshot (SNAPSHOT), so the
# package versions match the existing kernel/initramfs and never bump it.
#
# Idempotent-ish: re-running rebuilds from the stock sfs. Skips if the output
# already exists unless FORCE=1.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
SNAPSHOT="${SNAPSHOT:-2025/09/01}"
IMAGE="${ARCH_IMAGE:-archlinux:latest}"

STOCK_SFS="${REPO_ROOT}/server/images/airootfs.sfs"
OUT_DIR="${REPO_ROOT}/server/images/custom"
OUT_SFS="${OUT_DIR}/arch/x86_64/airootfs.sfs"

[ -f "${STOCK_SFS}" ] || { echo "ERROR: stock sfs not found: ${STOCK_SFS}" >&2; exit 1; }

if [ -f "${OUT_SFS}" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "[build] custom image already present: ${OUT_SFS}"
    echo "[build] (set FORCE=1 to rebuild)"
    exit 0
fi

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon not running" >&2; exit 1; }

mkdir -p "${OUT_DIR}"

# Build workspace: the ~2.5GB Linux rootfs MUST live on the Docker VM's ext4
# overlay, NOT a macOS host bind mount - APFS is case-insensitive (filename
# collisions like xt_CONNMARK.h vs xt_connmark.h) and lacks xattr support, both
# of which break unsquashing a real Linux rootfs. A named docker VOLUME gives a
# case-sensitive, xattr-capable filesystem with the VM's full free space.
WORK_VOL="${BUILD_WORK_VOL:-partyos-build-work}"
docker volume create "${WORK_VOL}" >/dev/null
# Clean any leftover rootfs from a previous run so we start fresh.
docker run --rm --platform linux/amd64 -v "${WORK_VOL}:/build" \
    "${IMAGE}" /bin/bash -c 'rm -rf /build/rootfs' >/dev/null 2>&1 || true

echo "[build] building custom image in ${IMAGE} (amd64), snapshot=${SNAPSHOT}"
echo "[build] stock sfs : ${STOCK_SFS}"
echo "[build] output    : ${OUT_DIR}"
echo "[build] work vol  : ${WORK_VOL} (docker volume, case-sensitive ext4)"

# The pinned partyOS CA. The build bakes ca/partyos-ca.crt into the rootfs
# (/etc/partyos/ca.pem + the system trust store) so the HTTPS runtime fetches trust
# it. It MUST exist (it's committed) - fail loudly if it's missing so a build never
# silently ships an image with no CA (the HTTPS runtime fetches would then fail).
CA_SRC="${REPO_ROOT}/ca/partyos-ca.crt"
[ -f "${CA_SRC}" ] || { echo "ERROR: pinned CA not found: ${CA_SRC} (run scripts/deploy/gen-ca.sh)" >&2; exit 1; }

# Mounts:
#   server/images        -> /in   (read-only: stock airootfs.sfs)
#   custom output dir    -> /out
#   build script dir     -> /scripts (read-only)
#   ca/                  -> /ca  (read-only: the pinned partyOS CA, baked into rootfs)
#   docker volume        -> /build (the big rootfs - on the VM's ext4, not APFS)
# --privileged is needed for arch-chroot's bind mounts of /dev,/proc,/sys.
docker run --rm --platform linux/amd64 --privileged \
    -e SNAPSHOT="${SNAPSHOT}" \
    -v "${REPO_ROOT}/server/images:/in:ro" \
    -v "${REPO_ROOT}/boot:/boot-src:ro" \
    -v "${REPO_ROOT}/server/games/icons:/game-icons:ro" \
    -v "${REPO_ROOT}/ca:/ca:ro" \
    -v "${OUT_DIR}:/out" \
    -v "${SELF_DIR}:/scripts:ro" \
    -v "${WORK_VOL}:/build" \
    "${IMAGE}" \
    /bin/bash /scripts/build-custom-image.sh

echo "[build] custom image ready:"
ls -lh "${OUT_DIR}"
