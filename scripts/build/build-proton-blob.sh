#!/usr/bin/env bash
# build-proton-blob.sh - build a self-contained WINDOWS-game blob for partyOS.
#
# Sibling of build-app-blob.sh. A Windows game runs under Wine, so the blob is the
# SAME shape as a native blob (squashfs ro + tmpfs overlay at ~/games/<name>, run
# by partyos-app cmd_launch via bin/run.sh) - only what's INSIDE the rootfs and
# what run.sh does differ. The rootfs bundles the whole Wine runtime (wine-staging
# + the 32-bit GL/Vulkan closure + dxvk/vkd3d) plus a PRE-BUILT wineprefix with the
# game already installed and mono/gecko baked in, so the party launch never touches
# the network (no internet at the party).
#
# Two infra differences vs a native blob (both isolated to THIS script - the base
# image, the LAN mirror and build-app-blob.sh are untouched):
#   1. [multilib] is enabled in this container's pacman.conf (both games are 32-bit
#      PE32 i386; wine + lib32-* live in multilib).
#   2. run.sh redirects WINEPREFIX to the USB stick
#      (/mnt/usbhome/.partyos-runcache/<name>/prefix) - the ~3GB prefix does NOT fit
#      in the 4GB airootfs RAM overlay (one game barely fits, a second ENOSPCs). The
#      USB has tens of GB and that path is outside ~, so it is not swept by the home
#      rsync. Falls back to ~/.cache (RAM) only when no USB home is mounted.
#
# The Wine runtime ships INSIDE the blob (NOT baked into the RAM-booted base image):
# the base is pulled into RAM on EVERY boot for EVERY client, blobs are USB-cached
# and only paid for by players who launch that game.
#
# Build runs in an amd64 Arch container pinned to the SAME 2025/09 snapshot as the
# client base (so the bundled libs match the kernel/abi the client ships).
#
# Usage:
#   build-proton-blob.sh <name> <game-src-path> <exe-rel> [title] [ram_min] [ram_max]
#     name          blob/file name (a-z0-9), e.g. wc3
#     game-src-path host path to the staged game (a DIR, or a .zip to extract)
#     exe-rel       the game exe RELATIVE to the game dir inside drive_c, e.g.
#                   "Warcraft III/Frozen Throne.exe" or "FlatOut2.exe"
#     title         human title for the catalog (default: name)
#     ram_min/max   RAM budget MiB (defaults 2048 / 4096)
#   Env knobs:
#     DXVK=1        bake DXVK d3d8/9/10/11 + dxgi into the prefix (default 1)
#     VKD3D=0       bake vkd3d-proton d3d12 into the prefix (default 0; old games
#                   are D3D8/9, vkd3d only matters for D3D12 titles)
#     WINVER=winxp  windows version the prefix reports (default winxp)
#     MAXFPS=       optional DXVK frame cap (e.g. 60) baked into dxvk.conf - for
#                   FlatOut 2 whose physics are framerate-tied.
#     PB_MIRROR=    optional pacman Server line for the build container (default: the
#                   archive.archlinux.org snapshot). For an OFFLINE build host, point it
#                   at a package repo inside ARCH_IMAGE, e.g. file:///offline/pkgs. That
#                   repo must hold the core, extra and multilib dbs. If it also holds a
#                   prebuilt dxvk-bin, the build installs it and does not use the AUR.
#     WINE_REG_EXTRA  optional newline-separated `wine reg add` arg-sets baked into
#                   the prefix-template for per-game polish. The generic modeset belt
#                   (X11 Driver UseXRandR/UseXVidMode=N) is ALWAYS baked regardless.
#                   WC3 needs (renders splash then exits without these):
#                     'HKCU\Software\Blizzard Entertainment\Warcraft III\Misc' /v seenintromovie /t REG_DWORD /d 1 /f
#                     'HKCU\Software\Blizzard Entertainment\Warcraft III\Video' /v reswidth  /t REG_DWORD /d 0x400 /f
#                     'HKCU\Software\Blizzard Entertainment\Warcraft III\Video' /v resheight /t REG_DWORD /d 0x300 /f
#   Output: <OUT_DIR>/<name>.squashfs + .sha256, and the catalog row updated with
#   the real sha256/size. Run build-game-blobs.sh after to regenerate catalog.json.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/server/games}"
SNAPSHOT="${SNAPSHOT:-2025/09/01}"
IMAGE="${ARCH_IMAGE:-archlinux:latest}"
PB_MIRROR="${PB_MIRROR:-}"

NAME="${1:?name}"; GAME_SRC="${2:?game-src-path (dir or .zip)}"; EXE_REL="${3:?exe-rel inside the game dir}"
TITLE="${4:-${NAME}}"; RAM_MIN="${5:-2048}"; RAM_MAX="${6:-4096}"
ID="${ID:-partyos.${NAME}}"; CATEGORY="${CATEGORY:-game}"
DXVK="${DXVK:-1}"; VKD3D="${VKD3D:-0}"; WINVER="${WINVER:-winxp}"; MAXFPS="${MAXFPS:-}"
# Optional extra registry keys baked into the prefix-template, one `wine reg add`
# argument-set per line (e.g. game-specific pins). The generic modeset belt
# (UseXRandR/UseXVidMode=N) is always baked; this is for per-game polish like the
# WC3 Blizzard intro-movie/resolution pins passed by the wc3 build invocation.
WINE_REG_EXTRA="${WINE_REG_EXTRA:-}"

# WC3 default reg set: the Blizzard pins war3.exe needs to even start under Wine
# (without seenintromovie it renders the splash and exits), the windowed resolution
# cap, AND the pre-1.31 fullscreen toggle. Baked automatically for the wc3 build so
# the operator does not have to hand-type them; override by passing WINE_REG_EXTRA.
#  - seenintromovie=1: skip the intro movie that otherwise wedges the launch.
#  - reswidth=0x400/resheight=0x300 (1024x768): the windowed-mode menu resolution.
#  - 'Gfx Fullscreen'=1: classic War3 (<=1.30) honours this DWORD in the Video subkey
#    as the fullscreen-vs-windowed switch (removed in 1.31, which moved it to the
#    preferences file). With it set, War3's "fullscreen" fills the Wine virtual
#    desktop (sized to the real monitor by run.sh) on first launch instead of the
#    1024x768 windowed box that leaves a black border. No REAL X modeset happens -
#    the desktop is Wine-owned - so the live nvidia X session is never switched out.
#    Some dumps place 'Gfx Fullscreen' under the Video subkey, some under the
#    Warcraft III root; we write the Video one (matches the reswidth/resheight
#    neighbours).
if [ "${NAME}" = wc3 ] && [ -z "${WINE_REG_EXTRA}" ]; then
  WINE_REG_EXTRA=$'\'HKCU\\Software\\Blizzard Entertainment\\Warcraft III\\Misc\' /v seenintromovie /t REG_DWORD /d 1 /f
\'HKCU\\Software\\Blizzard Entertainment\\Warcraft III\\Video\' /v reswidth /t REG_DWORD /d 0x400 /f
\'HKCU\\Software\\Blizzard Entertainment\\Warcraft III\\Video\' /v resheight /t REG_DWORD /d 0x300 /f
\'HKCU\\Software\\Blizzard Entertainment\\Warcraft III\\Video\' /v "Gfx Fullscreen" /t REG_DWORD /d 1 /f'
fi

# AvP2 default reg set: the Monolith keys that the four installers write in the
# staging prefix (stage-avp2.sh dumps them to <staged>.registry.txt). This build makes
# a FRESH prefix, so the keys must be baked here.
#  - InstallDir: the game dir. In the blob it is C:\game, not the staging path.
#  - Update Command Line: the update REZ archives (1.0.9.6 and SP map update) that the
#    launcher gives to lithtech.exe. It is the value the installers wrote.
#  - The 32-bit game reads HKLM\Software through Wow6432Node in the wow64 prefix.
#  - Disable Movies=1: the launcher option "Disable Logos". It adds +DisableMovies 1
#    to the lithtech.exe command. Without it, lithtech.exe crashes in Binkw32.dll
#    while it plays the intro movie under Wine.
if [ "${NAME}" = avp2 ] && [ -z "${WINE_REG_EXTRA}" ]; then
  WINE_REG_EXTRA=$'\'HKLM\\Software\\Wow6432Node\\Monolith Productions\\Aliens vs. Predator 2\\1.0\' /v InstallDir /d \'C:\\game\' /f
