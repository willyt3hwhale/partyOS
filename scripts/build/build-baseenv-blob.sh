#!/usr/bin/env bash
# build-baseenv-blob.sh - build the BASE proton-env blob for partyOS by REPACKING an
# existing proton game blob. NO x86 needed: this only unsquashfs/strip/repack
# (no wine/wineboot runs), so it works on a macOS/arm64 host.
#
# The base env is a reusable Wine RUNTIME + a PRISTINE wine prefix (NO baked game).
# The on-client engine clones the pristine prefix per env and drives bin/run.sh with
# env vars (PARTYOS_ENV_PREFIX / PARTYOS_RUN_EXE ...) to install/run arbitrary windows
# programs - the operator picks the exe at runtime instead of it being baked in.
#
# Source: an existing proton blob (flatout2.squashfs is the cleaner one). It already
# bundles the whole wine runtime under usr/ (wine/wineserver/wineboot + the lib32
# GL/Vulkan closure) and a fully-initialized prefix at opt/prefix-template/ (system.reg,
# user.reg, drive_c/windows with DXVK in syswow64, mono/gecko). We strip the baked GAME
# out of the template, swap in a parameterized launcher, and re-squash.
#
# Usage: build-baseenv-blob.sh [SRC_BLOB]
#   SRC_BLOB  source proton blob to repack (default: server/games/flatout2.squashfs)
# Output: server/games/protonenv.squashfs + .sha256 (both gitignored).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/server/games}"
SRC="${1:-${OUT_DIR}/flatout2.squashfs}"
NAME="protonenv"
BLOB="${OUT_DIR}/${NAME}.squashfs"

# --- preflight --------------------------------------------------------------
command -v unsquashfs >/dev/null 2>&1 || { echo "[baseenv] ERROR unsquashfs required (squashfs-tools)" >&2; exit 1; }
command -v mksquashfs >/dev/null 2>&1 || { echo "[baseenv] ERROR mksquashfs required (squashfs-tools)" >&2; exit 1; }
command -v sha256sum  >/dev/null 2>&1 || { echo "[baseenv] ERROR sha256sum required" >&2; exit 1; }
[ -s "${SRC}" ] || { echo "[baseenv] ERROR source blob not found: ${SRC}" >&2; exit 1; }
mkdir -p "${OUT_DIR}"

# --- work area: a CASE-SENSITIVE disk image --------------------------------
# The source rootfs has files that differ only in case (e.g. usr/include kernel
# headers xt_CONNMARK.h vs xt_connmark.h), which collide on the default
# case-INSENSITIVE APFS of macOS and make unsquashfs abort. Extract into a case-sensitive
# image instead so the whole tree lands faithfully. This stays fully arm64-native:
# the homebrew squashfs-tools just shuffle files (NO x86 wine/wineboot is executed),
# so no x86 and no wineprefix init is needed - the repack runs on an arm64 host as-is.
WORK_IMG=""; MNT=""
cleanup() {
    [ -n "${MNT}" ] && hdiutil detach "${MNT}" -force >/dev/null 2>&1 || true
    [ -n "${MNT}" ] && rmdir "${MNT}" 2>/dev/null || true
    [ -n "${WORK_IMG}" ] && rm -f "${WORK_IMG}" 2>/dev/null || true
}
trap cleanup EXIT

WORK_IMG="$(mktemp -u /tmp/partyos-baseenv.XXXXXX).sparseimage"
MNT="/tmp/partyos-baseenv.mnt.$$"
echo "[baseenv] repacking '${SRC}' -> '${BLOB}'" >&2
echo "[baseenv] creating case-sensitive work image (${WORK_IMG})..." >&2
hdiutil create -size 16g -type SPARSE -fs 'Case-sensitive HFS+' \
    -volname partyos-baseenv -quiet "${WORK_IMG}" \
    || { echo "[baseenv] ERROR hdiutil create failed" >&2; exit 1; }
