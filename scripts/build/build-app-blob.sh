#!/usr/bin/env bash
# build-app-blob.sh - build a SELF-CONTAINED game/app blob for partyOS.
#
# partyOS clients are slim and have none of the game's deps, so a blob is a whole
# x86_64 rootfs (the game + its full dependency closure) that runs SANDBOXED via
# bubblewrap (bwrap, baked into the client base) - no deps installed on the client,
# no pollution. The blob mounts at ~/games/<name> (squashfs ro + tmpfs overlay,
# the existing Step 7 path) and partyos-app runs its bin/run.sh, which bwraps the
# rootfs and execs the game.
#
# Build runs in an amd64 Arch container pinned to the SAME 2025/09 snapshot as the
# client base (so the bundled libs match the kernel/abi the client ships).
#
# Usage:
#   build-app-blob.sh <name> <source:repo|aur> <pkgs> <exec> [title] [category] [id] [ram_min] [ram_max]
#     name     blob/file name (a-z0-9)
#     source   repo (pacman) | aur (makepkg, build deps installed in-container)
#     pkgs     space-separated package(s) to install into the rootfs (or AUR pkgbase)
#     exec     command to run inside the sandbox (e.g. "ddnet" or "java -jar /opt/x.jar")
#   Output: <OUT_DIR>/<name>.squashfs + .sha256, and the catalog row (catalog.v2.json)
#   updated with the real sha256/size; run build-game-blobs.sh after to regen catalog.json.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/server/games}"
SNAPSHOT="${SNAPSHOT:-2025/09/01}"
IMAGE="${ARCH_IMAGE:-archlinux:latest}"

NAME="${1:?name}"; SOURCE="${2:?source repo|aur}"; PKGS="${3:?pkgs}"; EXEC="${4:?exec}"
TITLE="${5:-${NAME}}"; CATEGORY="${6:-game}"; ID="${7:-partyos.${NAME}}"
RAM_MIN="${8:-512}"; RAM_MAX="${9:-2048}"

command -v docker >/dev/null || { echo "[appblob] ERROR docker required" >&2; exit 1; }
mkdir -p "${OUT_DIR}"
echo "[appblob] building '${NAME}' (${SOURCE}: ${PKGS}) exec='${EXEC}'" >&2

# The bin/run.sh baked into the blob: bwrap the rootfs (this mountpoint) + exec.
# $0 is <mount>/bin/run.sh, so the rootfs is one dir up.
RUNSH='#!/bin/bash
# partyOS self-contained blob launcher: bwrap this rootfs + run the game.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
U="$(id -u)"
args=( --ro-bind "$ROOT/usr" /usr --ro-bind "$ROOT/etc" /etc
       --symlink usr/lib /lib --symlink usr/lib /lib64 --symlink usr/bin /bin --symlink usr/bin /sbin
       --proc /proc --dev-bind /dev /dev --tmpfs /tmp --tmpfs /var/tmp
       --bind "$HOME" "$HOME" )
[ -d "$ROOT/opt" ] && args+=( --ro-bind "$ROOT/opt" /opt )
[ -d "$ROOT/var/lib" ] && args+=( --ro-bind "$ROOT/var/lib" /var/lib )
[ -d "$ROOT/srv" ] && args+=( --ro-bind "$ROOT/srv" /srv )
# Host /sys, read-only. The Mesa loader and the Mesa Vulkan drivers find the GPU
# with drmGetDevice2, which reads /sys/dev/char/<major>:<minor>. If /sys is absent,
# Mesa cannot identify the Intel or AMD GPU and falls back to llvmpipe. The nvidia
# driver does not use this path, so only Intel and AMD hosts showed the problem.
args+=( --ro-bind-try /sys /sys )
# real host identity + runtime sockets (X11, pulse/pipewire, dbus) so the game can
# look up the player + reach audio/display. These overlay the blob copies.
args+=( --ro-bind-try /etc/passwd /etc/passwd --ro-bind-try /etc/group /etc/group
        --ro-bind-try "/run/user/$U" "/run/user/$U" --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix
        --setenv HOME "$HOME" --setenv USER "$(id -un)"
        --setenv DISPLAY "${DISPLAY:-:0}" --setenv XAUTHORITY "${XAUTHORITY:-$HOME/.Xauthority}"
        --setenv XDG_RUNTIME_DIR "/run/user/$U" --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=/run/user/$U/bus"
        --setenv LIBGL_ALWAYS_SOFTWARE "${PARTYOS_SOFTWARE_GL:-0}"
        --die-with-parent --new-session )
