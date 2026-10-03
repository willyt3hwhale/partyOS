#!/usr/bin/env bash
# build-usbhome.sh - IN-CONTAINER builder for the virtual USB home image.
# Runs inside an archlinux:latest (linux/amd64) container; the
# host wrapper create_usb.sh (--image-home) invokes it. macOS has no mkfs.ext4
# / partitioning tools, so the ext4 LANPARTY_HOME filesystem is built in Linux.
#
# It produces a removable USB disk image (the in-VM stand-in for a player's
# physical home stick) that run-client.sh attaches with --usb:
#   - a whole-disk ext4 filesystem (a USB stick formatted without a partition
#     table - the kernel exposes it as e.g. /dev/sda directly). Docker-on-Mac
#     cannot loop-mount partitions inside a privileged container (losetup -P
#     does not enumerate partition nodes), so we format the whole image;
#     label-based discovery (blkid / mount LABEL=) is identical either way.
#   - the filesystem is LABELLED 'LANPARTY_HOME' (the label the boot-time mount
#     service finds the home stick by)
#   - seeded with a few recognisable files under what becomes /home/gamer, so
#     the test can assert "files from USB appear in /home/gamer"
#
# Output: a raw image at /out/usbhome.img which the host wrapper converts to
# qcow2 (run-client.sh attaches USB drives as format=qcow2).
#
# Inputs (env):
#   IMG_MB     ext4 home image size in MB              (default 256)
#   SEED_TAG   marker string baked into the seed files (default partyos-step4)
#   USERNAME   if set, write a `.partyos` config at the home root with
#              USERNAME=<value> (the desktop account name the image reads). If
#              empty/unset, NO `.partyos` is written - the stick boots as the
#              default 'gamer' (backward compatible).
#   HOSTNAME   if set (and USERNAME is set, since .partyos is only written then),
#              add a HOSTNAME=<value> line so the OS uses it verbatim instead of
#              deriving <username>-<machine-suffix>. Optional.
#   SEED_SERVICE  if set, seed a dummy home service under
#              ~/.partyos-services/ (start services from home): an executable
#              launcher that binds a TCP port and writes a marker file into the
#              home, so a boot test can prove the user's own service auto-started
#              from their home folder. SVC_PORT (default 8099) + SVC_NAME (default
#              partysvc) tune it.
#   HOME_SUBDIR  if set to 1, lay the home tree under a `home/` SUBDIR of the ext4
#              partition (mirroring the PRODUCTION 3-partition stick + build-usbsplit),
#              keeping `.partyos` + `.partyos-cache` at the partition ROOT. This is
#              the layout the BAKED partyos-home-pull/partyos-sync-home expect
#              (USB_HOME=/mnt/usbhome/home). Used by the sync and hot-plug tests that exercise
#              the baked units. Unset (default) keeps the legacy FLAT layout (home
#              tree at the partition root) that the home, home-service and blob-cache tests read.
set -euo pipefail

OUT_DIR="${OUT_DIR:-/out}"
RAW="${OUT_DIR}/usbhome.img"
IMG_MB="${IMG_MB:-256}"
SEED_TAG="${SEED_TAG:-partyos-step4}"
USERNAME="${USERNAME:-}"
HOSTNAME_CFG="${HOSTNAME:-}"
SEED_SERVICE="${SEED_SERVICE:-}"
SVC_NAME="${SVC_NAME:-partysvc}"
SVC_PORT="${SVC_PORT:-8099}"
HOME_SUBDIR="${HOME_SUBDIR:-}"
LABEL="LANPARTY_HOME"

echo "[usbhome] === building virtual USB home image ==="
echo "[usbhome] size=${IMG_MB}MB label=${LABEL} seed_tag=${SEED_TAG}"

# Tooling: e2fsprogs gives mkfs.ext4 + the -d flag to populate the fs at build
# time WITHOUT mounting it (no loop device needed - works under Docker-on-Mac).
# When run natively on a Linux host that already has mkfs.ext4, skip pacman
# (which only exists in the Arch container path).
if ! command -v mkfs.ext4 >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed e2fsprogs >/dev/null 2>&1 || {
        grep -q '^DisableSandbox$' /etc/pacman.conf || \
            sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
        pacman -Sy --noconfirm --needed e2fsprogs >/dev/null
    }
fi

# --- 1. allocate the raw disk image ----------------------------------------
rm -f "${RAW}"
dd if=/dev/zero of="${RAW}" bs=1M count="${IMG_MB}" status=none
echo "[usbhome] allocated ${IMG_MB}MB raw image: ${RAW}"

# --- 2. stage the seed home tree --------------------------------------------
# The home stick holds the user's home tree. With HOME_SUBDIR=1 it lives under a
# `home/` SUBDIR (the production / baked-pull layout); otherwise it sits at the
# partition ROOT (the legacy flat layout the home tests read). `.partyos` +
# `.partyos-cache` always stay at the partition ROOT either way.
SEED="$(mktemp -d)"
if [ "${HOME_SUBDIR}" = "1" ]; then
    HOMEROOT="${SEED}/home"
    mkdir -p "${SEED}/.partyos-cache/games"
    # A concrete marker at the partition ROOT (alongside the blob cache) so the host
    # can prove the home --delete mirror of p2:/home never touched the p2 ROOT.
    echo "${SEED_TAG}-root-cache-$(date +%s)-$RANDOM" > "${SEED}/.partyos-cache/.partyos-cache-token"
    echo "[usbhome] HOME_SUBDIR=1 -> home tree under home/ subdir, config + cache at partition ROOT"