\'HKLM\\Software\\Wow6432Node\\Monolith Productions\\Aliens vs. Predator 2\\1.0\' /v Language /d English /f
\'HKLM\\Software\\Wow6432Node\\Monolith Productions\\Aliens vs. Predator 2\\1.0\' /v "Update Command Line" /d "-rez AVP2P1.REZ -rez AVP2SP.REZ" /f
\'HKLM\\Software\\Wow6432Node\\Monolith Productions\\Aliens vs. Predator 2\\1.0\' /v "Disable Movies" /t REG_DWORD /d 1 /f'
fi

command -v docker >/dev/null || { echo "[protonblob] ERROR docker required" >&2; exit 1; }
[ -e "${GAME_SRC}" ] || { echo "[protonblob] ERROR game source not found: ${GAME_SRC}" >&2; exit 1; }
mkdir -p "${OUT_DIR}"
echo "[protonblob] building '${NAME}' from '${GAME_SRC}' exe='${EXE_REL}' (dxvk=${DXVK} vkd3d=${VKD3D} winver=${WINVER})" >&2

# The bin/run.sh baked into the blob. Forked from build-app-blob.sh's RUNSH:
#   - PARTYOS_SOFTWARE_GL defaults to 0 (the opposite of build-app-blob.sh) so
#     DXVK gets the REAL GPU Vulkan path, not llvmpipe.
#   - on first launch, copy the read-only prefix-template out to a WRITABLE dir on
#     the USB stick (/mnt/usbhome/.partyos-runcache, big + outside the home rsync;
#     the 4GB RAM overlay can't hold a ~3GB prefix), then point WINEPREFIX there.
#     Second launch reuses it (instant). Falls back to ~/.cache if no USB is mounted.
#   - symlink the game's SAVE dir out to a synced HOME path so progress persists to
#     the USB stick (the prefix itself, in .cache, does NOT sync).
#   - GPU passthrough: the sandbox uses the BLOB /usr, which only ships the Mesa
#     Vulkan ICDs (intel/radeon) - so on a Mesa host the blob GL/Vulkan already
#     drives the real GPU. nvidia is different: its userspace driver is NOT in the
#     blob (it must match the HOST kernel module, so it canNOT be baked), and the
#     blob carries no nvidia ICD -> the loader finds no device, DXVK dies with
#     "Failed to enumerate physical devices" and falls back to llvmpipe. So when
#     the host has nvidia we bind the host nvidia userspace libs into /nvidia and
#     point the Vulkan loader at a generated ICD over them. Conditional: no nvidia
#     host -> the block is skipped and Mesa-in-the-blob handles intel/amd.
#   - echo the same marker contract cmd_launch:2137 greps, then exec wine.
RUNSH='#!/bin/bash
# partyOS Windows-game (Wine) blob launcher: bwrap this rootfs + run the game.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
U="$(id -u)"
NAME="__NAME__"
EXE_REL="__EXE_REL__"
SAVE_REL="__SAVE_REL__"
WINVER="__WINVER__"
DLLOVERRIDES="__DLLOVERRIDES__"
WIPE_SAVEGAME="__WIPE_SAVEGAME__"
NICK_PROFILE="__NICK_PROFILE__"

# --- GPU-vendor-gated Direct3D renderer ------------------------------------
# DXVK (Vulkan) is proven fast + stable on nvidia'\''s Vulkan and MUST stay the
# renderer there. But DXVK-on-mesa (vulkan-intel / vulkan-radeon) races/exits
# during d3d9 device creation for some titles (FlatOut2 exits ~6-16s in), while
# WineD3D (OpenGL) keeps them alive. Gate on the SAME /dev/nvidia0 probe the
# nvidia passthrough block below uses: nvidia present -> keep the baked DXVK
# native d3d overrides; otherwise (integrated Intel/AMD mesa) -> flip the DXVK
# d3d group to builtin so wine loads WineD3D instead of the native DXVK dlls
# (which stay on disk, just unused). WINEDLLOVERRIDES (env) outranks the prefix
# registry DllOverrides, so this needs no prefix change; reversible + keyed
# purely on the vendor probe. The LIBGL_ALWAYS_SOFTWARE knob + mesa passthrough
# are untouched.
if [ ! -e /dev/nvidia0 ]; then
    DLLOVERRIDES="${DLLOVERRIDES//d3d8,d3d9,d3d10core,d3d11,dxgi=n/d3d8,d3d9,d3d10core,d3d11,dxgi=b}"
    echo "PARTYOS-BLOB-RUN ${NAME} d3d=wined3d (mesa: no /dev/nvidia0)" >&2
else
    echo "PARTYOS-BLOB-RUN ${NAME} d3d=dxvk (nvidia /dev/nvidia0)" >&2
fi

# --- Wine prefix assembly (OVERLAY, not a multi-GB copy) ---------------------
# The ~3GB baked prefix-template is NOT copied into RAM or slow-copied to the stick.
# It is the read-only LOWER of an overlayfs; wine writes only deltas (registry, saves,
# config) to a small UPPER on the USB stick, and the merged dir is the WINEPREFIX. So a
# proton game costs the stick a few MB of deltas, not a multi-GB RAM/stick copy - which
# is what let one game barely fit and a second ENOSPC the 4GB RAM overlay, and what made
# an 8GB box project ~8GB and refuse to launch. Falls back to a COPY (stick preferred
# over /dev/shm, RAM last) when overlayfs is unavailable (no USB, no sudo, mount refused).
STICK_RC="/mnt/usbhome/.partyos-runcache/${NAME}"
CACHE_RC="${HOME}/.cache/partyos-run/${NAME}"
# Small per-game scratch (shader cache, generated nvidia ICD, lock). Kept under ~/.cache
# (bound into the sandbox via $HOME) regardless of where the prefix itself lives.
RUNHOME="${CACHE_RC}"
SAVES="${HOME}/.local/share/partyos-saves/${NAME}"   # synced HOME path -> saves reach USB
LOWER="${ROOT}/opt/prefix-template"
PREFIX=""          # assembled WINEPREFIX (overlay merged dir OR a copied prefix)
OVERLAY_MNT=""     # set => PREFIX is an overlay mount to bind into bwrap + umount on exit
mkdir -p "${RUNHOME}" "${SAVES}"

# try_overlay: mount lower(=baked prefix-template) + upper/work(=stick) -> merged prefix.
# The desktop user has passwordless sudo (mount needs root); the prefix-template is baked
# uid-1000 so overlay copy-up is user-writable. Idempotent: reuse an existing mount.
try_overlay() {
    mountpoint -q /mnt/usbhome 2>/dev/null || return 1
    command -v sudo >/dev/null 2>&1 || return 1
    local up="${STICK_RC}/upper" wk="${STICK_RC}/work" mp="${STICK_RC}/prefix"
    mkdir -p "${up}" "${wk}" "${mp}" 2>/dev/null || \
      { sudo -n mkdir -p "${up}" "${wk}" "${mp}" && sudo -n chown "$(id -u):$(id -g)" "${STICK_RC}" "${up}" "${wk}" "${mp}"; } 2>/dev/null || return 1
    if mountpoint -q "${mp}" 2>/dev/null; then PREFIX="${mp}"; OVERLAY_MNT="${mp}"; return 0; fi
    # index=off: (1) the lower is on the game overlay whose fs has no file handles, so the
    # kernel forces index=off anyway; (2) it disables overlayfs exclusive-upperdir protection
    # so a RELAUNCH remounts cleanly even if the previous mount was torn down lazily and a
    # wineserver briefly still referenced the upperdir (otherwise the remount is refused
    # with "upperdir is in-use as upperdir/workdir of another mount"). The per-game flock
    # already prevents two concurrent launches from sharing the upperdir.
    if sudo -n mount -t overlay overlay -o "lowerdir=${LOWER},upperdir=${up},workdir=${wk},index=off" "${mp}" 2>/dev/null; then
        PREFIX="${mp}"; OVERLAY_MNT="${mp}"
        echo "PARTYOS-BLOB-RUN ${NAME} prefix=overlay upper=${up}" >&2
        return 0
    fi
    return 1
}