# nvidia userspace passthrough (host-driver, conditional). The blob /usr ships mesa
# ONLY - no nvidia GL vendor - so on an nvidia host GLVND finds no nvidia provider
# and GL falls to the llvmpipe software rasterizer (openttd "no GPU", laggy STK).
# When the host has an nvidia GPU (/dev/nvidia0), bind its userspace GL/Vulkan stack
# into /nvidia and select the nvidia GLVND vendor so the game hits the real GPU.
# Skipped on non-nvidia hosts (blob mesa drives intel/amd; a GPU-less VM auto-falls
# to llvmpipe), so the software path stays intact. Mirrors build-baseenv-blob.sh so
# the game path matches the proton path.
# Hybrid graphics (PRIME). On a laptop the X screen can run on the Intel or AMD iGPU,
# and X loads the nvidia GPU only as a GPU screen (provider "NVIDIA-G0"). The nvidia
# GLX vendor then needs PRIME render offload. Without it the NV-GLX request fails
# with BadValue and the game exits at start. nv_prime_mode asks X for its providers:
#   offload - X has an NVIDIA-G* provider: nvidia vendor plus the PRIME offload env.
#   primary - nvidia drives the X screen, or X gives no answer: nvidia vendor only.
#   mesa    - X has providers but no nvidia one: use Mesa on the iGPU (DRI_PRIME).
nv_prime_mode() {
    local p=""
    p="$(timeout 5 xrandr --listproviders 2>/dev/null)" || p=""
    case "$p" in
        *name:NVIDIA-G*) echo offload ;;
        *name:NVIDIA*|"") echo primary ;;
        *) echo mesa ;;
    esac
}
# igpu_dri_prime prints the DRI_PRIME tag of the first Intel or AMD render node, for
# example "pci-0000_00_02_0". Mesa otherwise can open the nvidia node and fall back to
# llvmpipe.
igpu_dri_prime() {
    local r drv dev
    for r in /sys/class/drm/renderD*; do
        drv="$(basename "$(readlink -f "$r/device/driver" 2>/dev/null)" 2>/dev/null)"
        case "$drv" in
            i915|xe|amdgpu|radeon)
                dev="$(basename "$(readlink -f "$r/device")")"
                echo "pci-$(printf "%s" "$dev" | tr ":." "__")"
                return 0 ;;
        esac
    done
    return 1
}
NV_ICD=""
for icd in /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json; do
    [ -e "$icd" ] && { NV_ICD="$icd"; break; }
done
if [ -e /dev/nvidia0 ] && [ -n "$NV_ICD" ]; then
    NV_MODE="$(nv_prime_mode)"
    NVLIB=""
    for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu; do
        [ -e "$d/libGLX_nvidia.so.0" ] && { NVLIB="$d"; break; }
    done
    if [ "$NV_MODE" = mesa ]; then
        NVLIB=""
        IGPU="$(igpu_dri_prime)" && args+=( --setenv DRI_PRIME "$IGPU" )
    fi
    if [ -n "$NVLIB" ]; then
        for so in "$NVLIB"/libnvidia-*.so* \
                  "$NVLIB"/libGLX_nvidia.so* "$NVLIB"/libEGL_nvidia.so* \
                  "$NVLIB"/libGLESv1_CM_nvidia.so* "$NVLIB"/libGLESv2_nvidia.so* \
                  "$NVLIB"/libcuda.so* "$NVLIB"/libnvcuvid.so* "$NVLIB"/libnvoptix.so*; do
            [ -e "$so" ] && args+=( --ro-bind "$so" "/nvidia/$(basename "$so")" )
        done
        NVICD="$(mktemp)"
        printf "{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"/nvidia/libGLX_nvidia.so.0\",\"api_version\":\"1.4.0\"}}\n" > "$NVICD"
        args+=( --ro-bind "$NVICD" /nvidia/nvidia_icd.json
                --setenv VK_DRIVER_FILES /nvidia/nvidia_icd.json
                --setenv VK_ICD_FILENAMES /nvidia/nvidia_icd.json
                --setenv LD_LIBRARY_PATH /nvidia
                --setenv __GLX_VENDOR_LIBRARY_NAME nvidia )
        [ "$NV_MODE" = offload ] && args+=( --setenv __NV_PRIME_RENDER_OFFLOAD 1
                --setenv __VK_LAYER_NV_optimus NVIDIA_only )
    fi
fi
echo "PARTYOS-BLOB-RUN __NAME__ exec=__EXEC__"
exec bwrap "${args[@]}" __EXEC__ "$@"
'
# openra ships its own run.sh: it seeds the freeware Red Alert assets (baked
# read-only into /opt/openra-content at build time) into the player's WRITABLE
# $HOME on first launch, so OpenRA finds Content/ra/v2 populated and never opens
# the first-run content-download dialog (which crashes offline at the party).
# Mirrors the proton-blob prefix-template seed (build-proton-blob.sh:90-107).
if [ "${NAME}" = openra ]; then
RUNSH='#!/bin/bash
# partyOS openra blob launcher: seed freeware RA assets into HOME, bwrap + run.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
U="$(id -u)"
# First-run: copy the read-only baked Content tree into the writable, USB-synced
# HOME (OpenRA SupportDir = ~/.config/openra). cp -an = no-clobber so a player who
# later runs OpenRA own installer is not overwritten; the .ready sentinel guards
# against a crash mid-copy re-seeding (a partial copy leaves no sentinel -> redo).
DEST="$HOME/.config/openra/Content/ra/v2"
SRC="$ROOT/opt/openra-content/ra/v2"
if [ ! -f "$DEST/.partyos-content-ready" ] && [ -d "$SRC" ]; then
    mkdir -p "$DEST"
    cp -an "$SRC/." "$DEST/" && touch "$DEST/.partyos-content-ready"
fi
args=( --ro-bind "$ROOT/usr" /usr --ro-bind "$ROOT/etc" /etc
       --symlink usr/lib /lib --symlink usr/lib /lib64 --symlink usr/bin /bin --symlink usr/bin /sbin
       --proc /proc --dev-bind /dev /dev --tmpfs /tmp --tmpfs /var/tmp
       --bind "$HOME" "$HOME" )