else
    HOMEROOT="${SEED}"
fi
mkdir -p "${HOMEROOT}/Documents" "${HOMEROOT}/.config/partyos"
printf '%s welcome\n' "${SEED_TAG}" > "${HOMEROOT}/WELCOME.txt"
printf '%s document\n' "${SEED_TAG}" > "${HOMEROOT}/Documents/notes.txt"
printf '%s dotfile\n' "${SEED_TAG}" > "${HOMEROOT}/.config/partyos/settings.conf"
# A unique token file the test greps for to prove THIS image's data landed.
echo "${SEED_TAG}-$(date +%s)-$RANDOM" > "${HOMEROOT}/.partyos-home-token"

# Optional `.partyos` config file at the home root: the single per-stick config
# the OS parses on boot. Only written when USERNAME is set, so a stick WITHOUT
# it boots as 'gamer' (backward compatible). Format is plain KEY=value lines
# (parsed, never sourced) - extensible for future keys (HOSTNAME, THEME, ...).
if [ -n "${USERNAME}" ]; then
    {
        echo "# partyOS per-stick config (parsed, not executed). KEY=value, # comments."
        echo "USERNAME=${USERNAME}"
        [ -n "${HOSTNAME_CFG}" ] && echo "HOSTNAME=${HOSTNAME_CFG}"
    } > "${SEED}/.partyos"
    echo "[usbhome] wrote .partyos with USERNAME=${USERNAME}${HOSTNAME_CFG:+ HOSTNAME=${HOSTNAME_CFG}}"
else
    echo "[usbhome] no USERNAME set -> no .partyos written (boots as gamer)"
fi

# Optional dummy HOME SERVICE: a participant's own service that auto-starts
# on boot from their home folder. Seeded only when SEED_SERVICE is set; absent it,
# the home has no services dir and the boot hook is a clean no-op (which the test
# also asserts). The launcher binds a TCP port (proof it actually started) and
# writes a marker file carrying a unique token into the home (proof state lives
# in the home, owned by the user).
if [ -n "${SEED_SERVICE}" ]; then
    SVC_TOKEN="${SEED_TAG}-svc-$(date +%s)-$RANDOM"
    install -d "${HOMEROOT}/.partyos-services"
    cat > "${HOMEROOT}/.partyos-services/${SVC_NAME}.sh" <<SVC
#!/usr/bin/env bash
# Dummy home service seeded by build-usbhome.sh (test fixture). Run AS THE
# USER by partyos-home-services from ~/.partyos-services/. Writes a marker into
# the home, then binds a TCP port and answers it (so the test can prove the
# service is genuinely listening, owned by the user, state in the home).
set -u
SVC_NAME="${SVC_NAME}"
SVC_PORT="${SVC_PORT}"
TOKEN="${SVC_TOKEN}"
MARK="\${HOME}/.partyos-services/.run/\${SVC_NAME}.marker"
mkdir -p "\$(dirname "\${MARK}")"
{
  echo "service=\${SVC_NAME} token=\${TOKEN} user=\$(id -un) home=\${HOME} pid=\$\$ port=\${SVC_PORT}"
  echo "started=\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "\${MARK}"
# Mirror the marker to the serial console too (greppable proof from the guest).
# Only in a VM - a real laptop's /dev/ttyS0 has no draining reader and the write
# blocks for ~60s (see the SER=/dev/null guard the boot scripts use).
case "\$(systemd-detect-virt 2>/dev/null)" in none|"") : ;; *) echo "PARTYOS-HOMESVC-MARKER name=\${SVC_NAME} token=\${TOKEN} user=\$(id -un) home=\${HOME} port=\${SVC_PORT}" > /dev/ttyS0 2>/dev/null || true ;; esac
# Serve the token on the port forever (proves the service is up + reachable).
# Prefer a python one-liner (always present in the image); fall back to a bash
# /dev/tcp accept loop if not.
if command -v python3 >/dev/null 2>&1; then
  exec python3 - "\${SVC_PORT}" "\${TOKEN}" <<'PY'
import socket, sys
port = int(sys.argv[1]); token = sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(8)
while True:
    c, _ = s.accept()
    try:
        c.sendall(("partysvc-ok token=%s\n" % token).encode())
    except Exception:
        pass
    c.close()
PY
else
  # bash fallback: just stay alive holding the marker (no accept loop).
  while true; do sleep 30; done
fi
SVC
    chmod +x "${HOMEROOT}/.partyos-services/${SVC_NAME}.sh"
    echo "[usbhome] seeded home service ${SVC_NAME}.sh (port ${SVC_PORT}, token ${SVC_TOKEN})"
    # Record the token where the host can read it back if needed.
    echo "${SVC_TOKEN}" > "${HOMEROOT}/.partyos-services/${SVC_NAME}.token"
fi

# --- 3. format whole-disk ext4 with the LANPARTY_HOME label AND seed it ------
# mkfs.ext4 -d copies the seed tree into the new filesystem at creation time,
# so no mount / loop device is required (the part that fails under Docker-on-Mac).
mkfs.ext4 -q -F -L "${LABEL}" -d "${SEED}" "${RAW}"
echo "[usbhome] formatted whole-disk ext4 label=${LABEL}, seeded from ${SEED}"
rm -rf "${SEED}"

# --- 4. (verify) list what landed in the fs without mounting ----------------
echo "[usbhome] seeded files (debugfs listing of /):"
debugfs -R "ls -l /" "${RAW}" 2>/dev/null || true

echo "[usbhome] raw image ready: $(du -h "${RAW}" | cut -f1)"
echo "[usbhome] === DONE ==="
