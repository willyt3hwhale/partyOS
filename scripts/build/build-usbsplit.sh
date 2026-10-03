#!/usr/bin/env bash
# build-usbsplit.sh - IN-CONTAINER builder for the THREE-PARTITION participant USB
# VM test image. Runs inside an archlinux:latest (linux/amd64) container; the host
# wrapper create_usb.sh invokes it. macOS has no mkfs.ext4 / mkfs.exfat /
# partitioning tools, so the filesystems + table are built in Linux.
#
# This mirrors the PRODUCTION 3-partition stick (create_usb.sh) for VM testing:
#   p2  ext4   LABEL 'LANPARTY_HOME' - the Linux home partition. Identity (.partyos)
#              + blob cache live at the partition ROOT; the user home tree lives in a
#              `home/` SUBDIR (which the image's partyos-home-pull seeds + mirrors to
#              the RAM /home/<user>).
#   p3  exFAT  LABEL 'PARTYSHARE' - cross-OS readable (Win/mac/Linux) share; the
#              image mounts it at /mnt/share (~/Shared). Holds certs + files.
# (The production stick additionally has p1 ESP for iPXE; the VM test boots over the
# network, so this image carries only the data partitions.)
#
# The OS reads `.partyos` from the ext4 ROOT (config-finder); the home pull/push
# uses p2:/home. A single-ext4 stick still boots - the home falls back to the root.
#
# HOW it is assembled WITHOUT loop-partition support: Docker-on-Mac's kernel does
# not enumerate partition nodes (losetup -P is a no-op), so we cannot mkfs a
# partition device. Instead we build each filesystem as its own raw image:
#   - ext4  via `mkfs.ext4 -d` (populates at creation, no mount) - same as
#     build-usbhome.sh, factored out below.
#   - exFAT via mkfs.exfat on a raw file, then a WHOLE-FILE loop mount (which DOES
#     work in the container) to copy `.partyos` + portable data in.
# then `dd` both filesystem images into an MBR-partitioned disk at the right
# offsets (partition types 0x07 exFAT, 0x83 Linux). blkid on the assembled disk's
# partition offsets then reports the right TYPE for each, which the host test
# asserts.
#
# Output: a raw image at /out/usbsplit.img which the host wrapper converts to
# qcow2 (run-client.sh attaches USB drives as format=qcow2).
#
# Inputs (env):
#   IMG_MB       ext4 home partition size in MB           (default 256)
#   SHARE_MB     exFAT PARTYSHARE partition size in MB (default 64)
#   SEED_TAG     marker baked into the seed files         (default partyos-usbsplit)
#   USERNAME     if set, write `.partyos` (USERNAME=..) at the ext4 ROOT.
#                Empty -> no `.partyos` (boots as 'gamer', backward compatible).
#   HOSTNAME     if set (with USERNAME), add HOSTNAME=.. to `.partyos`. Optional.
set -euo pipefail

OUT_DIR="${OUT_DIR:-/out}"
RAW="${OUT_DIR}/usbsplit.img"
IMG_MB="${IMG_MB:-256}"
# CFG_MB kept as a back-compat alias for SHARE_MB (the exFAT partition's size).
SHARE_MB="${SHARE_MB:-${CFG_MB:-64}}"
SEED_TAG="${SEED_TAG:-partyos-usbsplit}"
USERNAME="${USERNAME:-}"
HOSTNAME_CFG="${HOSTNAME:-}"
HOME_LABEL="LANPARTY_HOME"
SHARE_LABEL="PARTYSHARE"

echo "[usbsplit] === building 3-partition-style participant USB image ==="
echo "[usbsplit] ext4=${IMG_MB}MB (${HOME_LABEL}, config at root + home/ subdir) + exFAT=${SHARE_MB}MB (${SHARE_LABEL}) seed_tag=${SEED_TAG}"