[ -d "$ROOT/opt" ] && args+=( --ro-bind "$ROOT/opt" /opt )
[ -d "$ROOT/var/lib" ] && args+=( --ro-bind "$ROOT/var/lib" /var/lib )
[ -d "$ROOT/srv" ] && args+=( --ro-bind "$ROOT/srv" /srv )
# Host /sys, read-only, so Mesa can identify the GPU - see the base launcher above.
args+=( --ro-bind-try /sys /sys )
args+=( --ro-bind-try /etc/passwd /etc/passwd --ro-bind-try /etc/group /etc/group
        --ro-bind-try "/run/user/$U" "/run/user/$U" --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix
        --setenv HOME "$HOME" --setenv USER "$(id -un)"
        --setenv DISPLAY "${DISPLAY:-:0}" --setenv XAUTHORITY "${XAUTHORITY:-$HOME/.Xauthority}"
        --setenv XDG_RUNTIME_DIR "/run/user/$U" --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=/run/user/$U/bus"
        --setenv LIBGL_ALWAYS_SOFTWARE "${PARTYOS_SOFTWARE_GL:-0}"
        --die-with-parent --new-session )
# nvidia userspace passthrough (host-driver, conditional) - see the base launcher
# above. The blob /usr is mesa-only, so an nvidia host needs the host GL vendor bound
# in or GL drops to llvmpipe. Skipped on non-nvidia/GPU-less hosts (software intact).
# Hybrid graphics (PRIME). On a laptop the X screen can run on the Intel or AMD iGPU,
# and X loads the nvidia GPU only as a GPU screen (provider "NVIDIA-G0"). The nvidia
# GLX vendor then needs PRIME render offload. Without it the NV-GLX request fails
# with BadValue and the game exits at start. nv_prime_mode asks X for its providers:
#   offload - X has an NVIDIA-G* provider: nvidia vendor plus the PRIME offload env.
#   primary - nvidia drives the X screen, or X gives no answer: nvidia vendor only.
#   mesa    - X has providers but no nvidia one: use Mesa on the iGPU (DRI_PRIME).
nv_prime_mode() {
    local p=""
    p="$(timeout 5 xrandr --listproviders 2>/dev/null)" || p=""
    case "$p" in
        *name:NVIDIA-G*) echo offload ;;
        *name:NVIDIA*|"") echo primary ;;
        *) echo mesa ;;
    esac
}
# igpu_dri_prime prints the DRI_PRIME tag of the first Intel or AMD render node, for
# example "pci-0000_00_02_0". Mesa otherwise can open the nvidia node and fall back to
# llvmpipe.
igpu_dri_prime() {
    local r drv dev
    for r in /sys/class/drm/renderD*; do
        drv="$(basename "$(readlink -f "$r/device/driver" 2>/dev/null)" 2>/dev/null)"
        case "$drv" in
            i915|xe|amdgpu|radeon)
                dev="$(basename "$(readlink -f "$r/device")")"
                echo "pci-$(printf "%s" "$dev" | tr ":." "__")"
                return 0 ;;
        esac
    done
    return 1
}
NV_ICD=""
for icd in /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json; do
    [ -e "$icd" ] && { NV_ICD="$icd"; break; }
done
if [ -e /dev/nvidia0 ] && [ -n "$NV_ICD" ]; then
    NV_MODE="$(nv_prime_mode)"
    NVLIB=""
    for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu; do
        [ -e "$d/libGLX_nvidia.so.0" ] && { NVLIB="$d"; break; }
    done
    if [ "$NV_MODE" = mesa ]; then
        NVLIB=""
        IGPU="$(igpu_dri_prime)" && args+=( --setenv DRI_PRIME "$IGPU" )
    fi
    if [ -n "$NVLIB" ]; then
        for so in "$NVLIB"/libnvidia-*.so* \
                  "$NVLIB"/libGLX_nvidia.so* "$NVLIB"/libEGL_nvidia.so* \
                  "$NVLIB"/libGLESv1_CM_nvidia.so* "$NVLIB"/libGLESv2_nvidia.so* \
                  "$NVLIB"/libcuda.so* "$NVLIB"/libnvcuvid.so* "$NVLIB"/libnvoptix.so*; do
            [ -e "$so" ] && args+=( --ro-bind "$so" "/nvidia/$(basename "$so")" )
        done
        NVICD="$(mktemp)"
        printf "{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"/nvidia/libGLX_nvidia.so.0\",\"api_version\":\"1.4.0\"}}\n" > "$NVICD"
        args+=( --ro-bind "$NVICD" /nvidia/nvidia_icd.json
                --setenv VK_DRIVER_FILES /nvidia/nvidia_icd.json
                --setenv VK_ICD_FILENAMES /nvidia/nvidia_icd.json
                --setenv LD_LIBRARY_PATH /nvidia
                --setenv __GLX_VENDOR_LIBRARY_NAME nvidia )
        [ "$NV_MODE" = offload ] && args+=( --setenv __NV_PRIME_RENDER_OFFLOAD 1
                --setenv __VK_LAYER_NV_optimus NVIDIA_only )
    fi
fi
echo "PARTYOS-BLOB-RUN __NAME__ exec=__EXEC__"
echo "PARTYOS-APP-OPENRA-RAN"
exec bwrap "${args[@]}" __EXEC__ "$@"
'
fi
# ezquake: seed a WRITABLE Quake basedir in the player HOME, then gate the launch on
# the presence of game data. The engine is free software, the DATA is not: id Software
# lets anyone redistribute the SHAREWARE release (episode 1) but not the retail paks.
# So the blob bakes the whole shareware archive and the player supplies pak1.pak for
# the full game. Inserted before the marker line of the generic launcher, so the bwrap
# sandbox, the nvidia passthrough and the marker contract stay exactly as they are.
if [ "${NAME}" = ezquake ]; then
EZ_SEED='
# --- Quake data (partyOS) ---------------------------------------------------
# ezQuake reads its game data from a basedir and WRITES demos, downloads and
# screenshots back into it, so the read-only blob cannot be the basedir. Seed a
# writable copy in HOME, which syncs to the USB stick and survives the reboot.
QBASE="$HOME/quake"
mkdir -p "$QBASE"
if [ ! -f "$QBASE/.partyos-ezquake-ready" ] && [ -d "$ROOT/opt/quake" ]; then
    cp -an "$ROOT/opt/quake/." "$QBASE/" 2>/dev/null
    # the engine binary stays in the blob; do not keep a stale copy in HOME.
    rm -f "$QBASE/ezquake-linux-x86_64" 2>/dev/null
    touch "$QBASE/.partyos-ezquake-ready"