# copy_prefix: fallback when overlay is unavailable. cp -a the whole template, preferring
# the STICK over /dev/shm so a 3GB copy never blows up the RAM on an 8GB box; cache last.
# Preserves the one-time-copy + ready-marker contract (a partial copy is torn down).
copy_prefix() {
    local base
    if mountpoint -q /mnt/usbhome 2>/dev/null; then base="${STICK_RC}"
    elif [ -d /dev/shm ]; then base="/dev/shm/partyos-runcache/${NAME}"
    else base="${CACHE_RC}"; fi
    mkdir -p "${base}" 2>/dev/null || { sudo -n mkdir -p "${base}" && sudo -n chown "$(id -u):$(id -g)" "${base}"; } 2>/dev/null || base="${CACHE_RC}"
    mkdir -p "${base}" 2>/dev/null || true
    PREFIX="${base}/prefix"
    if [ ! -f "${PREFIX}/.partyos-prefix-ready" ]; then
        rm -rf "${PREFIX}"
        cp -a "${LOWER}" "${PREFIX}" || { echo "PARTYOS-BLOB-RUN ${NAME} prefix copy failed" >&2; rm -rf "${PREFIX}"; return 1; }
    fi
    echo "PARTYOS-BLOB-RUN ${NAME} prefix=copy at=${PREFIX}" >&2
    return 0
}

# Single-instance per game. A second launch (double-click, or a click racing an
# in-flight one) must NOT run a concurrent prefix copy into the same RUNHOME: that
# raced two `cp -a` and left wine doing chdir into a half-built prefix ("No such file
# or directory"). Hold an exclusive per-game lock across the copy; if the game is
# already starting, bail quietly instead of stacking a second pipeline.
exec 9>"/run/user/${U}/partyos-blob-${NAME}.lock" 2>/dev/null || exec 9>"/tmp/partyos-blob-${NAME}.lock"
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
    echo "PARTYOS-BLOB-RUN ${NAME} already running - second launch ignored" >&2
    command -v zenity >/dev/null 2>&1 && \
        ( sleep 4 ) | zenity --progress --pulsate --auto-close --no-cancel \
            --title="partyOS" --width=360 --text="${NAME} is already running." >/dev/null 2>&1 &
    exit 0
fi

# Visible feedback during the (possibly slow) first-launch prefix copy + wine spin-up.
# Without it the desktop sits silent through the whole prepare phase and looks dead -
# the exact "I clicked the launcher and nothing happens" report. Pulsate dialog fed by
# a background sleep so it self-closes on EOF and survives the final exec (no kill).
if command -v zenity >/dev/null 2>&1; then
    ( sleep 25 ) | zenity --progress --pulsate --auto-close --no-cancel \
        --title="partyOS" --width=390 \
        --text="Launching ${NAME}...
First launch prepares the game - one moment." >/dev/null 2>&1 &
fi

# Assemble the prefix: overlay first (cheap - just deltas), copy fallback (heavy but
# always works). A hard failure of both leaves no writable prefix -> bail loudly.
try_overlay || copy_prefix || { echo "PARTYOS-BLOB-RUN ${NAME} FATAL no writable prefix" >&2; exit 1; }

# One-time prefix finalize: repoint the game SAVE dir at the synced HOME location so
# progress persists to the USB stick (the prefix upper is outside the home rsync). The
# ready marker lives WITH the prefix (overlay upper on the stick, or the copy), so this
# runs once per prefix and is a no-op on every later launch. On the overlay this writes
# a whiteout + symlink into the stick upper; on a copy it edits the copy.
if [ ! -f "${PREFIX}/.partyos-prefix-ready" ]; then
    if [ -n "${SAVE_REL}" ]; then
        src="${PREFIX}/drive_c/game/${SAVE_REL}"
        if [ -e "${src}" ] && [ ! -L "${src}" ]; then
            mkdir -p "$(dirname "${src}")"
            cp -a "${src}/." "${SAVES}/" 2>/dev/null || true
            rm -rf "${src}"
        fi
        ln -sfn "${SAVES}" "${src}"
    fi
    touch "${PREFIX}/.partyos-prefix-ready"
fi

args=( --ro-bind "$ROOT/usr" /usr --ro-bind "$ROOT/etc" /etc
       --symlink usr/lib /lib --symlink usr/lib /lib64 --symlink usr/bin /bin --symlink usr/bin /sbin
       --proc /proc --dev-bind /dev /dev --tmpfs /tmp --tmpfs /var/tmp
       --bind "$HOME" "$HOME" )
[ -d "$ROOT/opt" ] && args+=( --ro-bind "$ROOT/opt" /opt )
[ -d "$ROOT/var/lib" ] && args+=( --ro-bind "$ROOT/var/lib" /var/lib )
# Host /sys, read-only. The Mesa loader and the Mesa Vulkan drivers find the GPU
# with drmGetDevice2, which reads /sys/dev/char/<major>:<minor>. If /sys is absent,
# Mesa cannot identify the Intel or AMD GPU and falls back to llvmpipe. The nvidia
# driver does not use this path, so only Intel and AMD hosts showed the problem.
args+=( --ro-bind-try /sys /sys )
args+=( --ro-bind-try /etc/passwd /etc/passwd --ro-bind-try /etc/group /etc/group
        --ro-bind-try "/run/user/$U" "/run/user/$U" --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix
        --setenv HOME "$HOME" --setenv USER "$(id -un)"
        --setenv DISPLAY "${DISPLAY:-:0}" --setenv XAUTHORITY "${XAUTHORITY:-$HOME/.Xauthority}"
        --setenv XDG_RUNTIME_DIR "/run/user/$U" --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=/run/user/$U/bus"
        --setenv LIBGL_ALWAYS_SOFTWARE "${PARTYOS_SOFTWARE_GL:-0}"
        --setenv WINEPREFIX "${PREFIX}"
        --setenv WINEDEBUG "-all"
        --setenv WINEDLLOVERRIDES "${DLLOVERRIDES}"
        --setenv DXVK_LOG_LEVEL none
        --setenv MESA_SHADER_CACHE_DIR "${RUNHOME}/shadercache"
        --die-with-parent --new-session )

# The prefix (overlay merged dir, or a stick-backed copy fallback) lives on the USB
# stick, which is NOT otherwise bound into the sandbox - bind it so wine can see the
# WINEPREFIX. A /dev/shm or ~/.cache prefix is already visible (dev-bind /dev, bind $HOME).
case "${PREFIX}" in /mnt/usbhome/*) args+=( --bind "${PREFIX}" "${PREFIX}" );; esac

# --- nvidia GPU passthrough (host-driver, conditional) ----------------------
# The blob /usr ships no nvidia driver and no nvidia Vulkan ICD. If the host has
# an nvidia GPU, expose the HOST userspace driver (it matches the host kernel
# module) into /nvidia inside the sandbox and point the Vulkan loader at it via a
# generated ICD. Skipped entirely on non-nvidia hosts -> Mesa-in-the-blob drives
# intel/amd. wow64 wine runs the unix-side Vulkan as 64-bit, so the 64-bit driver
# serves the 32-bit game; no lib32 nvidia needed.
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
for icd in /usr/share/vulkan/icd.d/nvidia_icd.json \
           /etc/vulkan/icd.d/nvidia_icd.json; do
    [ -e "${icd}" ] && { NV_ICD="${icd}"; break; }
done
if [ -e /dev/nvidia0 ] && [ -n "${NV_ICD}" ]; then
    NV_MODE="$(nv_prime_mode)"
    NVLIB=""
    for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu; do
        [ -e "${d}/libGLX_nvidia.so.0" ] && { NVLIB="${d}"; break; }
    done
    if [ "$NV_MODE" = mesa ]; then
        NVLIB=""
        IGPU="$(igpu_dri_prime)" && args+=( --setenv DRI_PRIME "$IGPU" )
    fi
    if [ -n "${NVLIB}" ]; then
        # bind every nvidia userspace .so* into /nvidia (libGLX_nvidia dlopens its
        # siblings: glcore, glsi, tls, gpucomp, glvkspirv, ...). Generate an ICD
        # over the bound copy and resolve sibling deps via LD_LIBRARY_PATH=/nvidia.
        for so in "${NVLIB}"/libnvidia-*.so* \
                  "${NVLIB}"/libGLX_nvidia.so* "${NVLIB}"/libEGL_nvidia.so* \
                  "${NVLIB}"/libGLESv1_CM_nvidia.so* "${NVLIB}"/libGLESv2_nvidia.so* \
                  "${NVLIB}"/libcuda.so* "${NVLIB}"/libnvcuvid.so* "${NVLIB}"/libnvoptix.so*; do
            [ -e "${so}" ] && args+=( --ro-bind "${so}" "/nvidia/$(basename "${so}")" )
        done
        printf "{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"/nvidia/libGLX_nvidia.so.0\",\"api_version\":\"1.4.0\"}}\n" \
            > "${RUNHOME}/nvidia_icd.json"
        args+=( --ro-bind "${RUNHOME}/nvidia_icd.json" /nvidia/nvidia_icd.json
                --setenv VK_DRIVER_FILES /nvidia/nvidia_icd.json
                --setenv VK_ICD_FILENAMES /nvidia/nvidia_icd.json
                --setenv LD_LIBRARY_PATH /nvidia
                --setenv __GLX_VENDOR_LIBRARY_NAME nvidia )
        [ "$NV_MODE" = offload ] && args+=( --setenv __NV_PRIME_RENDER_OFFLOAD 1
                --setenv __VK_LAYER_NV_optimus NVIDIA_only )
    fi
fi

# The exe is launched directly (no start.exe). bwrap --chdir sets the working dir
# to the game folder so data loaded relative to cwd resolves (FlatOut 2 reads
# fo2*.bfs from the game dir). The win-path form of the exe is still handed to wine.
EXE_WIN="C:\\game\\__EXE_WIN__"

# unix path of the game dir inside the sandbox (cwd for data-relative loads). /dev/shm
# and the prefix are reachable via --dev-bind /dev. Drop start.exe; --chdir sets cwd.
UNIX_GAME_DIR="${PREFIX}/drive_c/game"
case "${EXE_REL}" in */*) UNIX_GAME_DIR="${PREFIX}/drive_c/game/${EXE_REL%/*}";; esac

