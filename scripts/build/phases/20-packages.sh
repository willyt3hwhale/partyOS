# phase 20-packages - sourced by build-custom-image.sh; not standalone
# --- 3. install desktop environment + drivers + apps into the rootfs ---------
# Package set rationale (Step 3):
#   XFCE desktop ............ xfce4 (panel/wm/session), xfce4-settings
#   display manager ......... lightdm + greeter (autologin target)
#   browser ................. none baked: Epiphany installs on first use
#                             from the LAN mirror (catalog row, source=pkg)
#   file manager ............ thunar (ships in xfce4 but list explicitly)
#   X stack / SW render ..... xorg-server, xorg-xinit, mesa (llvmpipe SW GL so
#                             a desktop renders in a VM with no GPU passthrough)
#   graphics DRIVERS ........ xf86-video-amdgpu, xf86-video-ati,
#                             xf86-video-intel, xf86-video-nouveau,
#                             nvidia (proprietary), vulkan-radeon,
#                             vulkan-intel, intel-media-driver, mesa-vdpau
#   network/chipset ......... networkmanager, network-manager-applet
# These satisfy "ALL graphics drivers (AMD/NVIDIA/Intel) + common network/chipset
# drivers" by PRESENCE; accel itself is a physical smoke-test (documented).
PKGS=(
  xfce4 xfce4-settings xfce4-terminal thunar
  xfce4-whiskermenu-plugin
  # xfce4-notifyd: the notification daemon that owns org.freedesktop.Notifications
  # in the session, so notify-send (used by partyos-notify-poll for operator
  # broadcasts) actually renders a toast instead of no-opping. It is a member of the
  # xfce4 group already, but list it explicitly so the broadcast path can never lose
  # its daemon to a group change. Its toasts are override-redirect / non-focus-
  # stealing, so a broadcast never tabs a player out of a fullscreen game.
  xfce4-notifyd
  # Away-from-keyboard: split roles. xscreensaver = the SAVER + DPMS engine only
  # (classic Win95-style hacks: 3D pipes, flying toasters, ...; lock:False always).
  # The LOCKER is our own custom GTK3/PAM app (/usr/local/bin/partyos-lock-screen) that
  # renders the exact Win95 "Welcome to Windows" logon dialog by leaning on the active
  # Chicago95 GTK theme; python-gobject+gtk3 give it the Gtk-3.0 typelib, python-cairo
  # the drawing backend, xss-lock bridges X idle -> the gated locker. The lock engages
  # ONLY when the player set a password (else just the saver, never a lockout).
  xscreensaver
  python-gobject gtk3 python-cairo xss-lock
  # NOTE: do NOT add gvfs - its metadata backend does not work on the RAM/overlay
  # home (metadata::* is "not supported"), so it can't mark .desktop launchers
  # trusted, AND its volume monitor leaks the host's real disks onto the desktop.
  # exfatprogs gives fsck.exfat so safe-eject can check the exFAT share FAT before
  # the player removes the stick (the cross-OS exFAT share has no journal). Tiny.
  exfatprogs
  plymouth
  bubblewrap
  lightdm lightdm-gtk-greeter
  xorg-server xorg-xinit xorg-xrandr
  # HEADLESS render path: under TCG emulation there is no GPU / no /dev/dri, so
  # NONE of the real xf86-video-* GPU drivers can drive a screen. xf86-video-dummy
  # is a pure-software framebuffer Xorg driver that needs no DRM device, so LightDM
  # can start a real X session headlessly. xorg-server-xvfb is the belt-and-braces
  # virtual-framebuffer X server the Step 3 boot script uses headlessly if Xorg
  # itself can't come up under emulation. On a KVM/physical host virtio-gpu or a
  # real GPU driver renders instead (the accelerated bonus path).
  xf86-video-dummy xorg-server-xvfb
  mesa
  zenity
  networkmanager
  ttf-dejavu
  # aria2: BitTorrent client for the P2P-only blob path (torrent + tracker swarm + LSD
  # peers). get_blob uses it; there is NO HTTP blob fallback (P2P only).
  aria2
  # Load-from-URL share-code feature: mktorrent generates the .torrent for a cached
  # blob that lacks one (RAM-cache pull), xclip copies the share code to the X
  # clipboard so the player can paste it into Signal / a chat. Both are tiny.
  mktorrent xclip
  # graphics drivers. Intel/AMD use the in-kernel open drivers (tiny). For NVIDIA we
  # ship the PROPRIETARY driver: nouveau HANGS the boot on Ampere (RTX 30xx) and
  # gives no accel, so nouveau is OFF (nouveau.modeset=0 + blacklist) and `nvidia`
  # drives NVIDIA cards -> native resolution + 3D acceleration (needed for games +
  # Proton). `nvidia` is the prebuilt module matched to the baked `linux` kernel (same
  # snapshot), so no DKMS. Cost: ~0.5GB added to the boot transfer.
  xf86-video-amdgpu xf86-video-ati xf86-video-intel
  nvidia nvidia-utils
  vulkan-radeon vulkan-intel vulkan-mesa-layers
  intel-media-driver libva-mesa-driver mesa-vdpau
  # AUDIO: full PipeWire stack - the Arch default and it speaks the PulseAudio
  # protocol via pipewire-pulse, so the existing libpulse game/Proton path reaches it
  # with no extra plumbing. wireplumber is the session manager (default-sink policy).
  # pipewire-alsa/pipewire-audio route the onboard sof-hda-dsp + HDMI cards. The panel
  # gets a volume tray (xfce4-pulseaudio-plugin) wired to pavucontrol as the mixer.
  pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-audio
  xfce4-pulseaudio-plugin pavucontrol
)