fi
# Seed the free SHAREWARE data as a whole (pak0.pak plus the id Software licence
# and readme files the shareware licence requires to travel with it). cp -an never
# clobbers a retail pak the player dropped in.
if [ ! -f "$QBASE/id1/pak0.pak" ] && [ -d "$ROOT/opt/quake-shareware" ]; then
    mkdir -p "$QBASE/id1"
    cp -an "$ROOT/opt/quake-shareware/." "$QBASE/" 2>/dev/null
fi
# No data at all: say so and stop. The engine would otherwise abort with a bare
# "cannot find id1/pak0.pak" on a console the player never sees.
if [ ! -f "$QBASE/id1/pak0.pak" ]; then
    NODATA="ezQuake has no Quake game data.
Copy pak0.pak (and pak1.pak) into:
    $QBASE/id1/
That folder is on your USB stick. Then start ezQuake again."
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="ezQuake" --width=460 --text="$NODATA" 2>/dev/null || true
    else
        printf "%s\n" "$NODATA"
    fi
    echo "PARTYOS-EZQUAKE-NO-DATA"
    exit 1
fi
# Seed the free deathmatch maps on EVERY launch, keyed on the files and not on the
# ready marker, so an old home gets them too. The GPL dm1-dm6 pack would shadow the
# retail maps, so skip it when pak1.pak is present (the nQuake rule). cp -n never
# overwrites a file the player already has.
if [ -d "$ROOT/opt/quake-extra" ]; then
    mkdir -p "$QBASE/id1" "$QBASE/qw/maps"
    [ -f "$QBASE/id1/pak1.pak" ] || cp -n "$ROOT/opt/quake-extra/id1/gpl_maps.pk3" "$QBASE/id1/" 2>/dev/null
    cp -an "$ROOT/opt/quake-extra/qw/maps/." "$QBASE/qw/maps/" 2>/dev/null
    cp -n "$ROOT/opt/quake-extra/README-partyos-maps.txt" "$QBASE/" 2>/dev/null
fi
# Shareware only: tell the player once per home what they have and what is missing.
if [ ! -f "$QBASE/id1/pak1.pak" ] && [ ! -f "$QBASE/.partyos-quake-data-notice" ]; then
    SWMSG="ezQuake is running on the free Quake SHAREWARE data.
You get Episode 1 (e1m1 to e1m8, plus start), the classic deathmatch maps
dm1 to dm6 (free GPL versions from nQuake) and the QuakeWorld maps aerowalk,
ztndm3, ztndm4, ztndm6 and schloss.
Episodes 2 to 4 are in pak1.pak, which id Software does not allow us to hand out.
For the full game, copy pak0.pak and pak1.pak from your own Quake CD, GOG or
Steam copy into:
    $QBASE/id1/
That folder is on your USB stick, so it stays there for the next boot."
    if command -v zenity >/dev/null 2>&1; then
        zenity --info --title="ezQuake - Quake data" --width=520 --text="$SWMSG" 2>/dev/null || true
    else
        printf "%s\n" "$SWMSG"
    fi
    touch "$QBASE/.partyos-quake-data-notice"
fi
if [ -f "$QBASE/id1/pak1.pak" ]; then QDATA=retail; else QDATA=shareware; fi
echo "PARTYOS-EZQUAKE-DATA ${QDATA} basedir=${QBASE}"
'
# In a bash pattern substitution an unescaped & in the REPLACEMENT expands to the
# matched text, which would shred every "&&" and "2>&1" in the seed. Escape them.
EZ_SEED="${EZ_SEED//\\/\\\\}"
EZ_SEED="${EZ_SEED//&/\\&}"
RUNSH="${RUNSH/echo \"PARTYOS-BLOB-RUN/${EZ_SEED}
echo \"PARTYOS-BLOB-RUN}"
fi
RUNSH="${RUNSH//__NAME__/${NAME}}"
RUNSH="${RUNSH//__EXEC__/${EXEC}}"

