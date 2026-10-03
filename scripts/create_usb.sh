#!/bin/bash
# Script to create a bootable partyOS iPXE USB.
#
# Two modes:
#   Physical:  ./create_usb.sh /dev/sdX [ipxe_efi]
#       Flashes the iPXE image to a real USB stick (dd). Interactive confirm.
#       Used for actual event deployment. [ipxe_efi] defaults to the https CA-baked
#       EFI built by scripts/deploy/setup.sh; pass a path only to override it.
#   Image:     ./create_usb.sh --image OUT.img
#       Writes the iPXE bootable USB to a raw disk IMAGE instead of a device.
#       Non-interactive, no root, no hardware - this is what the VM harness boots
#       (run-client.sh --ipxe-disk). The image auto-chains partyos.ipxe via the
#       DHCP boot filename (option 67) supplied by the virtual network, the same
#       way the physical stick does on a real LAN.
#
# Both paths share the same iPXE image fetch/cache logic so the image mode truly
# exercises create_usb.sh rather than a separate code path.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# iPXE source image (stock USB image). Cached so repeat/offline runs are
# deterministic; cache dir is git-ignored (*.usb).
IPXE_URL="${IPXE_URL:-https://boot.ipxe.org/ipxe.usb}"
IPXE_CACHE="${IPXE_CACHE:-${PROJECT_DIR}/server/images/ipxe.usb}"

fetch_ipxe() {
    # Populate $1 with the iPXE image, using the cache when present.
    local dest="$1"
    if [ -s "${IPXE_CACHE}" ]; then
        echo "Using cached iPXE image: ${IPXE_CACHE}"
        cp "${IPXE_CACHE}" "${dest}"
        return 0
    fi
    echo "Downloading iPXE boot image from ${IPXE_URL}..."
    mkdir -p "$(dirname "${IPXE_CACHE}")"
    curl -fL -o "${IPXE_CACHE}" "${IPXE_URL}"
    cp "${IPXE_CACHE}" "${dest}"
}

# --- USB HOME image mode (non-interactive, for VM tests - Step 4) ------
# Builds a removable USB *home* image: an MBR disk with one ext4 partition
# LABELLED 'LANPARTY_HOME', seeded with files that should appear in
# /home/gamer. This is the in-VM stand-in for a player's physical home stick.
# macOS has no mkfs.ext4/partitioning, so the ext4 build runs in the same
# archlinux:latest (linux/amd64) Docker container used for the custom image;
# we convert the resulting raw image to qcow2 (run-client.sh --usb expects
# qcow2). Non-interactive, no root on the host, no hardware.
#
#   ./create_usb.sh --image-home OUT.qcow2 [size_mb] [seed_tag] [username] [hostname]
# The optional [username] (or USERNAME env) writes a `.partyos` config at the
# home root so the OS logs in as that account instead of 'gamer' (Step: dynamic
# identity). The optional [hostname] (or HOSTNAME env) adds a HOSTNAME= line so
# the OS uses it verbatim instead of deriving <username>-<machine-suffix>. Omit
# the username and the stick boots as 'gamer' (backward compatible).
if [ "$1" = "--image-home" ]; then
    OUT="${2:?usage: create_usb.sh --image-home OUT.qcow2 [size_mb] [seed_tag] [username] [hostname]}"
    IMG_MB="${3:-256}"
    SEED_TAG="${4:-partyos-step4}"
    USERNAME="${5:-${USERNAME:-}}"
    HOSTNAME_CFG="${6:-${HOSTNAME:-}}"
    IMAGE="${ARCH_IMAGE:-archlinux:latest}"

    BUILD_DIR="${SCRIPT_DIR}/build"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/partyos-usbhome.XXXXXX")"

    if command -v mkfs.ext4 >/dev/null 2>&1; then
        # Native Linux host: build the ext4 image directly,
        # no Docker needed. mkfs.ext4 -d populates without mounting/root.
        echo "Building virtual USB home image (ext4 LANPARTY_HOME, ${IMG_MB}MB) natively..."
        OUT_DIR="${WORK}" IMG_MB="${IMG_MB}" SEED_TAG="${SEED_TAG}" USERNAME="${USERNAME}" HOSTNAME="${HOSTNAME_CFG}" \
            SEED_SERVICE="${SEED_SERVICE:-}" SVC_NAME="${SVC_NAME:-}" SVC_PORT="${SVC_PORT:-}" \
            HOME_SUBDIR="${HOME_SUBDIR:-}" \
            /bin/bash "${BUILD_DIR}/build-usbhome.sh"
    else
        # macOS / no native mkfs.ext4: build inside a Linux container.
        command -v docker >/dev/null 2>&1 || { echo "ERROR: docker required for --image-home (no native mkfs.ext4)" >&2; exit 1; }
        docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon not running" >&2; exit 1; }
        echo "Building virtual USB home image (ext4 LANPARTY_HOME, ${IMG_MB}MB) in ${IMAGE}..."
        # --privileged: losetup -P / loop devices need it. Mount the build scripts
        # read-only and a scratch dir as /out for the produced raw image.
        docker run --rm --platform linux/amd64 --privileged \
            -e IMG_MB="${IMG_MB}" -e SEED_TAG="${SEED_TAG}" -e USERNAME="${USERNAME}" -e HOSTNAME="${HOSTNAME_CFG}" \
            -e SEED_SERVICE="${SEED_SERVICE:-}" -e SVC_NAME="${SVC_NAME:-}" -e SVC_PORT="${SVC_PORT:-}" \
            -e HOME_SUBDIR="${HOME_SUBDIR:-}" \
            -v "${BUILD_DIR}:/scripts:ro" \
            -v "${WORK}:/out" \
            "${IMAGE}" \
            /bin/bash /scripts/build-usbhome.sh
    fi

    RAW="${WORK}/usbhome.img"
    [ -f "${RAW}" ] || { echo "ERROR: container did not produce ${RAW}" >&2; rm -rf "${WORK}"; exit 1; }

    echo "Converting raw -> qcow2: ${OUT}"
    QEMU_IMG="${QEMU_IMG:-$(command -v qemu-img || echo /opt/homebrew/bin/qemu-img)}"
    "${QEMU_IMG}" convert -f raw -O qcow2 "${RAW}" "${OUT}"
    rm -rf "${WORK}"
    echo "USB home image ready: ${OUT} ($(du -h "${OUT}" | cut -f1))"
    echo "Attach in a VM with: run-client.sh --usb ${OUT}"
    exit 0