mkdir -p "${MNT}"
hdiutil attach "${WORK_IMG}" -mountpoint "${MNT}" -nobrowse -quiet \
    || { echo "[baseenv] ERROR hdiutil attach failed" >&2; exit 1; }

# --- 1. extract the source proton blob -------------------------------------
ROOT="${MNT}/baseenv"
echo "[baseenv] extracting source blob..." >&2
unsquashfs -d "${ROOT}" "${SRC}" >/dev/null
TPL="${ROOT}/opt/prefix-template"
[ -d "${TPL}" ] || { echo "[baseenv] ERROR no opt/prefix-template in source blob" >&2; exit 1; }
[ -x "${ROOT}/usr/bin/wine" ] || { echo "[baseenv] ERROR no usr/bin/wine in source blob" >&2; exit 1; }

# --- 2. strip the baked game (keep the wine system + DXVK) ------------------
# Only remove what is CLEARLY game-specific. The wine runtime, the windows system
# dlls, DXVK in syswow64 and mono/gecko all STAY - those make the env reusable.
#   - drive_c/game        the baked game tree itself (definitely game-specific).
#   - drive_c/dxvk.conf   a per-game DXVK tweak (e.g. flatout2's framerate cap).
#   - .partyos-prefix-ready  the runtime "complete copy" marker, never baked but
#                            removed defensively so the on-client clone re-marks.
# NOTE: the native d3dx9_30.dll + DllOverride is INTENTIONALLY kept - a native D3DX9
# runtime is generically useful across windows games and harmless in a base env, and
# unwinding the user.reg override risks corrupting the pristine prefix. Conservative.
echo "[baseenv] stripping baked game from prefix-template..." >&2
# extracted as non-root: some dirs keep restrictive (no-write) modes -> add owner-write
# on the game subtree so rm can unlink it. Only the deleted tree is touched, so the
# repacked blob's modes stay faithful elsewhere.
chmod -R u+w "${TPL}/drive_c/game" 2>/dev/null || true
rm -rf "${TPL}/drive_c/game"
rm -f  "${TPL}/drive_c/dxvk.conf"
rm -f  "${TPL}/.partyos-prefix-ready"
# the old proton launcher's per-game dosdevices cdrom (wc3's D:) - drop if present.
rm -f  "${TPL}/dosdevices/d:" "${TPL}/dosdevices/d::" 2>/dev/null || true
[ -d "${TPL}/drive_c/game" ] && { echo "[baseenv] ERROR game dir still present after strip" >&2; exit 1; }

# --- 3. bake the PARAMETERIZED launcher over usr/bin/run.sh -----------------
# bin/run.sh is the entry the engine execs; /bin is a symlink to usr/bin in the blob,
# so the real file lives at usr/bin/run.sh. Authored as a SINGLE-QUOTED heredoc so NO
# build-time expansion happens - every $ survives literally into the file.
RUNSH_DST="${ROOT}/usr/bin/run.sh"
echo "[baseenv] baking parameterized run.sh -> usr/bin/run.sh..." >&2
cat > "${RUNSH_DST}" <<'PARTYOS_RUNSH'
#!/bin/bash
# partyOS BASE proton-env launcher. Reuses the proton-blob bwrap mechanics but is
# driven by ENV VARS instead of a baked-in game, so the on-client engine can install
# and run arbitrary windows programs against a supplied wine prefix.
#
# Env-var contract:
#   PARTYOS_ENV_PREFIX  (REQUIRED) absolute path to the writable wine prefix to use as
#                       WINEPREFIX (e.g. /mnt/usbhome/.partyos-proton-envs/<name>/prefix).
#                       Used DIRECTLY (no runcache clone). The engine normally pre-clones
#                       opt/prefix-template into it; a fallback below seeds it if empty.
#   PARTYOS_RUN_EXE     (REQUIRED) program to run. A windows path (drive letter / has
#                       backslashes) is passed to wine as-is; a unix absolute path is
#                       passed to wine directly (wine accepts unix paths).
#   PARTYOS_RUN_ARGS    (optional) extra args appended to the exe, split on whitespace
#                       (operator/engine-controlled, e.g. "/S" or "/VERYSILENT").
#   PARTYOS_RUN_CWD     (optional) unix dir to chdir into; default = the exe's own dir
#                       for a unix path, else the prefix drive_c.
# Echoes the marker "PARTYOS-PROTONENV exec=wine <exe>" then execs wine inside bwrap.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
U="$(id -u)"