# --- build the rootfs in an amd64 container, squash it ------------------------
RUNSH_B64="$(printf '%s' "${RUNSH}" | base64 | tr -d '\n')"
docker run --rm --platform linux/amd64 --privileged \
  -e SNAPSHOT="${SNAPSHOT}" -e NAME="${NAME}" -e SOURCE="${SOURCE}" \
  -e PKGS="${PKGS}" -e RUNSH_B64="${RUNSH_B64}" -e EXTRA="${EXTRA_PKGS:-}" \
  -e TITLE="${TITLE}" -e RAM_MIN="${RAM_MIN}" -e RAM_MAX="${RAM_MAX}" -e EXEC="${EXEC}" \
  -v "${OUT_DIR}":/out "${IMAGE}" /bin/bash -euo pipefail -c '
  printf "Server=https://archive.archlinux.org/repos/%s/\$repo/os/\$arch\n" "${SNAPSHOT}" > /etc/pacman.d/mirrorlist
  # DisableSandbox in options so makepkg NESTED pacman also skips the seccomp
  # sandbox - it fails under amd64 emulation on an arm64 docker host with
  # error restricting syscalls via seccomp 22.
  printf "[options]\nArchitecture = x86_64\nSigLevel = Never\nDisableSandbox\nParallelDownloads = 5\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n" > /etc/pacman.conf
  pacman -Sy --noconfirm --disable-sandbox squashfs-tools >/dev/null 2>&1
  ROOT=/blobroot; mkdir -p "${ROOT}/var/lib/pacman"
  if [ "${SOURCE}" = aur ]; then
    # overwrite star: snapshot gcc-libs ships /usr/lib libs that collide with
    # split-lib packages preinstalled in archlinux base, so a plain base-devel
    # install aborts with conflicting files. Overwrite them.
    pacman -Sy --noconfirm --disable-sandbox --needed --overwrite "*" base-devel git
    useradd -m builder 2>/dev/null || true; echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
    cd /home/builder
    for p in ${PKGS}; do
      sudo -u builder git clone --depth 1 "https://aur.archlinux.org/${p}.git" "/home/builder/${p}"
      # --skipchecksums: some -bin pkgbases pin a CI artifact whose upstream sha
      # drifts (e.g. veloren-bin GitLab artifact) -> validity check fails. We
      # verify the FINAL blob sha ourselves, so upstream source checksums are
      # redundant belt-and-suspenders here.
      ( cd "/home/builder/${p}" && sudo -u builder makepkg -s --noconfirm --skippgpcheck --skipchecksums )
      # install the just-built pkg into the CONTAINER so a later pkgbase that
      # build-depends on this one (AUR dep chain, e.g. ddnet -> discord-game-sdk)
      # finds it at makepkg time. List deps BEFORE the game in PKGS.
      pacman -U --noconfirm --disable-sandbox --overwrite "*" /home/builder/"${p}"/*.pkg.tar.zst 2>/dev/null || true
    done
    # install the game (+ deps) into the blob rootfs from the built pkgs + repos
    pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -Sy --noconfirm --disable-sandbox filesystem >/dev/null
    for f in /home/builder/*/*.pkg.tar.zst; do
      pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -U --noconfirm --disable-sandbox "${f}" || \
        pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -U --noconfirm --disable-sandbox --nodeps "${f}"
    done
  else
    pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -Sy --noconfirm --disable-sandbox ${PKGS}
  fi
  # EXTRA: extra REPO packages baked into the rootfs - e.g. a terminal so a TUI
  # app runs from a desktop click: EXTRA_PKGS="xterm xorg-fonts-misc" exec="xterm -e ncdc".
  if [ -n "${EXTRA:-}" ]; then
    pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -S --noconfirm --disable-sandbox ${EXTRA}
  fi
  # ezquake: bake the id Software Quake SHAREWARE data into the blob so the game has
  # something to run on at the party (no internet there, and the retail paks are not
  # ours to hand out). Source: the id Software idstuff archive, quake106.zip (the 1996
  # shareware release). Its licence (slicnse.txt, clause 6) grants the right to
  # distribute the software free of charge, electronically, in compressed format, as a
  # whole, with the agreement travelling with it - so we bake the WHOLE extracted
  # archive (pak0.pak plus licinfo.txt/slicnse.txt/readme.txt/order.txt), never pak0
  # alone. The payload sits in resource.1, an LHA archive, hence lhasa.
  if [ "${NAME}" = ezquake ]; then
    echo "[appblob] ezquake: fetching the Quake shareware data" >&2
    pacman -Sy --noconfirm --disable-sandbox unzip curl lhasa >/dev/null 2>&1
    Q_URL="https://ftp.gwdg.de/pub/misc/ftp.idsoftware.com/idstuff/quake/quake106.zip"
    Q_SHA="ec6c9d34b1ae0252ac0066045b6611a7919c2a0d78a3a66d9387a8f597553239"
    PAK_SHA="35a9c55e5e5a284a159ad2a62e0e8def23d829561fe2f54eb402dbc0a9a946af"
    ZIP=/tmp/quake106.zip
    curl -fsSL --max-time 600 -o "${ZIP}" "${Q_URL}" || {
      echo "[appblob] ezquake: FATAL download failed from ${Q_URL}" >&2; exit 1; }
    DLSHA="$(sha256sum "${ZIP}" | awk "{print \$1}")"
    [ "${DLSHA}" = "${Q_SHA}" ] || {
      echo "[appblob] ezquake: FATAL quake106.zip sha256 mismatch (got ${DLSHA})" >&2; exit 1; }
    mkdir -p /tmp/qsw && ( cd /tmp/qsw && unzip -oq "${ZIP}" && lha xq resource.1 )
    SWDEST="${ROOT}/opt/quake-shareware"
    mkdir -p "${SWDEST}/id1"
    cp -a /tmp/qsw/id1/pak0.pak "${SWDEST}/id1/pak0.pak"
    # the licence and the player-facing text files must ship with the data.
    for t in licinfo.txt slicnse.txt readme.txt readv106.txt order.txt help.txt techinfo.txt; do
      [ -f "/tmp/qsw/${t}" ] && cp -a "/tmp/qsw/${t}" "${SWDEST}/${t}"
    done
    # lha restores the 1996 archive modes (0600, root). The blob is squashed -all-root,
    # so the player runs as uid 1000 and could not READ its own game data. Make the
    # baked tree world-readable, the same way the ezquake PKGBUILD normalizes /opt/quake.
    find "${SWDEST}" -type d -exec chmod 0755 {} +
    find "${SWDEST}" -type f -exec chmod 0644 {} +
    PSHA="$(sha256sum "${SWDEST}/id1/pak0.pak" | awk "{print \$1}")"
    [ "${PSHA}" = "${PAK_SHA}" ] || {
      echo "[appblob] ezquake: FATAL pak0.pak sha256 mismatch (got ${PSHA})" >&2; exit 1; }
    [ -f "${SWDEST}/slicnse.txt" ] || {
      echo "[appblob] ezquake: FATAL shareware licence text missing - refusing to ship the data without it" >&2; exit 1; }
    echo "[appblob] ezquake: shareware data baked ($(du -sh "${SWDEST}" | cut -f1))" >&2
    # CONTENT GATE: the AUR package installs the engine under /opt/quake. Without it
    # the blob would carry data and no engine.
    [ -x "${ROOT}/opt/quake/ezquake-linux-x86_64" ] || {
      echo "[appblob] ezquake: FATAL engine missing at /opt/quake/ezquake-linux-x86_64" >&2
      ls -la "${ROOT}/opt/quake" >&2 || true; exit 1; }
    rm -f "${ZIP}"; rm -rf /tmp/qsw
    # Deathmatch maps: the shareware pak0 has no dm1 to dm6. nQuake ships free maps
    # for this. gpl_maps.pk3 holds GPL builds of dm1-dm6, e2m2, e3m7 and end. The
    # community QW maps are free to distribute with their author text files. Pin the
    # nQuake distfiles commit and the sha256 of each file. run.sh seeds them into HOME.
    echo "[appblob] ezquake: fetching the nQuake deathmatch maps" >&2
    NQ_URL="https://raw.githubusercontent.com/nQuake/distfiles/cb5085cfc4ad8aaab1411de030c17517302693be"
    XDEST="${ROOT}/opt/quake-extra"
    mkdir -p "${XDEST}/id1" "${XDEST}/qw/maps"
    while read -r QSRC QDST QSHA; do
      curl -fsSL --retry 3 --max-time 300 -o "${XDEST}/${QDST}" "${NQ_URL}/${QSRC}" || {
        echo "[appblob] ezquake: FATAL download failed from ${NQ_URL}/${QSRC}" >&2; exit 1; }
      GOT="$(sha256sum "${XDEST}/${QDST}" | awk "{print \$1}")"
      [ "${GOT}" = "${QSHA}" ] || {
        echo "[appblob] ezquake: FATAL ${QDST} sha256 mismatch (got ${GOT})" >&2; exit 1; }
    done <<QMAPS