fi

# --- TWO-PARTITION USB image mode ---------------------------------------
# Builds a CROSS-OS participant VM test stick mirroring the PRODUCTION stick's DATA
# partitions (the netbooted VM image omits the ESP): an MBR disk with TWO partitions -
#   p1  ext4   'LANPARTY_HOME' - the Linux home; `.partyos` config + blob cache at
#              the partition ROOT, the user home tree under a `home/` SUBDIR.
#   p2  exFAT  'PARTYSHARE'     - universally readable (Win/mac/Linux) cross-OS share
#              (mounted at /mnt/share / ~/Shared); holds certs + portable files.
# The OS reads `.partyos` from the ext4 ROOT; the home mount/sync uses the ext4
# home/ subdir; the exFAT partition is the share. Same Docker/native split as
# --image-home (macOS has no mkfs.ext4/mkfs.exfat/sfdisk). Produces a qcow2.
#
#   ./create_usb.sh --image-home-split OUT.qcow2 [home_mb] [seed_tag] [username] [hostname] [share_mb]
if [ "$1" = "--image-home-split" ]; then
    OUT="${2:?usage: create_usb.sh --image-home-split OUT.qcow2 [home_mb] [seed_tag] [username] [hostname] [share_mb]}"
    IMG_MB="${3:-256}"
    SEED_TAG="${4:-partyos-usbsplit}"
    USERNAME="${5:-${USERNAME:-}}"
    # ${6-...} (no colon) only substitutes when arg 6 is UNSET, so an explicitly
    # passed empty hostname stays empty (does NOT leak the host's $HOSTNAME env).
    HOSTNAME_CFG="${6-${HOSTNAME:-}}"
    # arg 7 is the exFAT PARTYSHARE size (build-usbsplit reads it as SHARE_MB; CFG_MB
    # is kept only as a back-compat env alias).
    CFG_MB="${7:-${CFG_MB:-64}}"
    IMAGE="${ARCH_IMAGE:-archlinux:latest}"

    BUILD_DIR="${SCRIPT_DIR}/build"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/partyos-usbsplit.XXXXXX")"

    if command -v mkfs.ext4 >/dev/null 2>&1 && command -v mkfs.exfat >/dev/null 2>&1 && command -v sfdisk >/dev/null 2>&1; then
        # Native Linux host with all fs tooling: build directly.
        echo "Building two-partition USB image (ext4 LANPARTY_HOME + exFAT PARTYSHARE) natively..."
        OUT_DIR="${WORK}" IMG_MB="${IMG_MB}" SHARE_MB="${CFG_MB}" SEED_TAG="${SEED_TAG}" \
            USERNAME="${USERNAME}" HOSTNAME="${HOSTNAME_CFG}" \
            /bin/bash "${BUILD_DIR}/build-usbsplit.sh"
    else
        # macOS / missing native tooling: build inside a Linux container. --privileged
        # is required for the whole-file loop mount that seeds the exFAT partition.
        command -v docker >/dev/null 2>&1 || { echo "ERROR: docker required for --image-home-split" >&2; exit 1; }
        docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon not running" >&2; exit 1; }
        echo "Building two-partition USB image (ext4 LANPARTY_HOME + exFAT PARTYSHARE) in ${IMAGE}..."
        docker run --rm --platform linux/amd64 --privileged \
            -e IMG_MB="${IMG_MB}" -e SHARE_MB="${CFG_MB}" -e SEED_TAG="${SEED_TAG}" \
            -e USERNAME="${USERNAME}" -e HOSTNAME="${HOSTNAME_CFG}" \
            -v "${BUILD_DIR}:/scripts:ro" \
            -v "${WORK}:/out" \
            "${IMAGE}" \
            /bin/bash /scripts/build-usbsplit.sh
    fi

    RAW="${WORK}/usbsplit.img"
    [ -f "${RAW}" ] || { echo "ERROR: builder did not produce ${RAW}" >&2; rm -rf "${WORK}"; exit 1; }

    echo "Converting raw -> qcow2: ${OUT}"
    QEMU_IMG="${QEMU_IMG:-$(command -v qemu-img || echo /opt/homebrew/bin/qemu-img)}"
    "${QEMU_IMG}" convert -f raw -O qcow2 "${RAW}" "${OUT}"
    rm -rf "${WORK}"
    echo "Two-partition USB image ready: ${OUT} ($(du -h "${OUT}" | cut -f1))"
    echo "Attach in a VM with: run-client.sh --usb ${OUT}"
    exit 0