PREFIX="${PARTYOS_ENV_PREFIX:-}"
if [ -z "${PREFIX}" ]; then
    echo "partyos-protonenv: PARTYOS_ENV_PREFIX is required (writable WINEPREFIX dir)" >&2
    exit 2
fi
RUN_EXE="${PARTYOS_RUN_EXE:-}"
if [ -z "${RUN_EXE}" ]; then
    echo "partyos-protonenv: PARTYOS_RUN_EXE is required (program to run)" >&2
    exit 2
fi
RUN_ARGS="${PARTYOS_RUN_ARGS:-}"
RUN_CWD="${PARTYOS_RUN_CWD:-}"

# Per-run writable scratch (nvidia ICD + shader cache). There is no RUNHOME here, so it
# lives beside the prefix (the one guaranteed-writable location).
SCRATCH="${PREFIX%/}/.partyos-run"
mkdir -p "${SCRATCH}"

# SAFETY NET: the engine normally pre-clones the pristine prefix-template into PREFIX
# before launch. If PREFIX is missing/empty and not marked ready, seed it from the baked
# template (cp -a) then mark it - so a bare invocation still works.
if [ ! -f "${PREFIX}/.partyos-prefix-ready" ]; then
    if [ ! -e "${PREFIX}" ] || [ -z "$(ls -A "${PREFIX}" 2>/dev/null)" ]; then
        echo "partyos-protonenv: seeding pristine prefix into ${PREFIX} (fallback)" >&2
        rm -rf "${PREFIX}"
        if cp -a "${ROOT}/opt/prefix-template" "${PREFIX}"; then
            touch "${PREFIX}/.partyos-prefix-ready"
        else
            echo "partyos-protonenv: prefix seed failed" >&2
            exit 1
        fi
    fi
fi