# --- REVOKED-SIGNER snapshot packages (operator-trusted) ---------------------
# A handful of 2025/09 snapshot packages were signed by an Arch dev key that Arch
# later REVOKED (heftig, jan.steffens). The latest keyring carries that revocation,
# and a revocation is ABSOLUTE (faked-time can't rescue it), so these packages can
# NEVER pass SigLevel=Required. They are dependency-closure of pavucontrol (the panel
# mixer) via the gtkmm4/glibmm/pangomm C++ chain, so they ARE needed. Handle them as
# the operator-trusted (transport-trusted) class: pre-install them via `pacman -U`
# (LocalFileSigLevel=Optional) BEFORE the Required group install, so the group install
# finds them already satisfied and still GPG-verifies all the OTHER packages. They are
# also moved to [partyos-local] (Never) at runtime (see the repo-split section).
# Keep this list MINIMAL - only genuinely-unverifiable revoked-signer packages.
REVOKED_SIGNER_PKGS=(
  "extra/cairomm-1.16-1.18.0-1-x86_64.pkg.tar.zst"
  "extra/libsigc++-3.0-3.6.0-1-x86_64.pkg.tar.zst"
)
echo "[build] pre-installing ${#REVOKED_SIGNER_PKGS[@]} revoked-signer snapshot package(s) as operator-trusted (-U)..."
_RSARGS=""
for _rp in "${REVOKED_SIGNER_PKGS[@]}"; do
  _bn="$(basename "${_rp}")"
  _url="https://archive.archlinux.org/repos/${SNAPSHOT}/${_rp%%/*}/os/x86_64/${_bn}"
  if curl --retry 5 --retry-all-errors -fsSL "${_url}" -o "${ROOTFS}/var/cache/pacman/pkg/${_bn}" 2>/dev/null; then
    _RSARGS="${_RSARGS} /var/cache/pacman/pkg/${_bn}"
  else
    echo "[build] WARN could not fetch revoked-signer pkg ${_bn} (group install may pull it under Required and fail)"
  fi
done
if [ -n "${_RSARGS}" ]; then
  # First refresh the db so -U can pull any missing deps of these 2 (themselves
  # Required-verified). LocalFileSigLevel=Optional lets the 2 -U files install unsigned.
  arch-chroot "${ROOTFS}" /bin/bash -c "set -e; pacman -Sy --noconfirm; pacman -U --noconfirm --needed ${_RSARGS}" 2>&1 | tail -8
fi

echo "[build] installing ${#PKGS[@]} package groups into rootfs (pinned snapshot)..."
# --dbpath points at the rootfs's own pacman db so dependency resolution sees
# what archiso already installed (no reinstalling the world). arch-chroot gives
# a working /dev,/proc,/sys + resolv for download.
arch-chroot "${ROOTFS}" /bin/bash -c "
  set -e
  # Refresh against the pinned snapshot only. SigLevel=Required (set above) +
  # the populated keyring mean these snapshot packages are GPG-verified as they
  # install, so a tampered build mirror can't slip a package in either. The 2
  # revoked-signer packages above were already satisfied via -U, so --needed skips
  # them here and every OTHER package is still signature-verified.
  pacman -Sy --noconfirm
  # Install desktop+drivers. --needed skips anything already present. Do NOT
  # pass -u: we must not upgrade the kernel and break the kept initramfs.
  pacman -S --noconfirm --needed ${PKGS[*]}
" 2>&1 | tail -25

echo "[build] package install complete"

# The custom Win95 PAM locker (partyos-lock-screen) is a python3+PyGObject app, so
# its runtime deps MUST survive into the rootfs - if any is missing the locker can't start
# and a passworded rig would have no way to lock (the supervisor fails closed, but the
# player loses the lock). Assert the Gtk-3.0 GIR typelib, the python3 interpreter, libpam
# (ctypes auth) and xss-lock (idle bridge) are all present before continuing.
for _need in \
  "/usr/lib/girepository-1.0/Gtk-3.0.typelib" \
  "/usr/lib/girepository-1.0/Gdk-3.0.typelib" \
  "/usr/bin/python3" \
  "/usr/bin/xss-lock"; do
  [ -e "${ROOTFS}${_need}" ] || { echo "[build] FATAL: locker dependency missing in rootfs: ${_need}"; exit 1; }
done
ls "${ROOTFS}"/usr/lib/libpam.so* >/dev/null 2>&1 \
  || { echo "[build] FATAL: libpam.so missing in rootfs - the Win95 locker can't authenticate"; exit 1; }