fi

# --- Image mode (non-interactive, for VM tests) ----------------------------
if [ "$1" = "--image" ]; then
    OUT="${2:?usage: create_usb.sh --image OUT.img}"
    echo "Building iPXE USB IMAGE at ${OUT}"
    fetch_ipxe "${OUT}"
    SIZE=$(wc -c < "${OUT}")
    echo "iPXE USB image ready: ${OUT} (${SIZE} bytes)"
    echo "Boot it in a VM with: run-client.sh --ipxe-disk ${OUT} \\"
    echo "    --bootfile http://<server>:8080/boot/partyos.ipxe"
    exit 0
fi

# --- THE party stick (the ONLY device mode) --------------------------------
# A real partyOS stick is never boot-only or home-only. ONE device that BOTH boots
# iPXE AND carries the player's home + blob cache + a cross-OS share. THREE partitions:
#   p1 ESP (the custom iPXE .efi)
#   p3 exFAT PARTYDATA - cross-platform (Win/mac/Linux) share for internyet.env,
#      certs + files, mounted in-session at ~/Shared
#   p2 ext4 PARTYOSHOME (fills the rest) - blob cache + sync state at the partition
#      ROOT, plus a home/ subdir that backs the RAM /home/<user> (rsync'd).
# This is the layout of the venue sticks: the same labels, the same order on the
# disk (p1, then p3, then p2 at the tail). The OS's partyos-usbhome.service mounts
# the home partition at /mnt/usbhome and the share at /mnt/share. It finds them by
# label (partyos-usb-labels.sh), so it also accepts the legacy labels
# (LANPARTY_HOME, PARTYSHARE). HOME_LABEL and SHARE_LABEL override the labels.
# (The image builders above - --image / --image-home / --image-home-split - are VM
# test plumbing that simulate the one stick with separate virtual disks. They keep
# the legacy labels, which the client still accepts.)
if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 <device> [ipxe_efi] [esp_mb] [share_mb]"
    echo "  Makes THE partyOS stick: p1 ESP (iPXE) + p3 exFAT PARTYDATA + p2 ext4 PARTYOSHOME. ERASES the device."
    echo "  ipxe_efi defaults to build/ipxe-custom-https.efi (the https, CA-baked, server-IP-baked iPXE"
    echo "  built by scripts/deploy/setup.sh). FORCE=1 skips the prompt."
    echo "  esp_mb defaults to 512, share_mb defaults to 4096 (the exFAT cross-OS share)."
    echo "  Example: sudo $0 /dev/sdb"
    exit 1
