#!/usr/bin/env bash
# stage-avp2.sh - stage Aliens versus Predator 2 for build-proton-blob.sh.
#
# AvP2 does not ship as a copyable game directory. It ships as four Windows
# installers, and build-proton-blob.sh takes a STAGED GAME DIR (the wc3/flatout2
# convention). This script is the missing step: it runs the four installers in a
# throwaway wineprefix, checks that each one applied, scrubs the player state, and
# leaves an installed tree that build-proton-blob.sh can bake.
#
# WHERE TO RUN IT. On a native x86_64 Linux host with wine and a live X display.
# It EXECUTES 32-bit Windows installers, so it cannot run on an arm64 Mac:
# Rosetta does not run 32-bit x86. Two of the four installers are 2002
# InstallShield archives whose silent mode is not documented, so the script tries
# silent first and falls back to an attended install you click through. On the first
# real run all three InstallShield updates ignored /s and showed their wizard, so
# expect to click Next, Next, Next, Finish for each of them.
#
# Usage:
#   stage-avp2.sh [src-dir] [dest-dir]
#     src-dir   holds the downloaded installer archives (default ~/Downloads/avp2-installers)
#     dest-dir  where the staged game tree lands (default ~/Downloads/avp2-staged)
#   Env knobs:
#     KEEP_PREFIX=1   keep the staging wineprefix for inspection (default: kept anyway)
#     SKIP_SHA=1      skip the archive checksum check (only for a re-download)
#
# Get the archives first with fetch-avp2-installers.sh.
#
# Next step, once this finishes:
#   bash scripts/build/build-proton-blob.sh avp2 ~/Downloads/avp2-staged "AVP2.exe" \
#        "Aliens versus Predator 2" 2048 4096
set -euo pipefail

SRC="${1:-${HOME}/Downloads/avp2-installers}"
DEST="${2:-${HOME}/Downloads/avp2-staged}"
WORK="${WORK:-${HOME}/.cache/partyos-avp2-stage}"
PFX="${WORK}/prefix"

# Pinned sizes + sha256 of the archives, recorded 2026-09-21 from avpunknown.com.
# A silent re-pack upstream would otherwise stage a different game than the one
# this recipe was written against.
AIO_ZIP="avp2_avp2ph_aio.exe.zip"
AIO_SHA="3b96e7609e86578e2606045bc5f5af43a007d123283acce3e9d39352561c8496"
U096_ZIP="avp2_en_096.zip"
U096_SHA="b1d8b4b1f00d23b4f8fa5c74465ff0c10f67e46d90904eb8b18ab0787604bab3"
SP1_ZIP="avp2_en_sp1.zip"
SP1_SHA="b1e87afa53f8822e7f6efbfbeb257235880daecddec133f8bfe1094592e8e5ba"
MP1_ZIP="avp2_en_mp1.zip"
MP1_SHA="c0fbadd8e2a779488a6946d5c01beeb1dec926da639013f4aac22c6aed992ead"

say() { echo "[avp2] $*" >&2; }
die() { echo "[avp2] FATAL $*" >&2; exit 1; }

case "$(uname -m)" in
    x86_64|amd64) : ;;
    *) die "this host is $(uname -m). The installers are 32-bit x86 and must run on a native x86_64 Linux host." ;;
esac
command -v wine >/dev/null || die "wine not found. Install wine-staging."
command -v unzip >/dev/null || die "unzip not found."
[ -n "${DISPLAY:-}" ] || say "WARNING DISPLAY is not set. A silent install may work; an attended fallback will not."

check_sha() {
    local f="$1" want="$2"
    [ -f "${f}" ] || die "missing archive ${f} - run fetch-avp2-installers.sh"
    [ "${SKIP_SHA:-0}" = 1 ] && return 0
    local got; got="$(sha256sum "${f}" | awk '{print $1}')"
    [ "${got}" = "${want}" ] || die "sha256 mismatch on $(basename "${f}") (got ${got})"
}

say "checking the archives in ${SRC}"
check_sha "${SRC}/${AIO_ZIP}"  "${AIO_SHA}"
check_sha "${SRC}/${U096_ZIP}" "${U096_SHA}"
check_sha "${SRC}/${SP1_ZIP}"  "${SP1_SHA}"
check_sha "${SRC}/${MP1_ZIP}"  "${MP1_SHA}"