# --- tooling ----------------------------------------------------------------
need_pkgs=()
command -v mkfs.ext4 >/dev/null 2>&1   || need_pkgs+=(e2fsprogs)
command -v mkfs.exfat >/dev/null 2>&1  || need_pkgs+=(exfatprogs)
command -v sfdisk >/dev/null 2>&1      || need_pkgs+=(util-linux)
if [ "${#need_pkgs[@]}" -gt 0 ]; then
    pacman -Sy --noconfirm --needed "${need_pkgs[@]}" >/dev/null 2>&1 || {
        grep -q '^DisableSandbox$' /etc/pacman.conf || \
            sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
        pacman -Sy --noconfirm --needed "${need_pkgs[@]}" >/dev/null
    }
fi

# Privilege helper: loop-mounting the exFAT image to seed it needs root. Inside
# the Docker container (mac path) we already run as root, so SUDO is empty. On a
# native non-root host (e.g. a KVM host, where this runs under `sg kvm` as the user)
# fall back to sudo if it is available passwordlessly.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        SUDO="sudo -n"
    fi
fi

WORK="$(mktemp -d)"
EXT4_IMG="${WORK}/home.ext4"
EXFAT_IMG="${WORK}/share.exfat"

# --- 1. stage the ext4 partition tree: config at ROOT + home/ subdir ---------
# The ext4 partition holds the identity (.partyos) + blob cache at the partition
# ROOT (read before any home exists), and the user home tree under a `home/`
# SUBDIR (which the image's partyos-home-pull seeds + mirrors to /home/<user>).
EXT4SEED="$(mktemp -d)"
mkdir -p "${EXT4SEED}/home" "${EXT4SEED}/.partyos-cache/games"
# config at the ROOT (only when USERNAME is set; else boots as 'gamer').
if [ -n "${USERNAME}" ]; then
    {
        echo "# partyOS per-stick config (parsed, not executed). KEY=value, # comments."
        echo "USERNAME=${USERNAME}"
        [ -n "${HOSTNAME_CFG}" ] && echo "HOSTNAME=${HOSTNAME_CFG}"
    } > "${EXT4SEED}/.partyos"
    echo "[usbsplit] wrote .partyos at ext4 ROOT with USERNAME=${USERNAME}${HOSTNAME_CFG:+ HOSTNAME=${HOSTNAME_CFG}}"
else
    echo "[usbsplit] no USERNAME -> no .partyos at ext4 root (boots as gamer)"
fi
# home/ content (mirrors the proven step5/6 seed tree). The image's first-boot seed
# guard ONLY fires when home/ is empty, so to exercise the PULL path we DO populate
# home/ here (this stick is "already provisioned"). An EMPTY home/ would instead
# exercise the build-skel seed path.
mkdir -p "${EXT4SEED}/home/Documents" "${EXT4SEED}/home/.config/partyos"
printf '%s welcome\n' "${SEED_TAG}" > "${EXT4SEED}/home/WELCOME.txt"
printf '%s document\n' "${SEED_TAG}" > "${EXT4SEED}/home/Documents/notes.txt"
printf '%s dotfile\n' "${SEED_TAG}" > "${EXT4SEED}/home/.config/partyos/settings.conf"
echo "${SEED_TAG}-$(date +%s)-$RANDOM" > "${EXT4SEED}/home/.partyos-home-token"

# --- 2. format the ext4 home image (populate without mounting) ---------------
dd if=/dev/zero of="${EXT4_IMG}" bs=1M count="${IMG_MB}" status=none
mkfs.ext4 -q -F -L "${HOME_LABEL}" -d "${EXT4SEED}" "${EXT4_IMG}"
rm -rf "${EXT4SEED}"
echo "[usbsplit] built ext4 ${HOME_LABEL} (${IMG_MB}MB, config at root + home/ subdir)"

# --- 3. stage the exFAT PARTYSHARE seed tree ------------------------------
# The cross-OS share: certs + portable files, mounted at /mnt/share (~/Shared).
SHARESEED="$(mktemp -d)"
mkdir -p "${SHARESEED}/certs"
echo "${SEED_TAG} portable-readme: this partition is exFAT, readable on Windows/macOS/Linux." \
    > "${SHARESEED}/README.txt"
echo "place per-stick certs here (cross-OS share, mounts at ~/Shared)" \
    > "${SHARESEED}/certs/.keep"
SHARE_TOKEN="${SEED_TAG}-share-$(date +%s)-$RANDOM"
echo "${SHARE_TOKEN}" > "${SHARESEED}/.partyos-share-token"