# DXVK native (d3d8/9/10/11 + dxgi), mono/gecko install popups off. Mirrors the proton
# DLLOVERRIDES default.
DLLOVERRIDES="mscoree=;mshtml=;d3d8,d3d9,d3d10core,d3d11,dxgi=n"

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
# Expose the data stick RO so an operator/engine-picked installer on it resolves inside
# the sandbox. The wine prefix (rw) is bound LAST, below, so it survives this mount.
args+=( --ro-bind-try /mnt/usbhome /mnt/usbhome )
# if the exe is a unix path, also expose its directory (a download outside both $HOME
# and /mnt/usbhome). $HOME is already rw-bound; /mnt/usbhome already ro-bound.
case "${RUN_EXE}" in
    [A-Za-z]:\\*|*\\*) : ;;
    /*) EXE_DIR="$(dirname "${RUN_EXE}")"
        [ -d "${EXE_DIR}" ] && args+=( --ro-bind-try "${EXE_DIR}" "${EXE_DIR}" ) ;;
esac
# the wine prefix is OUTSIDE $HOME (engine puts it on the data stick, UNDER /mnt/usbhome).
# Bind it RW *after* the /mnt/usbhome (and EXE_DIR) ro-binds: bwrap applies binds in order
# and a later child bind wins over an earlier parent mount, so the prefix stays writable.
# Binding it BEFORE the ro parent leaves it read-only and wineserver fails to write the
# registry/installs ("could not save registry branch ... Read-only file system").
args+=( --bind "${PREFIX}" "${PREFIX}" )
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
        --setenv MESA_SHADER_CACHE_DIR "${SCRATCH}/shadercache"
        --die-with-parent --new-session )

# --- nvidia GPU passthrough (host-driver, conditional) ----------------------
# The blob /usr ships no nvidia driver and no nvidia Vulkan ICD. If the host has an
# nvidia GPU, expose the HOST userspace driver into /nvidia and point the Vulkan loader
# at a generated ICD over it. Skipped on non-nvidia hosts (Mesa-in-the-blob handles
# intel/amd). ICD goes in SCRATCH (no RUNHOME here).
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
        for so in "${NVLIB}"/libnvidia-*.so* \
                  "${NVLIB}"/libGLX_nvidia.so* "${NVLIB}"/libEGL_nvidia.so* \
                  "${NVLIB}"/libGLESv1_CM_nvidia.so* "${NVLIB}"/libGLESv2_nvidia.so* \
                  "${NVLIB}"/libcuda.so* "${NVLIB}"/libnvcuvid.so* "${NVLIB}"/libnvoptix.so*; do
            [ -e "${so}" ] && args+=( --ro-bind "${so}" "/nvidia/$(basename "${so}")" )
        done
        printf "{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"/nvidia/libGLX_nvidia.so.0\",\"api_version\":\"1.4.0\"}}\n" \
            > "${SCRATCH}/nvidia_icd.json"
        args+=( --ro-bind "${SCRATCH}/nvidia_icd.json" /nvidia/nvidia_icd.json
                --setenv VK_DRIVER_FILES /nvidia/nvidia_icd.json
                --setenv VK_ICD_FILENAMES /nvidia/nvidia_icd.json
                --setenv LD_LIBRARY_PATH /nvidia
                --setenv __GLX_VENDOR_LIBRARY_NAME nvidia )
        [ "$NV_MODE" = offload ] && args+=( --setenv __NV_PRIME_RENDER_OFFLOAD 1
                --setenv __VK_LAYER_NV_optimus NVIDIA_only )
    fi
fi

# --- Wine virtual desktop (real-hardware modeset guard) ---------------------
# Run wine inside a virtual desktop so a fullscreen game/installer becomes a Wine-owned
# window sized to the real monitor, instead of a REAL RandR modeset that would switch
# the live X server out from under the player. Size it to the host primary output (we
# still have DISPLAY/XAUTHORITY here, before bwrap); fall back to 1920x1080.
DESK_RES="$(xrandr 2>/dev/null | awk '
    / connected/ {
        for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) {
            if ($0 ~ / connected primary /) { print $i; exit }
            if (!r) r=$i
        }
    }
    END { if (r) print r }' | sed 's/+.*//')"
case "${DESK_RES}" in *[0-9]x[0-9]*) : ;; *) DESK_RES="1920x1080" ;; esac