# --- unpack the installers ---------------------------------------------------
INST="${WORK}/installers"
rm -rf "${INST}"; mkdir -p "${INST}"
say "unpacking the installers into ${INST}"
# The AIO zip carries the whole package (manual, tools, Primal Hunt). We only need
# the base-game installer; the updates come from their own archives so the recipe
# stays explicit about which version it applies.
AIO_MEMBER="All In One (AVP2)/Aliens vs. Predator 2/Aliens vs. Predator 2 - Full Game/Aliens vs. Predator 2.exe"
unzip -joq "${SRC}/${AIO_ZIP}" "${AIO_MEMBER}" -d "${INST}" \
    || die "could not extract the full-game installer from ${AIO_ZIP}"
unzip -joq "${SRC}/${U096_ZIP}" "avp2_en_096.exe" -d "${INST}"
unzip -joq "${SRC}/${SP1_ZIP}"  "avp2_en_sp1.exe" -d "${INST}"
unzip -joq "${SRC}/${MP1_ZIP}"  "avp2_en_mp1.exe" -d "${INST}"
ls -la "${INST}" >&2

# --- a clean staging wineprefix ----------------------------------------------
# winxp: the game is a 2001 title and its installers check the Windows version.
# This prefix is a SCRATCH prefix for the install only. The blob gets its own clean
# prefix from build-proton-blob.sh, so nothing from here is shipped except the
# installed game tree.
export WINEPREFIX="${PFX}" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml="
if [ ! -f "${PFX}/system.reg" ]; then
    say "initializing the staging wineprefix at ${PFX}"
    mkdir -p "${PFX}"
    wineboot --init >/dev/null 2>&1 || true
    wineserver -w || true
    [ -f "${PFX}/system.reg" ] || die "wineprefix init failed - wine cannot run here"
    wine reg add "HKCU\\Software\\Wine" /v Version /d winxp /f >/dev/null 2>&1 || true
fi

GAME_WIN='C:\Games\AvP2'
GAME_UNIX="${PFX}/drive_c/Games/AvP2"

# find_game sets GAME_UNIX to the directory that holds AVP2.exe. The AIO installer
# ignores /D= and installs to C:\Program Files (x86)\Aliens vs. Predator 2 (seen
# on the first real run), so the script finds the tree by its exe, not by a path.
find_game() {
    local f
    f="$(find "${PFX}/drive_c" -maxdepth 4 -type f -iname AVP2.exe -print -quit 2>/dev/null)"
    [ -n "${f}" ] || return 1
    GAME_UNIX="$(dirname "${f}")"
}

run_installer() {
    # run_installer <exe> <silent-args> <probe> <human-description>
    # The probe is a shell test that returns 0 once the installer has applied.
    local exe="$1" silent="$2" probe="$3" desc="$4"
    if eval "${probe}"; then say "${desc}: already applied, skipping"; return 0; fi
    say "${desc}: trying a silent install"
    # Split the silent args on spaces WITHOUT eval. An eval removes the backslashes
    # from /D=C:\Games\AvP2, and NSIS then installs to the wrong path.
    local -a sargs; read -r -a sargs <<< "${silent}"
    ( cd "${INST}" && timeout 3600 wine "${exe}" "${sargs[@]}" ) >/dev/null 2>&1 || true
    wineserver -w || true
    # InstallShield ignores /s and shows its wizard. If you click it through during
    # this step, the probe passes here, so do not read this message as "no wizard".
    if eval "${probe}"; then say "${desc}: applied during the silent step"; return 0; fi
    # ATTENDED FALLBACK. Warning: the installer window opens now. Take every
    # default and close the installer when it finishes.
    say "${desc}: the silent install did not take. Starting it ATTENDED."
    say "${desc}: take the default install path (the game is at ${GAME_UNIX} if it is installed)"
    [ -n "${DISPLAY:-}" ] || die "${desc} needs an attended install but DISPLAY is not set"
    ( cd "${INST}" && wine "${exe}" ) || true
    wineserver -w || true
    eval "${probe}" || die "${desc} did not apply. Check ${PFX} and rerun."
    say "${desc}: attended install OK"
}

# 1. base game. The AIO full-game exe is NSIS 3.0, so /S is a silent install.
#    It ignores /D=, so find_game locates the tree after the install.
#    The AIO build has the no-CD built in, so no disc and no CD key are needed.
run_installer "Aliens vs. Predator 2.exe" "/S /D=${GAME_WIN}" \
    'find_game' "base game"

# Each update leaves its own readme next to the files it writes (seen on the first
# real run). The readme is the check that the update landed. It also makes a rerun
# skip an update that is already applied, so a rerun needs no extra wizard clicks.
# An earlier version compared a digest of the tree before and after. That failed on
# a rerun: the update wrote identical files, so the digest did not change.