# --- Wine virtual desktop (real-hardware modeset guard) ---------------------
# Classic D3D8/War3-era games do a REAL fullscreen RandR modeset (e.g. to 1024x768)
# on the live X server. On a real partyOS client that switches the nvidia Xorg mode
# out from under the running session -> the monitor loses signal and X dies (the
# player blacks out). Run the game inside a Wine virtual desktop instead: its
# "fullscreen" becomes a Wine-owned window sized to the real monitor, so the actual
# X mode is never switched. DXVK still inits on the GPU and presents into the
# virtual-desktop window. Size the desktop to the user'\''s primary output, queried
# on the HOST X session (we still have DISPLAY/XAUTHORITY here, before bwrap); the
# sandbox never sees xrandr. Fall back to 1920x1080 if detection fails.
# Pull the WIDTHxHEIGHT+X+Y geometry token off the connected output line ("primary"
# shifts the field index by one, so match the token by shape, not by position);
# prefer the primary output, else the first connected one. Strip the +X+Y offset.
DESK_RES="$(xrandr 2>/dev/null | awk '\''
    / connected/ {
        for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) {
            if ($0 ~ / connected primary /) { print $i; exit }
            if (!r) r=$i
        }
    }
    END { if (r) print r }'\'' | sed '\''s/+.*//'\'')"
case "${DESK_RES}" in *[0-9]x[0-9]*) : ;; *) DESK_RES="1920x1080" ;; esac

# --- runtime player-name preseed (per-user, NOT bakeable) -------------------
# The in-game player/profile name should be the LIVE partyOS username, which differs
# per machine and is only known at runtime ($USER). The prefix-template is SHARED and
# baked, so the name canNOT be baked statically - it is seeded HERE into the per-user
# writable prefix (~/.cache/partyos-run/<name>/prefix). NAME_REG is the
# "<key>|<value-name>" to write (set only for games that store the name in the
# registry; empty otherwise). Gated on a marker keyed by the username so it is a
# one-shot per user (re-runs only if the username changed) and never slows a launch.
# Runs INSIDE bwrap so wine sees the prefix/env exactly as the game will.
NAME_REG="__NAME_REG__"
if [ -n "${NAME_REG}" ]; then
    PNAME="$(id -un)"
    SEEN="${RUNHOME}/.partyos-name-${PNAME}"
    if [ ! -f "${SEEN}" ]; then
        nk="${NAME_REG%%|*}"; nv="${NAME_REG##*|}"
        bwrap "${args[@]}" wine reg add "${nk}" /v "${nv}" /d "${PNAME}" /f >/dev/null 2>&1 || true
        : > "${SEEN}" 2>/dev/null || true
    fi
fi

# --- per-launch savegame wipe + FlatOut profile-name inject -----------------
# WIPE_SAVEGAME: space-separated files to rm -f from the game Savegame dir on every
# launch (the FlatOut video-config, so its setup dialog always re-runs). NICK_PROFILE=
# flatout-sav rewrites the FlatOut profile name in every player*.sav to the live NICK
# (UTF-16LE at 0x04 cap 64B + 0x64 cap 24B). The name source is INTERNYET_ALIAS, see
# below. The template ships no player*.sav, so the first launch shows the game profile
# dialog and later launches rename that profile. Savegame is a symlink to the synced SAVES,
# so both the wipe and the name persist to the USB stick. Each guarded on its knob.
if [ -n "${WIPE_SAVEGAME}" ] || [ -n "${NICK_PROFILE}" ]; then
    SAVEDIR="${PREFIX}/drive_c/game/${SAVE_REL}"
    if [ -d "${SAVEDIR}" ]; then
        for f in ${WIPE_SAVEGAME}; do
            rm -f "${SAVEDIR}/${f}" 2>/dev/null || true
        done
        if [ "${NICK_PROFILE}" = flatout-sav ]; then
            # The player name is the venue alias: INTERNYET_ALIAS in internyet.env on
            # the stick share. If it is absent, use the NICK that partyos-userconf-setup
            # publishes, then the login name. Read only the alias key (the file holds secrets).
            NICK=""
            if [ -r /usr/local/lib/partyos-internyet.sh ]; then
                NICK="$(. /usr/local/lib/partyos-internyet.sh && internyet_get INTERNYET_ALIAS 2>/dev/null)"
            fi
            [ -n "${NICK}" ] || NICK="$(tr -d '\''\r\n'\'' 2>/dev/null < /run/partyos-nick)"
            [ -n "${NICK}" ] || NICK="$(id -un)"
            SAVEDIR="${SAVEDIR}" NICK="${NICK}" python3 - <<'\''PY'\'' || true
import glob, os
savedir = os.environ["SAVEDIR"]
enc = os.environ["NICK"].encode("utf-16-le")
for p in glob.glob(os.path.join(savedir, "player*.sav")):
    try:
        with open(p, "rb") as fh:
            b = bytearray(fh.read())
    except OSError:
        continue
    if len(b) < 0x7c:
        continue
    # name field @0x04: buffer 0x04..0x45 (next struct @0x46); safe cap 64 bytes.
    n1 = enc[:64]
    b[0x04:0x04 + len(n1)] = n1
    for i in range(0x04 + len(n1), 0x46):
        b[i] = 0
    # name field @0x64: 24-byte buffer 0x64..0x7b (length field @0x60 left intact).
    n2 = enc[:22]
    b[0x64:0x64 + len(n2)] = n2
    for i in range(0x64 + len(n2), 0x7c):
        b[i] = 0
    with open(p, "wb") as fh:
        fh.write(b)
PY
        fi
    fi
fi

echo "PARTYOS-BLOB-RUN ${NAME} exec=wine ${EXE_REL}"
if [ -n "${OVERLAY_MNT}" ]; then
    # Keep run.sh as the parent (do NOT exec) so we can drop the stick overlay once the
    # game exits: instant remount next launch, no piling host mounts, stick stays ejectable.
    bwrap "${args[@]}" --chdir "${UNIX_GAME_DIR}" wine explorer /desktop="partyos,${DESK_RES}" "${EXE_WIN}" "$@"
    rc=$?
    sudo -n umount "${OVERLAY_MNT}" 2>/dev/null || sudo -n umount -l "${OVERLAY_MNT}" 2>/dev/null || true
    exit "${rc}"
fi
exec bwrap "${args[@]}" --chdir "${UNIX_GAME_DIR}" wine explorer /desktop="partyos,${DESK_RES}" "${EXE_WIN}" "$@"
'

# DLL overrides string: turn off mono/gecko popups + force the dxvk dlls native.
DLLOVERRIDES="mscoree=;mshtml="
if [ "${DXVK}" = 1 ]; then DLLOVERRIDES="${DLLOVERRIDES};d3d8,d3d9,d3d10core,d3d11,dxgi=n"; fi
if [ "${VKD3D}" = 1 ]; then DLLOVERRIDES="${DLLOVERRIDES};d3d12,d3d12core=n"; fi

# the save dir (relative to the game dir) to persist out to synced HOME. Heuristic
# per known game; empty = no save redirect (prefix-in-.cache holds saves, won't sync).
SAVE_REL="${SAVE_REL:-}"
# windows-path form of the exe (forward -> back slashes) for the wine command.
EXE_WIN="$(printf '%s' "${EXE_REL}" | tr '/' '\\')"