fi
DEVICE="$1"
# Default to the https, CA-baked, server-IP-baked iPXE EFI (built by setup.sh). The
# 2nd positional is an explicit EFI-path override only (e.g. the plain-http EFI).
EFI="${2:-${PROJECT_DIR}/build/ipxe-custom-https.efi}"
ESP_MB="${3:-512}"
SHARE_MB="${4:-4096}"
# The venue labels. The client also accepts the legacy labels.
HOME_LABEL="${HOME_LABEL:-PARTYOSHOME}"
SHARE_LABEL="${SHARE_LABEL:-PARTYDATA}"
[[ "${DEVICE}" =~ ^/dev/(sd[a-z]|nvme[0-9]n[0-9]|mmcblk[0-9]|disk[0-9]+|loop[0-9]+)$ ]] \
    || { echo "refusing: ${DEVICE} doesn't look like a removable device" >&2; exit 1; }
# Missing EFI -> point the operator at setup.sh, which mints the CA + bakes the
# server IP into this EFI. (A passed-in override path that is missing fails here too.)
[ -f "${EFI}" ] || { echo "iPXE EFI not found at ${EFI} - run scripts/deploy/setup.sh first to build it (or pass a path)" >&2; exit 1; }
command -v mkfs.exfat >/dev/null 2>&1 || { echo "mkfs.exfat not found - install exfatprogs" >&2; exit 1; }
echo "WARNING: this ERASES ${DEVICE} -> p1 ESP(iPXE) + p3 exFAT ${SHARE_LABEL} + p2 ext4 ${HOME_LABEL}"
[ "${FORCE:-0}" = 1 ] || { read -p "Continue? (y/N): " c; [[ "${c}" =~ ^[Yy]$ ]] || { echo aborted; exit 0; }; }
# nvme/mmc/loop devices need a 'p' before the partition number; sdX doesn't
case "${DEVICE}" in *[0-9]) P="${DEVICE}p";; *) P="${DEVICE}";; esac
sudo umount "${DEVICE}"* 2>/dev/null || true
sudo sgdisk --zap-all "${DEVICE}" >/dev/null
# p1 ESP first (512M), p3 SHARE next (+share_mb), p2 HOME fills the rest. The
# partition NUMBERS (1/2/3) are independent of on-device order; we lay p2 last so
# it grabs the tail, the same as the venue sticks.
sudo sgdisk -n "1:0:+${ESP_MB}M"     -t 1:EF00 -c 1:ESP \
            -n "3:0:+${SHARE_MB}M"   -t 3:0700 -c "3:${SHARE_LABEL}" \
            -n 2:0:0                 -t 2:8300 -c "2:${HOME_LABEL}" "${DEVICE}" >/dev/null
sudo partprobe "${DEVICE}" 2>/dev/null || true; sleep 2
sudo mkfs.vfat -F32 -n PARTYOS "${P}1" >/dev/null
_t="$(mktemp -d)"; sudo mount "${P}1" "${_t}"; sudo mkdir -p "${_t}/EFI/BOOT"
sudo cp "${EFI}" "${_t}/EFI/BOOT/BOOTX64.EFI"; sudo sync; sudo umount "${_t}"; rmdir "${_t}"
sudo mkfs.exfat -L "${SHARE_LABEL}" "${P}3" >/dev/null
sudo mkfs.ext4 -F -L "${HOME_LABEL}" "${P}2" >/dev/null
echo "partyOS stick ready on ${DEVICE}:"
echo "  p1 ESP (PARTYOS, BOOTX64.EFI=$(basename "${EFI}"))  +  p3 exFAT ${SHARE_LABEL}  +  p2 ext4 ${HOME_LABEL}"
echo "  boots iPXE; the OS mounts ${HOME_LABEL} at /mnt/usbhome (home + blob cache) and ${SHARE_LABEL} at /mnt/share (~/Shared)."