echo "[build] verified Win95 locker deps (Gtk-3.0 typelib, python3, libpam, xss-lock)"

# --- bake a build-id so an in-session report names the EXACT image -----------
# A player-filed report (/usr/local/bin/partyos-report) is only actionable if we
# know which image build it came from. There is no per-image id in the rootfs
# otherwise (arch/version is the static archiso label), so stamp one now: a UTC
# build timestamp + the host that built it + a short content-ish suffix. Every
# client that boots THIS sfs reads the same /etc/partyos-build-id, so a report
# pins down the build. Plain key=value text, trivial to grep at triage.
PARTYOS_BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%s' "${HOSTNAME:-build}" | tr -cd 'A-Za-z0-9' | cut -c1-12)"
{
  echo "BUILD_ID=${PARTYOS_BUILD_ID}"
  echo "BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "BUILT_ON=${HOSTNAME:-unknown}"
  echo "KERNEL=${KVER:-unknown}"
} > "${ROOTFS}/etc/partyos-build-id"
chmod 0644 "${ROOTFS}/etc/partyos-build-id"
echo "[build] baked /etc/partyos-build-id (${PARTYOS_BUILD_ID})"

# --- bake the pinned partyOS CA ------------------------------------------------
# The pinned private CA (ca/partyos-ca.crt, committed) is mounted at /ca by
# build-image.sh. The clients fetch over HTTPS (app catalog/blobs, the operator
# config hook, the pacman mirror, the portal, torrent web-seeds) and verify against
# THIS CA. Bake it two ways:
#   1. /etc/partyos/ca.pem - the explicit cacert the in-guest curls pass with --cacert.
#      The initramfs step (a5-eggs-splash-initramfs.sh) copies this same path into the
#      initramfs, so it must be in ${ROOTFS} before any initramfs regeneration.
#   2. the system trust store (anchors/ + update-ca-trust) - so pacman + aria2's libcurl
#      trust the CA without an explicit flag (no per-tool cert plumbing needed).
# The CA MUST exist at build time (committed). Fail clearly if the mount is missing.
CA_SRC="/ca/partyos-ca.crt"
[ -f "${CA_SRC}" ] || { echo "[build] FATAL: pinned CA not found at ${CA_SRC} (is ca/ mounted? run scripts/deploy/gen-ca.sh)"; exit 1; }
install -d -m0755 "${ROOTFS}/etc/partyos"
install -m0644 "${CA_SRC}" "${ROOTFS}/etc/partyos/ca.pem"
install -d -m0755 "${ROOTFS}/etc/ca-certificates/trust-source/anchors"
install -m0644 "${CA_SRC}" "${ROOTFS}/etc/ca-certificates/trust-source/anchors/partyos-ca.crt"
# Rebuild the system trust bundle inside the rootfs so pacman/aria2/libcurl pick up the
# anchor. update-ca-trust is best-effort under amd64-on-arm emulation; if it can't run,
# the explicit --cacert /etc/partyos/ca.pem on the in-guest curls still authenticates.
if arch-chroot "${ROOTFS}" update-ca-trust 2>/dev/null; then
    echo "[build] baked partyOS CA: /etc/partyos/ca.pem + system trust anchor (update-ca-trust ran)"
else
    echo "[build] baked partyOS CA: /etc/partyos/ca.pem + anchor (update-ca-trust skipped under emulation; --cacert still covers curl)"
fi

# --- install the patched Thunar (local .desktop launchers trusted) -----------
# Stock Thunar 4.20 only shows a .desktop's Name= when it is gvfs-metadata
# "trusted" - impossible on the RAM home, so category-folder launchers show the
# raw "Foo.desktop" filename. scripts/build/build-thunar-patched.sh builds a
# thunar whose thunar_file_load/can_execute trust any LOCAL .desktop. Install it
# over stock if present (built separately; warn but continue if absent).
PATCHED_THUNAR="$(ls /scripts/thunar-patched/thunar-*.pkg.tar.zst 2>/dev/null | head -1)"
if [ -n "${PATCHED_THUNAR}" ] && [ -s "${PATCHED_THUNAR}" ]; then
  _tpkg="$(basename "${PATCHED_THUNAR}")"
  # stage into the rootfs pacman cache then -U from INSIDE the chroot (a host /tmp
  # path is not visible to arch-chroot's pacman).
  install -Dm644 "${PATCHED_THUNAR}" "${ROOTFS}/var/cache/pacman/pkg/${_tpkg}"
  arch-chroot "${ROOTFS}" /bin/bash -c "pacman -U --noconfirm --overwrite '*' '/var/cache/pacman/pkg/${_tpkg}'" 2>&1 | tail -4
  _tv="$(arch-chroot "${ROOTFS}" pacman -Q thunar 2>/dev/null)"
  case "${_tv}" in
    *-99) echo "[build] installed PATCHED Thunar (local .desktop trusted): ${_tv}";;
    *) echo "[build] ERROR patched Thunar did not take (still '${_tv}')"; exit 1;;
  esac
else
  echo "[build] WARN no patched Thunar at /scripts/thunar-patched/ - using stock (folder launchers show .desktop)"
fi