# NAME_REG: the "<registry-key>|<value-name>" run.sh seeds at runtime with the live
# username (the per-machine player name). Empty unless the game is known to store its
# local name in the registry. For classic War3 the in-game create-game
# name field is what the player types and the campaign profile lives in a Save/profile
# FILE, not a documented registry value - no reliable HKCU value for the local/LAN name
# was found in the sources. We seed a best-candidate value ('name' under the Warcraft
# III root) so the username is at least pre-written; if War3 ignores it the create-game
# dialog still has to be filled by hand (harmless, idempotent, one-shot per user).
# NOT a backslash here -
# this string is later pasted into the run.sh heredoc and split on the '|' at runtime.
NAME_REG=""
[ "${NAME}" = wc3 ] && NAME_REG='HKCU\Software\Blizzard Entertainment\Warcraft III|name'

# Per-launch savegame knobs (empty = no-op, so other games are unaffected):
#   WIPE_SAVEGAME - space-separated files run.sh rm -f's from the game Savegame dir on
#                   every launch (FlatOut2 stores its video setup in options.cfg/
#                   device.cfg/options.sav - wiping them makes the setup dialog re-run).
#   NICK_PROFILE  - names the profile-name recipe run.sh applies. "flatout-sav" injects
#                   the live player NICK into every FlatOut player*.sav (binary UTF-16LE),
#                   so the profile shows the player, not the baked builder name.
WIPE_SAVEGAME=""
NICK_PROFILE=""
if [ "${NAME}" = flatout2 ]; then
  # FlatOut 2 keeps profiles + config under drive_c/game/Savegame. Pin SAVE_REL so the
  # prefix-copy block symlinks it to the synced SAVES (saves persist to USB) AND the
  # wipe/inject below resolve the right dir. Respects an explicit SAVE_REL override.
  SAVE_REL="${SAVE_REL:-Savegame}"
  WIPE_SAVEGAME="options.cfg device.cfg options.sav"
  NICK_PROFILE="flatout-sav"
fi

RUNSH="${RUNSH//__NAME__/${NAME}}"
RUNSH="${RUNSH//__EXE_REL__/${EXE_REL}}"
RUNSH="${RUNSH//__EXE_WIN__/${EXE_WIN}}"
RUNSH="${RUNSH//__SAVE_REL__/${SAVE_REL}}"
RUNSH="${RUNSH//__WINVER__/${WINVER}}"
RUNSH="${RUNSH//__DLLOVERRIDES__/${DLLOVERRIDES}}"
RUNSH="${RUNSH//__NAME_REG__/${NAME_REG}}"
RUNSH="${RUNSH//__WIPE_SAVEGAME__/${WIPE_SAVEGAME}}"
RUNSH="${RUNSH//__NICK_PROFILE__/${NICK_PROFILE}}"

# --emit-runsh: print the fully-substituted run.sh and exit (pure bash - no Docker, no
# x86). Lets a REPACK swap an updated launcher into an existing blob without rebuilding
# the wine prefix. Feed the blob's own values via the normal args/env (NAME EXE_REL +
# DXVK/VKD3D/WINVER/SAVE_REL); GAME_SRC is unused here so a dummy "-" is fine.
if [ -n "${PB_EMIT_RUNSH:-}" ]; then
    printf '%s\n' "${RUNSH}"
    exit 0
fi

# --- build the rootfs in an amd64 container, squash it ------------------------
RUNSH_B64="$(printf '%s' "${RUNSH}" | base64 | tr -d '\n')"

# stage the game where the container can read it (a dir is bind-mounted ro; a zip is
# copied so we can unzip inside). We bind a parent dir to /gamesrc.
GAME_SRC_ABS="$(cd "$(dirname "${GAME_SRC}")" && pwd)/$(basename "${GAME_SRC}")"
GAME_PARENT="$(dirname "${GAME_SRC_ABS}")"
GAME_BASE="$(basename "${GAME_SRC_ABS}")"