gpl/id1/gpl_maps.pk3 id1/gpl_maps.pk3 6e409cab705ea6046872383149a222fe76a351f03ac48055b3e5f1faaec9d6c6
non-gpl/qw/maps/aerowalk.bsp qw/maps/aerowalk.bsp 6c297aaa5ccb8f10f6f7ee4991ba6663f887414e31e6eac8358510e14e4ec98b
non-gpl/qw/maps/aerowalk.txt qw/maps/aerowalk.txt 621cdfce651717ad53d15b3267759569c7bdfbedc8758df2dd9686ea37bf24da
non-gpl/qw/maps/ztndm3.bsp qw/maps/ztndm3.bsp 4ae63e8d82f6439d79cbde4d1a7b46dbbc46a34eb30839ba2db24e1fd0778fbe
non-gpl/qw/maps/ztndm3.txt qw/maps/ztndm3.txt ce38c72046c50d7acb5c78ab5cbbe0ba5f3e523dfc9b2ef7624ce76e0b0b3e63
non-gpl/qw/maps/ztndm4.bsp qw/maps/ztndm4.bsp 192647cd29d7901d6d71fea7114c7168315f5b13a8b5e0beeac535d29000d2d7
non-gpl/qw/maps/ztndm4.txt qw/maps/ztndm4.txt a5cf4dc5ba7a2ae1f872eb4cc85b5199e2d1260bba604cab62d3841f04d47944
non-gpl/qw/maps/ztndm6.bsp qw/maps/ztndm6.bsp b0039ac2d4ea83661e0cc7fb769537e25496007d152c2550b18b5f68df5a351f
non-gpl/qw/maps/ztndm6.txt qw/maps/ztndm6.txt e2de4dc51b95aa5dfc48bcdb6e38210910de6e38621e856ae635c156bde4c039
non-gpl/qw/maps/schloss.bsp qw/maps/schloss.bsp 947d6a01e293d27f387080011fea0bfecda55c574cb664494c7dd21af71eb2dd
QMAPS
    cat > "${XDEST}/README-partyos-maps.txt" <<QREADME