# --- resolve the exe form + working dir -------------------------------------
# A windows path (drive letter or backslashes) is handed to wine as-is; a unix path is
# handed to wine directly. The chdir dir defaults to the exe's own dir for a unix path,
# else the prefix drive_c.
EXE="${RUN_EXE}"
case "${RUN_EXE}" in
    [A-Za-z]:\\*|*\\*) CWD_DEFAULT="${PREFIX}/drive_c" ;;
    /*)                CWD_DEFAULT="$(dirname "${RUN_EXE}")" ;;
    *)                 CWD_DEFAULT="${PREFIX}/drive_c" ;;
esac
CWD="${RUN_CWD:-${CWD_DEFAULT}}"
[ -d "${CWD}" ] || CWD="${PREFIX}/drive_c"

# operator/engine-controlled extra args (NOT user free-text) - intentional word-split,
# globbing off so a literal * in an arg is not expanded.
set -f
# shellcheck disable=SC2206
EXTRA_ARGS=( ${RUN_ARGS} )
set +f

echo "PARTYOS-PROTONENV exec=wine ${RUN_EXE}"
exec bwrap "${args[@]}" --chdir "${CWD}" wine explorer /desktop="partyos,${DESK_RES}" "${EXE}" "${EXTRA_ARGS[@]}"
PARTYOS_RUNSH
chmod +x "${RUNSH_DST}"

# --- 4. write game.meta (mirrors the proton meta shape; no baked game) ------
# shm_mb mirrors the proton shape (prefix-template size + 1024 headroom, floored) even
# though the base env run.sh does NOT copy the prefix into /dev/shm (it uses the engine-
# supplied prefix directly) - kept for a consistent gate projection.
PREFIX_MB="$(du -sm "${TPL}" 2>/dev/null | cut -f1)"
case "${PREFIX_MB}" in ""|*[!0-9]*) PREFIX_MB=2048;; esac
SHM_MB=$(( PREFIX_MB + 1024 ))
[ "${SHM_MB}" -ge 1024 ] 2>/dev/null || SHM_MB=2048
RAM_MIN=1024
RAM_MAX=4096
TITLE="Proton Env Base"
MARKER="PARTYOS-PROTONENV"
printf "id=%s\nname=%s\nentry=bin/run.sh\nkind=proton\nram_min=%s\nram_max=%s\nshm_mb=%s\ntitle=%s\nmarker=%s\n" \
    "${NAME}" "${NAME}" "${RAM_MIN}" "${RAM_MAX}" "${SHM_MB}" "${TITLE}" "${MARKER}" > "${ROOT}/game.meta"
echo "[baseenv] game.meta: ram_min=${RAM_MIN} ram_max=${RAM_MAX} shm_mb=${SHM_MB} marker=${MARKER}" >&2

# --- 5. repack with the SAME comp/block opts the proton build uses ----------
# Owner-read belt: unsquashfs ran as a non-root user, so a file whose baked mode denies
# OWNER read (e.g. usr/lib/dbus-daemon-launch-helper is ---s--x---) cannot be read back
# by mksquashfs (we ARE the owner now, unlike root in the original container build) and
# would be silently squashed as an EMPTY file. Add owner-read to any such file first so
# its real content lands in the blob. -all-root restores root ownership in the output.
find "${ROOT}" -type f ! -perm -u+r -exec chmod u+r {} + 2>/dev/null || true
echo "[baseenv] mksquashfs (xz, 1MiB blocks)..." >&2
# -no-xattrs: macOS stamps com.apple.provenance xattrs on extracted files; without
# this mksquashfs floods warnings AND bakes that Apple metadata into the blob. The wine
# runtime needs no file xattrs (it runs under bwrap, no setcap-dependent tools), so drop
# them for a clean Linux-appropriate blob. (Other proton blobs are built on Linux where
# this question never arises - this is the macOS-repack adaptation of the same flags.)
mksquashfs "${ROOT}" "${BLOB}" -comp xz -b 1048576 -Xdict-size 100% -all-root -no-xattrs -noappend -no-progress >/dev/null

# --- 6. sha256 (bare hash, matching the existing server/games/*.sha256) -----
sha256sum "${BLOB}" | awk '{print $1}' > "${BLOB}.sha256"
SHA="$(cat "${BLOB}.sha256")"
SIZE="$(wc -c < "${BLOB}" | tr -d ' ')"

echo "[baseenv] DONE ${NAME}: size=${SIZE} bytes ($(ls -lh "${BLOB}" | awk '{print $5}')) sha=${SHA}" >&2
echo "[baseenv] shm_mb=${SHM_MB} ram_min=${RAM_MIN} ram_max=${RAM_MAX}" >&2
# emit machine-readable summary on stdout for callers wiring the catalog row.
printf 'name=%s\nblob=server/games/%s.squashfs\nsha256=%s\nsize=%s\nram_min=%s\nram_max=%s\nshm_mb=%s\nmarker=%s\n' \
    "${NAME}" "${NAME}" "${SHA}" "${SIZE}" "${RAM_MIN}" "${RAM_MAX}" "${SHM_MB}" "${MARKER}"