docker run --rm --platform linux/amd64 --privileged \
  -e SNAPSHOT="${SNAPSHOT}" -e PB_MIRROR="${PB_MIRROR}" -e NAME="${NAME}" -e RUNSH_B64="${RUNSH_B64}" \
  -e EXE_REL="${EXE_REL}" -e GAME_BASE="${GAME_BASE}" -e SAVE_REL="${SAVE_REL}" \
  -e DXVK="${DXVK}" -e VKD3D="${VKD3D}" -e WINVER="${WINVER}" -e MAXFPS="${MAXFPS}" \
  -e DLLOVERRIDES="${DLLOVERRIDES}" -e WINE_REG_EXTRA="${WINE_REG_EXTRA}" \
  -e TITLE="${TITLE}" -e RAM_MIN="${RAM_MIN}" -e RAM_MAX="${RAM_MAX}" \
  -v "${OUT_DIR}":/out -v "${GAME_PARENT}":/gamesrc:ro "${IMAGE}" /bin/bash -euo pipefail -c '
  # PB_MIRROR replaces the snapshot URL, for a build host with no internet access.
  if [ -n "${PB_MIRROR}" ]; then
    printf "Server=%s\n" "${PB_MIRROR}" > /etc/pacman.d/mirrorlist
  else
    printf "Server=https://archive.archlinux.org/repos/%s/\$repo/os/\$arch\n" "${SNAPSHOT}" > /etc/pacman.d/mirrorlist
  fi
  # [multilib] is THE difference vs a native blob - both target games are 32-bit
  # PE32 i386 so wine needs the lib32-* GL/Vulkan closure. DisableSandbox: makepkc/
  # pacman seccomp sandbox fails under amd64 emulation on an arm64 docker host.
  printf "[options]\nArchitecture = x86_64\nSigLevel = Never\nDisableSandbox\nParallelDownloads = 5\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" > /etc/pacman.conf
  # GLIBC SKEW FIX: archlinux:latest ships coreutils-9.7 built against glibc 2.43,
  # but the pinned 2025/09/01 snapshot glibc is 2.42. The moment we pacman -S a
  # snapshot pkg into the CONTAINER (wine/winetricks have to run here to bake the
  # prefix), the live container glibc is downgraded to 2.42 and the image-supplied
  # coreutils binaries (sort/sed) break with "GLIBC_2.43 not found". That broke
  # makepkg arch-lint (sort -u returns 0 lines -> false "arch can not contain
  # duplicate values") and the post-install hooks. Downgrade the WHOLE container to
  # the snapshot FIRST (-uu allows downgrades) so coreutils/glibc are mutually
  # consistent before anything else touches the container system. Native blobs dodge
  # this because they only install base-devel into the container, never snapshot libs.
  # --overwrite "*": the snapshot split-lib pkgs (gcc-libs, pacman libmakepkg-dropins)
  # ship files the newer image already owns -> the upgrade aborts on "exists in
  # filesystem" without it (same conflict build-app-blob.sh overwrites for base-devel).
  pacman -Syuu --noconfirm --disable-sandbox --overwrite "*" >/dev/null 2>&1
  pacman -S --noconfirm --disable-sandbox squashfs-tools unzip >/dev/null 2>&1
  ROOT=/blobroot; mkdir -p "${ROOT}/var/lib/pacman"

  # --- wine runtime + 32-bit GL/Vulkan closure into the blob rootfs ----------
  # wine-staging: preferred for 2002-2006 D3D8/9 titles (ships from multilib, simpler
  # than proton-ge/umu). The 64-bit wow64 binary still needs the lib32 GL/Vulkan
  # closure to render 32-bit games. winetricks + cabextract for prefix tweaks.
  # libunwind + lib32-libunwind are HARD-required by the wine-staging ntdll.so (it
  # links libunwind.so.8 for its unwinder) but the snapshot packages them as a weak
  # dep pacman does NOT auto-pull -> without them wine fails to even start with
  # could-not-load-ntdll.so libunwind.so.8 cannot-open-shared-object, both at build
  # time (wineboot) AND at the party. Pin them in BOTH the container and the blob
  # rootfs. The 64-bit wow64 wine still needs the lib32 copy for 32-bit PE games.
  WINE_PKGS="wine-staging winetricks cabextract libunwind lib32-libunwind \
    lib32-mesa lib32-vulkan-icd-loader lib32-vulkan-intel lib32-vulkan-radeon \
    lib32-libpulse lib32-alsa-lib lib32-gnutls lib32-libgcrypt lib32-libxcomposite \
    mesa vulkan-icd-loader vulkan-intel vulkan-radeon \
    wine-mono wine-gecko"
  pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -Sy --noconfirm --disable-sandbox filesystem >/dev/null
  pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -S --noconfirm --disable-sandbox ${WINE_PKGS}

  # wine + winetricks must run AT BUILD TIME (to make the prefix) -> install them in
  # the CONTAINER too (the blob rootfs has them, but we exec from the container).
  pacman -S --noconfirm --disable-sandbox --needed ${WINE_PKGS} >/dev/null 2>&1 || \
    pacman -S --noconfirm --disable-sandbox --needed wine-staging winetricks cabextract wine-mono wine-gecko

  # --- dxvk / vkd3d via the AUR makepkg-in-container path (build-app-blob.sh) -
  AUR=""
  [ "${DXVK}" = 1 ]  && AUR="${AUR} dxvk-bin"
  [ "${VKD3D}" = 1 ] && AUR="${AUR} vkd3d-proton-bin"
  if [ -n "${AUR}" ]; then
    pacman -S --noconfirm --disable-sandbox --needed --overwrite "*" base-devel git >/dev/null 2>&1 || \
      pacman -S --noconfirm --disable-sandbox --needed --overwrite "*" base-devel git
    useradd -m builder 2>/dev/null || true; echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
    for p in ${AUR}; do
      # An offline mirror (PB_MIRROR) can carry the AUR package prebuilt. If a repo
      # has it, install it from there. The public repos do not have it, so an online
      # build always takes the git clone path below.
      if pacman -Si "${p}" >/dev/null 2>&1; then
        pacman -S --noconfirm --disable-sandbox --overwrite "*" "${p}"
        continue
      fi
      sudo -u builder git clone --depth 1 "https://aur.archlinux.org/${p}.git" "/home/builder/${p}"
      # --skipchecksums: -bin pkgbases pin CI artifacts whose upstream sha drifts; we
      # verify the FINAL blob sha ourselves (same rationale as build-app-blob.sh).
      ( cd "/home/builder/${p}" && sudo -u builder makepkg -s --noconfirm --skippgpcheck --skipchecksums )
      pacman -U --noconfirm --disable-sandbox --overwrite "*" /home/builder/"${p}"/*.pkg.tar.zst 2>/dev/null || true
    done
  fi

  # --- stage the game into /opt/game ----------------------------------------
  GAME_DST="${ROOT}/opt/game"; mkdir -p "${GAME_DST}"
  SRC="/gamesrc/${GAME_BASE}"
  case "${GAME_BASE}" in
    *.zip)
      echo "[protonblob] extracting ${GAME_BASE}..." >&2
      unzip -q "${SRC}" -d "${GAME_DST}" ;;
    *)
      echo "[protonblob] copying game dir ${GAME_BASE}..." >&2
      cp -a "${SRC}/." "${GAME_DST}/" ;;
  esac

  # --- build the wineprefix TEMPLATE at /opt/prefix-template -----------------
  # WOW64 prefix (WINEARCH=win64, the default). wine-staging 10.x is wow64-ONLY - it
  # dropped the legacy pure-win32 build, so WINEARCH=win32 now aborts with "not
  # supported in wow64 mode". The 32-bit PE32 games (WC3, FlatOut2) still run fine:
  # wow64 wine thunks 32-bit calls inside the win64 prefix (drive_c/windows/syswow64
  # holds the 32-bit system dlls). mono+gecko are present in the CONTAINER so wineboot
  # installs them locally - NO network at the party. WINEDLLOVERRIDES kills the
  # mono/gecko install POPUPS during boot.
  # The prefix-template MUST be built UNDER ${ROOT} - that is the tree mksquashfs
  # squashes and run.sh copies from (${ROOT}/opt/prefix-template). Building it at the
  # container-absolute /opt/prefix-template put it OUTSIDE the squashfs -> the blob
  # shipped with the Wine runtime but an empty /opt (no prefix, no game). Stage it in
  # the rootfs so it actually lands in the blob.
  PREFIX_TPL="${ROOT}/opt/prefix-template"
  export WINEPREFIX="${PREFIX_TPL}" WINEDEBUG=-all
  export WINEDLLOVERRIDES="mscoree=;mshtml="
  # point wine at the bundled mono/gecko msi/cab so it never reaches out to the net.
  export WINEMONO="/usr/share/wine/mono" WINEGECKO="/usr/share/wine/gecko"
  echo "[protonblob] initializing wow64 wineprefix (mono+gecko baked) at ${PREFIX_TPL}..." >&2
  wineboot --init 2>&1 | tail -3 >&2 || true
  wineserver -w 2>/dev/null || true   # block until wineboot finishes writing the prefix
  # GATE: a wineprefix that booted writes system.reg + drive_c/windows/system32. If
  # wine could not start (e.g. a missing runtime lib like libunwind) wineboot silently
  # left an empty prefix and we would ship a blob that cannot launch the game. Fail the
  # build LOUDLY here instead - a broken proton blob must never reach the catalog.
  if [ ! -f "${PREFIX_TPL}/system.reg" ] || [ ! -d "${PREFIX_TPL}/drive_c/windows/system32" ]; then
    echo "[protonblob] FATAL wineprefix init failed (no system.reg / system32) - wine could not run in the build container" >&2
    exit 1
  fi
  # set the reported windows version (old games behave best as winxp).
  winetricks -q "${WINVER}" 2>/dev/null || wine reg add "HKCU\\Software\\Wine" /v Version /d "${WINVER}" /f 2>/dev/null || true

  # GENERIC modeset belt: tell the Wine X11 driver never to drive RandR/XVidMode mode
  # switches. The run.sh virtual desktop already keeps the game in a Wine-owned window,
  # but classic War3/D3D8 titles can still try a real fullscreen modeset; with these the
  # Wine X11 driver refuses, so the live nvidia Xorg mode is never switched out from
  # under the player. Baked for ALL games.
  wine reg add "HKCU\\Software\\Wine\\X11 Driver" /v UseXRandR  /d N /f 2>/dev/null || true
  wine reg add "HKCU\\Software\\Wine\\X11 Driver" /v UseXVidMode /d N /f 2>/dev/null || true

  # AUDIO: pin the wine audio backend to pulse so games hit the live pipewire-pulse
  # socket (the image runs pipewire-pulse per session; run.sh already binds /run/user
  # + XDG_RUNTIME_DIR/DBUS into the bwrap so the socket is reachable). Without this wine
  # auto-probes and may land on a backend that is not up. Baked for ALL games.
  wine reg add "HKCU\\Software\\Wine\\Drivers" /v Audio /d pulse /f 2>/dev/null || true

  # Per-game registry pins (WINE_REG_EXTRA): one `wine reg add` argument-set per line.
  # Used by the wc3 build to bake the Blizzard intro-movie/resolution keys that stop
  # war3.exe exiting after the splash. Empty for games that pass nothing.
  if [ -n "${WINE_REG_EXTRA:-}" ]; then
    while IFS= read -r regline; do
      [ -n "${regline}" ] || continue
      eval "wine reg add ${regline}" 2>/dev/null || true
    done <<< "${WINE_REG_EXTRA}"
  fi

  # game already extracted/copied into the rootfs /opt/game; ALSO place it in the
  # prefix template at drive_c/game so the player copy (run.sh cp -a) is the single
  # ready-to-run tree (game + wine state together). The squashfs dedups xz-side.
  # run.sh execs C:\game\<EXE_REL>, i.e. drive_c/game/<EXE_REL>, so the game tree must
  # sit DIRECTLY under drive_c/game (no extra wrapper dir). Some sources nest a single
  # top-level dir (a zip extracting to "Foo/..." or a macOS rsync doubling "FlatOut 2/
  # FlatOut 2/"); flatten exactly one redundant level so <EXE_REL> resolves.
  GAME_TPL="${PREFIX_TPL}/drive_c/game"
  mkdir -p "${GAME_TPL}"
  cp -a "${GAME_DST}/." "${GAME_TPL}/"
  # If the exe is NOT at ${GAME_TPL}/${EXE_REL} but the staged tree is a single dir that
  # CONTAINS ${EXE_REL}, hoist that dir up one level (handles the doubled-dir nesting).
  if [ ! -f "${GAME_TPL}/${EXE_REL}" ]; then
    only="$(find "${GAME_TPL}" -mindepth 1 -maxdepth 1 -printf "%f\n" | head -2)"
    if [ "$(printf "%s\n" "${only}" | wc -l)" = 1 ] && [ -n "${only}" ] && \
       [ -d "${GAME_TPL}/${only}" ] && [ -f "${GAME_TPL}/${only}/${EXE_REL}" ]; then
      echo "[protonblob] flattening redundant top-level dir [${only}]..." >&2
      mv "${GAME_TPL}/${only}" "${GAME_TPL}/.__hoist" && \
        ( shopt -s dotglob; mv "${GAME_TPL}/.__hoist"/* "${GAME_TPL}/" ) && \
        rmdir "${GAME_TPL}/.__hoist"
    fi
  fi

  # --- clean save dir: ship no builder profile, saves or settings ----------------
  # The staged game tree can hold the save dir of the machine that installed it (for
  # FlatOut 2: player*.sav with the builder name, options.sav, options.cfg, device.cfg
  # with the build machine audio device, the am*.dat key map). Every client starts from
  # this template, so every player would get that state. Empty the save dir (SAVE_REL)
  # and keep the dir itself. run.sh links it to the synced per-player SAVES dir.
  if [ -n "${SAVE_REL}" ] && [ -d "${GAME_TPL}/${SAVE_REL}" ]; then
    echo "[protonblob] emptying save dir [${SAVE_REL}] in the prefix-template..." >&2
    find "${GAME_TPL}/${SAVE_REL}" -mindepth 1 -delete
  fi

  # --- WC3 disc-check: present drive_c/game as a labelled CD-ROM (D:) ---------
  # Classic Warcraft III runs its no-CD-less disc check against a drive whose VOLUME
  # LABEL is WAR3X and whose TYPE is cdrom. Without it war3.exe pops "Please insert the
  # Warcraft III disc" and exits. Reproduce the working menu config: a DIRECTORY-backed
  # cdrom D: pointing at the game dir, labelled WAR3X.
  #  - dosdevices/d:  -> a RELATIVE symlink to ../drive_c/game/Warcraft III (the way
  #    wine itself writes drive links), so D:\ IS the game dir.
  #  - .windows-label inside that dir holds the 5 bytes WAR3X (NO trailing newline) -
  #    wine reads this file as the volume label, satisfying the WAR3X check.
  #  - [Software\Wine\Drives] "d:"="cdrom" marks D: as cdrom TYPE (not the default fixed).
  # CRITICAL: do NOT create dosdevices/d:: . A d:: link points at the backing UNIX device
  # (e.g. /dev/sr0); with no real disc that dangles and BREAKS the disc check. The
  # directory-backed cdrom must have ONLY d:, never d::.
  if [ "${NAME}" = wc3 ]; then
    echo "[protonblob] WC3: configuring directory-backed WAR3X cdrom on D:..." >&2
    mkdir -p "${PREFIX_TPL}/dosdevices"
    # relative link, like wine writes: dosdevices/ -> ../drive_c/game/...
    ln -snf "../drive_c/game/Warcraft III" "${PREFIX_TPL}/dosdevices/d:"
    # 5 bytes, NO newline (printf, not echo): the WAR3X volume label.
    printf 'WAR3X' > "${PREFIX_TPL}/drive_c/game/Warcraft III/.windows-label"
    # mark D: as cdrom type in the registry.
    wine reg add "HKLM\\Software\\Wine\\Drives" /v "d:" /d "cdrom" /f 2>/dev/null || true
    # belt-and-braces: ensure no dangling d:: device link exists.
    rm -f "${PREFIX_TPL}/dosdevices/d::" 2>/dev/null || true
  fi

  # --- FlatOut 2 D3DX9 effects framework: native d3dx9_30 --------------------
  # FlatOut2 compiles its FX shaders through the D3DX9 effects framework. Wine builtin
  # d3dx9_30 cannot compile them (fatal at startup). Install the NATIVE Microsoft
  # d3dx9_30.dll via winetricks: it drops the dll into syswow64 AND sets the
  # d3dx9_30=native DllOverride. winetricks + cabextract are in WINE_PKGS; the build
  # already fetches from the network (pacman), so the winetricks cab fetch is consistent
  # with the existing build network dependency. Verified verb: `d3dx9_30`.
  if [ "${NAME}" = flatout2 ]; then
    echo "[protonblob] FlatOut2: installing native d3dx9_30 via winetricks..." >&2
    winetricks -q d3dx9_30 2>&1 | tail -3 >&2 || true
    # GATE: the native dll must have landed in syswow64 (the 32-bit system dir of the
    # wow64 prefix). FlatOut2 is 32-bit, so the builtin would otherwise be used.
    if [ ! -f "${PREFIX_TPL}/drive_c/windows/syswow64/d3dx9_30.dll" ]; then
      echo "[protonblob] FATAL FlatOut2: native d3dx9_30.dll missing after winetricks - FX shaders will not compile" >&2
      exit 1
    fi
  fi

  # --- DXVK / vkd3d into the prefix ------------------------------------------
  if [ "${DXVK}" = 1 ]; then
    echo "[protonblob] installing DXVK into prefix..." >&2
    # setup_dxvk ships with dxvk-bin and is wow64-aware (puts x32 dlls in syswow64,
    # x64 in system32); falls back to copying by hand if it is absent. In a WOW64
    # prefix the 32-bit dxvk dlls go in syswow64 (NOT system32 - that holds the 64-bit
    # ones now), so the 32-bit games actually pick them up.
    ( command -v setup_dxvk >/dev/null 2>&1 && setup_dxvk install ) 2>/dev/null || \
    ( for d in d3d8 d3d9 d3d10core d3d11 dxgi; do
        for src in /usr/share/dxvk/x32/${d}.dll /usr/share/dxvk/${d}.dll.so; do
          [ -f "${src}" ] && cp "${src}" "${PREFIX_TPL}/drive_c/windows/syswow64/${d}.dll"
        done
        for src in /usr/share/dxvk/x64/${d}.dll; do
          [ -f "${src}" ] && cp "${src}" "${PREFIX_TPL}/drive_c/windows/system32/${d}.dll"
        done
      done ) 2>/dev/null || true
    wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v d3d9  /d native /f 2>/dev/null || true
    wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v d3d8  /d native /f 2>/dev/null || true
    wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v dxgi  /d native /f 2>/dev/null || true
    wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v d3d11 /d native /f 2>/dev/null || true
  fi
  if [ "${VKD3D}" = 1 ]; then
    ( command -v setup_vkd3d_proton >/dev/null 2>&1 && setup_vkd3d_proton install ) 2>/dev/null || true
  fi

  # FlatOut 2 ties physics to framerate -> bake a DXVK frame cap if MAXFPS is set.
  if [ -n "${MAXFPS}" ]; then
    printf "dxvk.maxFrameRate = %s\n" "${MAXFPS}" > "${PREFIX_TPL}/drive_c/dxvk.conf"
  fi

  wineserver -k 2>/dev/null || true; sleep 1

  # --- bake bin/run.sh + slim + meta -----------------------------------------
  mkdir -p "${ROOT}/bin"; echo "${RUNSH_B64}" | base64 -d > "${ROOT}/bin/run.sh"; chmod +x "${ROOT}/bin/run.sh"
  rm -rf "${ROOT}/var/lib/pacman/sync" "${ROOT}/var/cache" "${ROOT}/usr/share/man" "${ROOT}/usr/share/doc" 2>/dev/null || true
  # the prefix-template now holds drive_c/game; the separate /opt/game is redundant
  # (run.sh copies from the template). Drop it to save ~game-size in the blob.
  rm -rf "${ROOT}/opt/game" 2>/dev/null || true
  # shm_mb = 0: the overlay run.sh writes NO /dev/shm copy of the prefix. It overlays the
  # read-only baked prefix-template (compressed, page-cache, reclaimable) with a small
  # delta UPPER on the USB stick, so the real RAM cost of a launch is the working set +
  # headroom - NOT the old prefix-size-in-RAM charge that made an 8GB box project ~8GB and
  # refuse. overlay=1 tells partyos-ram to project the honest cost (ram_min + headroom).
  SHM_MB=0
  echo "[protonblob] overlay=1 shm_mb=0 (prefix is an overlayfs, no /dev/shm copy)" >&2
  # ram_min/max/title/marker make the blob launchable with NO catalog row (load-url):
  # marker matches what run.sh echoes ("PARTYOS-BLOB-RUN <name> ...") and the catalog row
  # (catalog.v2.json marker below), so a catalog-free launch verifies it the same way
  # cmd_launch greps. Values threaded via the docker -e env (TITLE/RAM_MIN/RAM_MAX).
  printf "id=%s\nname=%s\nentry=bin/run.sh\nkind=proton\noverlay=1\nram_min=%s\nram_max=%s\nshm_mb=%s\ntitle=%s\nmarker=%s\n" \
    "partyos.'"${NAME}"'" "${NAME}" "${RAM_MIN}" "${RAM_MAX}" "${SHM_MB}" "${TITLE}" "PARTYOS-BLOB-RUN ${NAME}" > "${ROOT}/game.meta"

  # --- HARD CONTENT GATE (the missing check that let an empty blob ship) -------
  # The wineprefix gate above only proves Wine RAN; it says NOTHING about the game
  # being present. The 537MB "runtime-only" blobs passed that gate yet had an empty
  # /opt. Assert, INSIDE ${ROOT} (the exact tree mksquashfs squashes), that the game
  # exe run.sh will exec is really there and the game tree is a sane size. Same lesson
  # as the OpenRA fix: gate on the CONTENT, not just the engine. Fail LOUDLY.
  GATE_EXE="${ROOT}/opt/prefix-template/drive_c/game/${EXE_REL}"
  if [ ! -f "${GATE_EXE}" ]; then
    echo "[protonblob] FATAL content gate: game exe missing at ${GATE_EXE}" >&2
    echo "[protonblob] drive_c/game contents:" >&2
    ls -la "${ROOT}/opt/prefix-template/drive_c/game" 2>&1 | head -40 >&2 || true
    exit 1
  fi
  GAME_BYTES="$(du -sb "${ROOT}/opt/prefix-template/drive_c/game" | cut -f1)"
  MIN_BYTES=$((100*1024*1024))   # >100MB: WC3 (~2.8G) and FlatOut2 dwarf this; a
                                 # runtime-only/empty staging never will.
  if [ "${GAME_BYTES}" -lt "${MIN_BYTES}" ]; then
    echo "[protonblob] FATAL content gate: staged game tree is only ${GAME_BYTES} bytes (< ${MIN_BYTES}) - game data did not land in the blob" >&2
    exit 1
  fi
  echo "[protonblob] content gate OK: ${EXE_REL} present, game tree $(du -sh "${ROOT}/opt/prefix-template/drive_c/game" | cut -f1)" >&2

  echo "[protonblob] rootfs size: $(du -sh ${ROOT} | cut -f1)" >&2
  # Export shm_mb to the host (the catalog.v2.json writer runs OUTSIDE the container and
  # has no prefix-template to measure). /out is bind-mounted to OUT_DIR, so a sidecar
  # file crosses the boundary cleanly. Read back + removed on the host after the build.
  printf '%s\n' "${SHM_MB}" > "/out/'"${NAME}"'.shm_mb"
  # OVERLAY OWNERSHIP: the run.sh overlays this prefix-template (read-only LOWER) with a
  # writable UPPER on the stick and runs wine as the UNPRIVILEGED desktop user (uid 1000).
  # overlayfs copy-up preserves the LOWER file ownership, so a root-owned template (the old
  # -all-root squashfs) would make every copy-up root-owned -> the user cannot write the
  # registry/saves and wine breaks. Bake the prefix-template uid-1000 (and DROP -all-root
  # below) so copy-up lands user-writable. The rest of the rootfs stays root (bwrap only
  # ro-binds /usr /etc, ownership is irrelevant for reads). Matches the desktop uid the
  # image provisions (1000) and the uid partyos-usbhome pre-creates .partyos-runcache with.
  chown -R 1000:1000 "${ROOT}/opt/prefix-template" 2>/dev/null || true
  mksquashfs "${ROOT}" "/out/'"${NAME}"'.squashfs" -comp xz -b 1048576 -Xdict-size 100% -noappend -no-progress >/dev/null
  sha256sum "/out/'"${NAME}"'.squashfs" | awk "{print \$1}" > "/out/'"${NAME}"'.squashfs.sha256"
  echo "[protonblob] blob: $(ls -lh /out/'"${NAME}"'.squashfs | awk "{print \$5}")" >&2
' 2>&1 | grep -vE "warning:|Parallel mksquashfs|fixme:|^[[:space:]]*$"
# PIPESTATUS[0] is docker's REAL exit code; the trailing grep always exits 0/1 on its
# own match state and would otherwise MASK a failed build (the prior run shipped a
# broken blob with outer rc=0). pipefail alone is not enough: grep -v returning 1
# (everything filtered) is not the same signal as docker failing, so check explicitly.
DOCKER_RC="${PIPESTATUS[0]}"
if [ "${DOCKER_RC}" -ne 0 ]; then
  echo "[protonblob] BUILD FAILED for ${NAME} (container exit ${DOCKER_RC})" >&2
  exit 1
fi

BLOB="${OUT_DIR}/${NAME}.squashfs"
[ -s "${BLOB}" ] || { echo "[protonblob] ERROR no blob produced" >&2; exit 1; }
SHA="$(cat "${BLOB}.sha256")"; SIZE="$(wc -c < "${BLOB}" | tr -d ' ')"
echo "[protonblob] ${NAME}: sha=${SHA:0:12}... size=${SIZE}" >&2
# Recover the real /dev/shm need the container measured (sidecar over the /out bind).
# Fall back to a size-derived estimate if the sidecar is somehow missing, so the
# catalog row always carries an honest shm_mb. The sidecar is then cleaned up.
SHM_MB="$(cat "${OUT_DIR}/${NAME}.shm_mb" 2>/dev/null | tr -dc '0-9')"
# Overlay blobs write NO /dev/shm copy, so shm_mb=0 is CORRECT (not "missing"). Only a
# truly absent/garbage sidecar falls back to 0 as well; partyos-ram projects the honest
# cost from ram_min because overlay=1 is set below.
case "${SHM_MB}" in ''|*[!0-9]*) SHM_MB=0;; esac
rm -f "${OUT_DIR}/${NAME}.shm_mb" 2>/dev/null || true
echo "[protonblob] ${NAME}: shm_mb=${SHM_MB} overlay=1 (prefix overlayed, no /dev/shm copy)" >&2

# --- wire the real sha/size into catalog.v2.json (tracked source of truth) -----
# marker MUST equal what run.sh echoes ("PARTYOS-BLOB-RUN <name> ...") so
# cmd_launch:2137 grep -F matches and logs PARTYOS-APP-LAUNCHED. proton:true marks a
# Proton blob; the rectangular parser ignores it.
# Update the catalog only when it's actually co-located (dev/deploy host). On a
# standalone build host (OUT_DIR elsewhere, no repo catalog here) skip cleanly - the
# blob + .sha256 are already written above and the deploy path updates the catalog
# separately, so don't crash on a missing path. CATALOG_V2 overrides the location.
V2="${CATALOG_V2:-${REPO_ROOT}/server/games/catalog.v2.json}"
if [ -f "${V2}" ]; then
NAME="${NAME}" TITLE="${TITLE}" CAT="${CATEGORY}" ID="${ID}" \
SHA="${SHA}" SIZE="${SIZE}" RMIN="${RAM_MIN}" RMAX="${RAM_MAX}" SHM="${SHM_MB}" python3 - "${V2}" <<'PY'
import json, os, sys
v2 = sys.argv[1]; d = json.load(open(v2))
name = os.environ["NAME"]
row = next((r for r in d.get("games", []) if r.get("name") == name), None)
new = dict(id=os.environ["ID"], name=name, title=os.environ["TITLE"], source="blob",
          blob="server/games/%s.squashfs" % name, sha256=os.environ["SHA"],
          size=int(os.environ["SIZE"]), ram_min=int(os.environ["RMIN"]),
          ram_max=int(os.environ["RMAX"]), shm_mb=int(os.environ["SHM"]),
          version="1.0.0", category=os.environ["CAT"],
          icon="/usr/share/pixmaps/partyos-games/%s.png" % name, exec="", pkg="", pkgs="",
          entry="bin/run.sh", marker="PARTYOS-BLOB-RUN %s" % name,
          needs_server=False, proton=True, overlay=True, hidden=False)
if row:
    # PRESERVE the hand-maintained access gate. hidden/unlock_code are how a non-free
    # title stays off the store until an operator hands out the code; a rebuild that
    # reset hidden to False would publish it to every player. Same reasoning as the
    # field-preserving update in build-app-blob.sh. Everything else the build derives.
    keep = {k: row[k] for k in ("hidden", "unlock_code") if k in row}
    row.update(new)
    row.update(keep)
else:
    d.setdefault("games", []).append(new)
json.dump(d, open(v2, "w"), indent=2)
print("[protonblob] catalog.v2.json updated for %s (sha %s)" % (name, os.environ["SHA"][:12]), file=sys.stderr)
PY
else
  echo "[protonblob] NOTE catalog not at ${V2} - skipped in-script catalog update (blob+sha written; the deploy path updates the catalog)" >&2
fi
echo "[protonblob] DONE ${NAME}. Run build-game-blobs.sh to regenerate catalog.json." >&2