Extra Quake maps on partyOS
===========================
Source: the nQuake distfiles repository
(https://github.com/nQuake/distfiles).

id1/gpl_maps.pk3
  Free GPL builds of dm1 to dm6, e2m2, e3m7 and end, from nQuake.
  Licence: GNU General Public License. See maps/readme.txt in the pk3.
  partyOS does not install this file when id1/pak1.pak is present.

qw/maps/aerowalk.bsp, ztndm3.bsp, ztndm4.bsp, ztndm6.bsp, schloss.bsp
  Community QuakeWorld maps. The authors distribute them free of charge.
  nQuake ships them the same way. Each author text file (.txt) stays with
  its map, as the author asks. nQuake has no text file for schloss.
QREADME
    find "${XDEST}" -type d -exec chmod 0755 {} +
    find "${XDEST}" -type f -exec chmod 0644 {} +
    echo "[appblob] ezquake: deathmatch maps baked ($(du -sh "${XDEST}" | cut -f1))" >&2
  fi
  # openra: bake the EA-freeware Red Alert assets into the blob so the game runs
  # fully offline at the party. The build station has internet; players do not.
  # OpenRA ships the engine but downloads the .mix asset packs on first run, which
  # fails offline -> crash. We fetch the version-matched ra-quickinstall.zip,
  # SHA1-verify it (OpenRA validates with SHA1, not SHA256), and stage the Content
  # tree read-only under /opt/openra-content/ra/v2; run.sh seeds it into HOME.
  if [ "${NAME}" = openra ]; then
    echo "[appblob] openra: confirming engine version pin" >&2
    pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -Q openra >&2
    pacman -Sy --noconfirm --disable-sandbox unzip curl >/dev/null 2>&1
    RA_SHA1="44241f68e69db9511db82cf83c174737ccda300b"
    MIRROR_TXT="https://www.openra.net/packages/ra-quickinstall-mirrors.txt"
    ZIP="/tmp/ra-quickinstall.zip"
    # fetch the live mirror list, fall back to the known community hosts if the
    # list itself is unreachable. iterate mirrors until one yields a good zip.
    mapfile -t MIRRORS < <(curl -fsSL --max-time 30 "${MIRROR_TXT}" 2>/dev/null | grep -Eo "https?://[^[:space:]]+" || true)
    if [ "${#MIRRORS[@]}" -eq 0 ]; then
      MIRRORS=(
        "https://openra.baxxster.no/openra/ra-quickinstall.zip"
        "https://openra.ppmsite.com/ra-quickinstall.zip"
        "https://republic.community/hosted/files/command-and-conquer/openra/ra-quickinstall.zip"
        "https://cdn.mailaender.name/openra/ra-quickinstall.zip"
        "https://openra.0x47.net/ra-quickinstall.zip"
      )
    fi
    GOT=0
    for url in "${MIRRORS[@]}"; do
      echo "[appblob] openra: trying ${url}" >&2
      rm -f "${ZIP}"
      curl -fsSL --max-time 600 -o "${ZIP}" "${url}" || { echo "[appblob] openra: download failed from ${url}" >&2; continue; }
      DLSHA="$(sha1sum "${ZIP}" | awk "{print \$1}")"
      if [ "${DLSHA}" = "${RA_SHA1}" ]; then echo "[appblob] openra: SHA1 OK from ${url}" >&2; GOT=1; break; fi
      echo "[appblob] openra: SHA1 MISMATCH from ${url} (got ${DLSHA})" >&2
    done
    [ "${GOT}" = 1 ] || { echo "[appblob] openra: FATAL no mirror yielded a SHA1-valid ra-quickinstall.zip - refusing to ship a content-less blob" >&2; exit 1; }
    # extract the Content tree (top-level *.mix, expand/*, cnc/desert.mix) into the
    # exact layout the ra mod expects, baked read-only under /opt.
    DEST="${ROOT}/opt/openra-content/ra/v2"
    mkdir -p "${DEST}"
    unzip -oq "${ZIP}" -d "${DEST}"
    # sanity: a real RA install must carry the base .mix set. fail loudly otherwise.
    for f in conquer.mix allies.mix russian.mix temperat.mix; do
      [ -f "${DEST}/${f}" ] || { echo "[appblob] openra: FATAL ${f} missing after extract - asset bundle incomplete" >&2; exit 1; }
    done
    echo "[appblob] openra: assets baked ($(du -sh "${DEST}" | cut -f1), $(find "${DEST}" -type f | wc -l) files)" >&2
    rm -f "${ZIP}"
  fi
  # AUR glibc/gcc-libs skew fix: makepkg compiled the game against the rolling-latest
  # container glibc/gcc-libs, but the rootfs was populated from the pinned
  # SNAPSHOT (older). If latest > snapshot the binary references newer versioned
  # symbols (e.g. ddnet needs GLIBC_2.43 from libm; the 2025/09 snapshot ships 2.42)
  # and the loader aborts at startup. Align the rootfs libc UP to the toolchain the
  # binary was linked against - forward-compatible (older rootfs libs run on a newer
  # glibc; the reverse breaks). Only the AUR path has this skew: the repo path builds
  # the game against the same snapshot it bundles, so leave it untouched.
  if [ "${SOURCE}" = aur ]; then
    printf "Server=https://geo.mirror.pkgbuild.com/\$repo/os/\$arch\n" > /etc/pacman.d/mirrorlist
    pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -Sy --noconfirm --disable-sandbox glibc gcc-libs
  fi
  # LIBRARY GATE: the entry binary must find every library it needs inside the
  # rootfs. A repo package can omit a dependency (openttd-14.1-3 needs libSDL2 but
  # does not depend on sdl2), and then the game stops at start on every client.
  # Take the first word of EXEC. If it is an ELF file, run ldd on it in the rootfs.
  # If ldd reports "not found", stop the build. A script entry is not checked.
  ENTRY_BIN="${EXEC%% *}"; case "${ENTRY_BIN}" in /*) ;; *) ENTRY_BIN="/usr/bin/${ENTRY_BIN}";; esac
  ENTRY_REAL="$(chroot "${ROOT}" readlink -f "${ENTRY_BIN}" 2>/dev/null || echo "${ENTRY_BIN}")"
  if [ -x "${ROOT}/usr/bin/ldd" ] && [ "$(head -c4 "${ROOT}${ENTRY_REAL}" 2>/dev/null | od -An -c | tr -d " ")" = "177ELF" ]; then
    MISSING="$(chroot "${ROOT}" /usr/bin/ldd "${ENTRY_REAL}" 2>&1 | grep "not found" || true)"
    if [ -n "${MISSING}" ]; then
      echo "[appblob] FATAL ${ENTRY_REAL} needs libraries that the blob does not have:" >&2
      echo "${MISSING}" >&2
      echo "[appblob] add the package that provides them to EXTRA_PKGS (catalog extra_pkgs)" >&2
      exit 1
    fi
    echo "[appblob] library gate OK: ${ENTRY_REAL}" >&2
  else
    echo "[appblob] library gate skipped: ${ENTRY_REAL} is not an ELF file (or the rootfs has no ldd)" >&2
  fi
  # bake the bwrap launcher as bin/run.sh, drop pacman db + caches to slim
  mkdir -p "${ROOT}/bin"; echo "${RUNSH_B64}" | base64 -d > "${ROOT}/bin/run.sh"; chmod +x "${ROOT}/bin/run.sh"
  rm -rf "${ROOT}/var/lib/pacman/sync" "${ROOT}/var/cache" "${ROOT}/usr/share/man" "${ROOT}/usr/share/doc" 2>/dev/null || true
  # game.meta so the blob is self-describing (mirrors build-game-blobs.sh).
  # ram_min/max/title/marker make the blob launchable with NO catalog row (load-url):
  # marker matches what run.sh echoes ("PARTYOS-BLOB-RUN <name> ...") so a catalog-free
  # launch can verify it the same way cmd_launch greps. Values threaded via the docker -e env.
  printf "id=%s\nname=%s\nentry=bin/run.sh\nram_min=%s\nram_max=%s\ntitle=%s\nmarker=%s\n" \
    "partyos.'"${NAME}"'" "${NAME}" "${RAM_MIN}" "${RAM_MAX}" "${TITLE}" "PARTYOS-BLOB-RUN ${NAME}" > "${ROOT}/game.meta"
  echo "[appblob] rootfs size: $(du -sh ${ROOT} | cut -f1)" >&2
  mksquashfs "${ROOT}" "/out/'"${NAME}"'.squashfs" -comp xz -b 1048576 -Xdict-size 100% -all-root -noappend -no-progress >/dev/null
  sha256sum "/out/'"${NAME}"'.squashfs" | awk "{print \$1}" > "/out/'"${NAME}"'.squashfs.sha256"
  echo "[appblob] blob: $(ls -lh /out/'"${NAME}"'.squashfs | awk "{print \$5}")" >&2
' 2>&1 | grep -vE "warning:|Parallel mksquashfs" || { echo "[appblob] BUILD FAILED for ${NAME}" >&2; exit 1; }

BLOB="${OUT_DIR}/${NAME}.squashfs"
[ -s "${BLOB}" ] || { echo "[appblob] ERROR no blob produced" >&2; exit 1; }
SHA="$(cat "${BLOB}.sha256")"; SIZE="$(wc -c < "${BLOB}" | tr -d ' ')"
echo "[appblob] ${NAME}: sha=${SHA:0:12}... size=${SIZE}" >&2

# --- wire the real sha/size into catalog.v2.json (tracked source of truth) -----
# SKIP_CATALOG=1: do NOT touch any catalog at all - just leave the blob + .sha256.
# Used by the contributor-facing make-blob.sh so a non-operator can build a blob
# WITHOUT mutating the operator catalog (they ship a fragment instead, vouched in
# later by add-blob.sh). CATALOG_V2= overrides the catalog path (symmetric with
# build-proton-blob.sh) so a build can target a TEMP catalog. Default stays the
# repo catalog so the operator's existing build flow is unchanged.
if [ "${SKIP_CATALOG:-0}" = "1" ]; then
  echo "[appblob] SKIP_CATALOG=1 - leaving catalog untouched (blob+sha written)" >&2
  echo "[appblob] DONE ${NAME}. blob=${BLOB} sha=${SHA:0:12}..." >&2
  exit 0
fi
V2="${CATALOG_V2:-${REPO_ROOT}/server/games/catalog.v2.json}"
if [ ! -f "${V2}" ]; then
  echo "[appblob] NOTE catalog not at ${V2} - skipped in-script catalog update (blob+sha written)" >&2
  echo "[appblob] DONE ${NAME}." >&2
  exit 0
fi
NAME="${NAME}" TITLE="${TITLE}" CAT="${CATEGORY}" ID="${ID}" EXECV="${EXEC}" \
SHA="${SHA}" SIZE="${SIZE}" RMIN="${RAM_MIN}" RMAX="${RAM_MAX}" python3 - "${V2}" <<'PY'
import json, os, sys
v2 = sys.argv[1]; d = json.load(open(v2))
name = os.environ["NAME"]
row = next((r for r in d.get("games", []) if r.get("name") == name), None)
new = dict(id=os.environ["ID"], name=name, title=os.environ["TITLE"], source="blob",
          blob="server/games/%s.squashfs" % name, sha256=os.environ["SHA"],
          size=int(os.environ["SIZE"]), ram_min=int(os.environ["RMIN"]),
          ram_max=int(os.environ["RMAX"]), version="1.0.0", category=os.environ["CAT"],
          icon="applications-games", exec=os.environ["EXECV"], pkg="", pkgs="",
          entry="bin/run.sh", marker="", hidden=False)
if row:
    # PRESERVE hand-maintained catalog fields (version, marker, icon, config_*,
    # blob_note, etc.) on an existing row - only the build DERIVES sha256/size, so
    # only those (plus a missing-field backfill) should change. Without this the
    # generic version="1.0.0"/marker="" defaults clobber the openra version pin and
    # the PARTYOS-APP-OPENRA-RAN marker on every rebuild.
    for k in ("sha256", "size"):
        row[k] = new[k]
    for k, v in new.items():
        row.setdefault(k, v)
else:
    d.setdefault("games", []).append(new)
json.dump(d, open(v2, "w"), indent=2)
print("[appblob] catalog.v2.json updated for %s (sha %s)" % (name, os.environ["SHA"][:12]), file=sys.stderr)
PY
echo "[appblob] DONE ${NAME}. Run build-game-blobs.sh to regenerate catalog.json." >&2