# --- 4. format the exFAT share image + populate via whole-file loop mount ----
dd if=/dev/zero of="${EXFAT_IMG}" bs=1M count="${SHARE_MB}" status=none
mkfs.exfat -L "${SHARE_LABEL}" "${EXFAT_IMG}" >/dev/null
EXMNT="$(mktemp -d)"
if ${SUDO} mount -o loop "${EXFAT_IMG}" "${EXMNT}" 2>/dev/null; then
    # exFAT has no unix ownership, so use cp -r (NOT -a/-p which tries to preserve
    # ownership and fails on exfat). Content + names are all the test reads back.
    ${SUDO} cp -r "${SHARESEED}/." "${EXMNT}/"
    ${SUDO} sync
    ${SUDO} umount "${EXMNT}"
    echo "[usbsplit] populated exFAT ${SHARE_LABEL} (${SHARE_MB}MB) via loop mount${SUDO:+ (sudo)}"
else
    echo "[usbsplit] ERROR: could not loop-mount exFAT image to seed it (need root/sudo or kernel exfat module)" >&2
    rm -rf "${WORK}" "${SHARESEED}" "${EXMNT}"
    exit 1
fi
rm -rf "${SHARESEED}" "${EXMNT}"

# --- 5. assemble the MBR-partitioned disk ------------------------------------
# Layout (1MiB-aligned): p1 ext4 (LANPARTY_HOME), p2 exFAT (PARTYSHARE). 1MiB
# reserved at the front for the MBR + alignment, plus a 1MiB tail slack. The image
# discovers both partitions by LABEL, so partition order/number is functional only
# for the offset-based blkid checks below.
ALIGN_MB=1
HOME_START_MB=${ALIGN_MB}
SHARE_START_MB=$(( HOME_START_MB + IMG_MB ))
TOTAL_MB=$(( SHARE_START_MB + SHARE_MB + ALIGN_MB ))

dd if=/dev/zero of="${RAW}" bs=1M count="${TOTAL_MB}" status=none

# sfdisk works on the whole-disk image (no partition enumeration needed - it only
# writes the partition TABLE in the MBR). Sizes/starts in 512-byte sectors.
sectors_per_mb=2048
home_start=$(( HOME_START_MB * sectors_per_mb ))
home_size=$(( IMG_MB * sectors_per_mb ))
share_start=$(( SHARE_START_MB * sectors_per_mb ))
share_size=$(( SHARE_MB * sectors_per_mb ))
sfdisk "${RAW}" >/dev/null <<SFD
label: dos
${home_start},${home_size},83
${share_start},${share_size},7
SFD
echo "[usbsplit] wrote MBR: p1 ext4 @${HOME_START_MB}MiB +${IMG_MB}MiB, p2 exFAT @${SHARE_START_MB}MiB +${SHARE_MB}MiB"

# Splice each filesystem image into its partition slot (conv=notrunc preserves the
# table written by sfdisk; seek is in MiB blocks).
dd if="${EXT4_IMG}"  of="${RAW}" bs=1M seek="${HOME_START_MB}"  conv=notrunc status=none
dd if="${EXFAT_IMG}" of="${RAW}" bs=1M seek="${SHARE_START_MB}" conv=notrunc status=none
echo "[usbsplit] spliced ext4 + exFAT filesystems into partitions"

rm -rf "${WORK}"

# --- 6. verify the table + filesystem types (offset-based blkid) -------------
echo "[usbsplit] partition table:"
sfdisk -d "${RAW}" 2>/dev/null || true
echo "[usbsplit] ext4 partition blkid (offset ${HOME_START_MB}MiB):"
blkid -o export -O "$(( HOME_START_MB * 1024 * 1024 ))" "${RAW}" 2>/dev/null || true
echo "[usbsplit] exFAT partition blkid (offset ${SHARE_START_MB}MiB):"
blkid -o export -O "$(( SHARE_START_MB * 1024 * 1024 ))" "${RAW}" 2>/dev/null || true

echo "[usbsplit] raw image ready: $(du -h "${RAW}" | cut -f1)"
echo "[usbsplit] === DONE ==="