# 2. the official 1.0.9.6 update. InstallShield self-extracting archive. It has no
#    response file, so /s does not make it silent: click its wizard through. It
#    finds the base game through the registry of the staging prefix.
run_installer "avp2_en_096.exe" "/s /sms" \
    '[ -f "${GAME_UNIX}/readme1096.txt" ]' "1.0.9.6 update"

# 3. single-player map update 1. It replaces AVP2SP.REZ and adds readmesp1.txt.
run_installer "avp2_en_sp1.exe" "/s /sms" \
    '[ -f "${GAME_UNIX}/readmesp1.txt" ] && [ -f "${GAME_UNIX}/AVP2SP.REZ" ]' \
    "SP map update 1"

# 4. multiplayer map update 1. It adds its ten MP levels packed in AVP2P.REZ, next
#    to its readme readmemp1.txt. No level file is unpacked on disk, so these two
#    files are the check that the update landed (seen on the first real run).
run_installer "avp2_en_mp1.exe" "/s /sms" \
    '[ -f "${GAME_UNIX}/AVP2P.REZ" ] && [ -f "${GAME_UNIX}/readmemp1.txt" ]' \
    "MP map update 1"

# --- verify, scrub, stage ----------------------------------------------------
find_game || die "no AVP2.exe under ${PFX}/drive_c"
say "installed tree: $(du -sh "${GAME_UNIX}" | cut -f1)"

# The proton blob ships this tree to EVERY player, so it must carry no builder
# state. FlatOut 2 once shipped the builder profile and settings because the build baked a played prefix.
say "scrubbing builder state from the staged tree"
rm -rf "${GAME_UNIX}/Save" "${GAME_UNIX}/Saves" 2>/dev/null || true
# Keep Profiles\Default.prf. The base installer ships it, and the game reads it to
# make the first player profile. Without it, the game uses an uninitialized binding
# table and lithtech.exe crashes in cshell.dll at PLAY. Remove only the player profiles.
find "${GAME_UNIX}/Profiles" -type f ! -iname "Default.prf" -delete 2>/dev/null || true
# An earlier version of this script deleted Profiles/. If the staging prefix comes
# from that version, the installers are skipped and the file is missing. Then get it
# from the base-game installer (an NSIS archive) with 7z.
if ! ls "${GAME_UNIX}/Profiles/"[Dd]efault.prf >/dev/null 2>&1; then
    command -v 7z >/dev/null \
        || die "Profiles/Default.prf is missing. Install 7zip, or remove ${WORK} and run again."
    say "Profiles/Default.prf is missing: extracting it from the base-game installer"
    mkdir -p "${GAME_UNIX}/Profiles"
    7z e -y -o"${GAME_UNIX}/Profiles" "${INST}/Aliens vs. Predator 2.exe" "Profiles/Default.prf" >/dev/null \
        || die "could not extract Profiles/Default.prf from the base-game installer"
fi
ls "${GAME_UNIX}/Profiles/"[Dd]efault.prf >/dev/null 2>&1 \
    || die "Profiles/Default.prf is missing from the installed tree. The game crashes at PLAY without it."
# Keep autoexec.cfg: the base game ships it (dated 2001) with the default settings,
# and this script never runs the game, so it holds no builder state.
find "${GAME_UNIX}" -maxdepth 2 \( -iname "*.sav" -o -iname "display.cfg" \
    -o -iname "*.log" \) -delete 2>/dev/null || true

rm -rf "${DEST}"; mkdir -p "${DEST}"
cp -a "${GAME_UNIX}/." "${DEST}/"
say "staged to ${DEST} ($(du -sh "${DEST}" | cut -f1))"

# The installers write an install path and a version under HKLM. The blob builds a
# FRESH prefix and only copies the game tree, so those keys do not travel. Dump them
# here: if the game fails to start in the blob, feed them back with WINE_REG_EXTRA.
REGDUMP="${DEST}.registry.txt"
grep -a -i -A12 -E "Fox|Monolith|Aliens|Predator|Lithtech" "${PFX}/system.reg" > "${REGDUMP}" 2>/dev/null || true
say "AvP2 registry keys from the staging prefix: ${REGDUMP}"

cat >&2 <<EOF
[avp2] DONE. Next:
[avp2]   bash scripts/build/build-proton-blob.sh avp2 "${DEST}" "AVP2.exe" \\
[avp2]        "Aliens versus Predator 2" 2048 4096
[avp2]   bash scripts/build/build-game-blobs.sh
[avp2] Then unhide the catalog row (set hidden/unlock_code) and regenerate the torrents.
EOF
