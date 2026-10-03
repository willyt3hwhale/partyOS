#!/usr/bin/env bash
# build-custom-image.sh - IN-CONTAINER builder for the partyOS custom OS image.
# Runs inside an archlinux:latest (linux/amd64) container; the
# host orchestrator scripts/build/build-image.sh invokes it.
#
# Strategy (reproducible, preserves the proven stock archiso boot chain):
#   1. Take the stock archiso airootfs.sfs (already a full Arch live system whose
#      initramfs + archiso live hooks RAM-boot over HTTP) and unsquash it into a
#      rootfs. We do NOT rebuild the kernel/initramfs - we keep the exact ones
#      the stock archiso boots, so the live PXE/copytoram machinery is untouched.
#   2. pacman -S the desktop + driver packages INTO that rootfs, pinned to the
#      same 2025.09 snapshot the image was built from (archive.archlinux.org) so
#      we never upgrade the kernel (would desync /usr/lib/modules vs initramfs)
#      and every package version is deterministic.
#   3. Layer the partyOS config: user 'gamer', LightDM autologin -> XFCE, a
#      browser + file manager, and an XFCE autostart entry that emits the
#      'desktop-ready' serial marker + HTTP callback (the autonomous "the desktop
#      came up" channel).
#   4. mksquashfs the result back to airootfs.sfs and emit a pkglist for the test.
#
# Inputs (env / mounted paths inside the container):
#   /in/airootfs.sfs   stock squashfs (read-only bind from server/images)
#   /out               output dir (bind) - gets airootfs.sfs + pkglist + sha
#   SNAPSHOT           archive.archlinux.org date (default 2025/09/01)
set -euo pipefail

SNAPSHOT="${SNAPSHOT:-2025/09/01}"
IN_SFS="/in/airootfs.sfs"
OUT_DIR="/out"
ROOTFS="/build/rootfs"
REPORT_HELPER="/in/desktop-ready.sh"   # baked into the image as the autostart cmd

echo "[build] === partyOS custom image build ==="
echo "[build] snapshot=${SNAPSHOT}"


# ---- thin driver: source the ordered phase modules + install baked files -----
# Source the ordered phase modules under phases/, then install files/rootfs via files/rootfs.manifest.
SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PHASE_DIR="${SELF_DIR}/phases"
FILES="${SELF_DIR}/files"
MANIFEST="${FILES}/rootfs.manifest"

# bake <rootfs-relative-path>: install a static file from files/rootfs into the
# target rootfs. The manifest sets mode and owner; the `chown -R` build steps set home-dir ownership.
bake() {
  local rel="$1" row mode owner
  row="$(awk -F'\t' -v p="$rel" '$1==p{print $2"\t"$3; exit}' "${MANIFEST}")"
  [ -n "${row}" ] || { echo "[build] bake: no manifest entry for '${rel}'" >&2; exit 1; }
  mode="${row%%$'\t'*}"; owner="${row#*$'\t'}"
  install -D -m "${mode}" "${FILES}/rootfs/${rel}" "${ROOTFS}/${rel}"
  chown "${owner}" "${ROOTFS}/${rel}"
}

for _phase in \
  00-common 10-rootfs-base 20-packages 25-strip 30-base-config \
  40-identity 45-usbhome-sync 50-net-provision 55-home-services \
  60-appstore-games 70-report-notify 75-desktop-tools 80-diagnostics \
  85-repo-runtime 90-launch-web-chat 95-desktop-theme \
  a0-lock a5-eggs-splash-initramfs b0-ram-seed b5-desktop-ready \
  c0-finalize ; do
  # shellcheck source=/dev/null
  source "${PHASE_DIR}/${_phase}.sh"
done
