#!/usr/bin/env bash
# test-proton-runcache-reset.sh - hardware-free test: a new Proton blob
# resets the Wine registry in the stick upper of its prefix. No VM, no network, no hardware.
#
# A Proton blob runs its Wine prefix as an overlay: the baked opt/prefix-template is
# the lower dir, and /mnt/usbhome/.partyos-runcache/<name>/upper is the upper dir.
# The registry files in the upper hide the registry of a newer blob.
# partyos-app must:
#   1. remove the registry files from the upper when the baked registry changes,
#   2. keep the saves in the upper,
#   3. not touch the upper while the prefix overlay is mounted,
#   4. make uncache and reinstall cause a reset at the next mount.
# PAPP=<path> runs the test against another copy of partyos-app.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

PAPP="${PAPP:-${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-app}"
[ -s "${PAPP}" ] || { echo "FAIL: partyos-app not found at ${PAPP}"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-runcache.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

# Carve the functions under test (definition to the closing brace in column 0).
LIB="${T}/lib.sh"
for fn in mount_overlay runcache_sync cmd_uncache cmd_reinstall; do
    awk -v f="${fn}" '$0 ~ "^"f"\\(\\) \\{"{g=1} g{print} g&&/^\}/{exit}' "${PAPP}" >> "${LIB}"
done
for fn in mount_overlay runcache_sync cmd_uncache cmd_reinstall; do
    assert_eq "$(grep -c "^${fn}() {" "${LIB}")" "1" "partyos-app defines ${fn}"
done

# Environment of partyos-app, moved into the test dir.
APP_USER="$(id -un)"
HOME_DIR="${T}/home"
GAMES_DIR="${HOME_DIR}/games"
MNT_BASE="${T}/run/partyos-games"
STATE_DIR="${T}/state"
RUNCACHE_DIR="${T}/usbhome/.partyos-runcache"
PREFIX_REG_FILES="system.reg user.reg userdef.reg .update-timestamp"
SAY_LOG=""
say() { SAY_LOG="${SAY_LOG}${SAY_LOG:+|}$*"; }
# The paths in MOUNTED are mount points. mount and umount do nothing.
MOUNTED=""
mountpoint() { local p="${!#}"; case " ${MOUNTED} " in *" ${p} "*) return 0;; *) return 1;; esac; }
mount()  { return 0; }
umount() { return 0; }
chown()  { return 0; }
load_catalog() { return 1; }
resolve_idx()  { return 1; }
cache_dir()    { echo "${T}/cache"; }
a2()           { return 0; }
cmd_remove()   { return 0; }
# The reinstall must forget the hash before it mounts the blob again.
cmd_install()  { if [ -e "${RUNCACHE_DIR}/${1}/lower-id" ]; then echo kept > "${T}/install-saw"; else echo gone > "${T}/install-saw"; fi; }
# shellcheck disable=SC1090
source "${LIB}"

G=avp2
TPL="${MNT_BASE}/${G}/opt/prefix-template"
RC="${RUNCACHE_DIR}/${G}"
UP="${RC}/upper"
NAMEMARK="${HOME_DIR}/.cache/partyos-run/${G}/.partyos-name-${APP_USER}"
mkdir -p "${TPL}" "${UP}/drive_c/game/Save" "${RC}/work" "${RC}/prefix" "$(dirname "${NAMEMARK}")" "${T}/cache"

echo "================ 1. old stick upper, new blob: registry reset ===="
printf 'NEW "Disable Movies"=dword:1\n' > "${TPL}/system.reg"
printf 'baked user\n' > "${TPL}/user.reg"
printf 'OLD system\n' > "${UP}/system.reg"
printf 'OLD user\n'   > "${UP}/user.reg"
printf 'old ts\n'     > "${UP}/.update-timestamp"
printf 'save1\n'      > "${UP}/drive_c/game/Save/slot1.sav"
: > "${NAMEMARK}"
SAY_LOG=""; mount_overlay "${G}" "${T}/cache/${G}.squashfs"
assert_false "$([ -e "${UP}/system.reg" ]; echo $?)" "old system.reg is removed from the upper"
assert_false "$([ -e "${UP}/user.reg" ]; echo $?)" "old user.reg is removed from the upper"
assert_false "$([ -e "${UP}/.update-timestamp" ]; echo $?)" "old .update-timestamp is removed from the upper"
assert_eq "$(cat "${UP}/drive_c/game/Save/slot1.sav" 2>/dev/null)" "save1" "the save in the upper stays"
assert_true "$([ -s "${RC}/lower-id" ]; echo $?)" "lower-id is written"
assert_false "$([ -e "${NAMEMARK}" ]; echo $?)" "the player name marker is removed"
assert_contains "${SAY_LOG}" "PARTYOS-APP-PREFIX-RESET name=${G}" "the reset is logged"

echo "================ 2. same blob again: no reset ===================="
printf 'WINE WROTE THIS\n' > "${UP}/system.reg"
SAY_LOG=""; mount_overlay "${G}" "${T}/cache/${G}.squashfs"
assert_eq "$(cat "${UP}/system.reg" 2>/dev/null)" "WINE WROTE THIS" "the registry of the same blob stays"
assert_not_contains "${SAY_LOG}" "PREFIX-RESET" "no reset for the same blob"

echo "================ 3. prefix overlay mounted: no change ==========="
printf 'NEWER\n' >> "${TPL}/system.reg"
id_before="$(cat "${RC}/lower-id")"
MOUNTED="${RC}/prefix"
SAY_LOG=""; mount_overlay "${G}" "${T}/cache/${G}.squashfs"
MOUNTED=""
assert_eq "$(cat "${UP}/system.reg" 2>/dev/null)" "WINE WROTE THIS" "a mounted prefix keeps its upper"
assert_eq "$(cat "${RC}/lower-id")" "${id_before}" "a mounted prefix keeps lower-id"
assert_contains "${SAY_LOG}" "PREFIX-RESET-SKIP" "the skip is logged"

echo "================ 4. next mount after the skip: reset ============"
SAY_LOG=""; mount_overlay "${G}" "${T}/cache/${G}.squashfs"
assert_false "$([ -e "${UP}/system.reg" ]; echo $?)" "the changed blob registry resets the upper"

echo "================ 5. copy prefix (no overlay): baked file back ==="
printf 'copy\n' > "${RC}/prefix/.partyos-prefix-ready"
printf 'OLD copy\n' > "${RC}/prefix/system.reg"
printf 'NEWEST\n' >> "${TPL}/system.reg"
SAY_LOG=""; mount_overlay "${G}" "${T}/cache/${G}.squashfs"
assert_eq "$(cat "${RC}/prefix/system.reg")" "$(cat "${TPL}/system.reg")" "the copy gets the baked system.reg"
rm -f "${RC}/prefix/.partyos-prefix-ready" "${RC}/prefix/system.reg"

echo "================ 6. no runcache or no prefix-template: no-op ===="
SAY_LOG=""; mount_overlay "native" "${T}/cache/native.squashfs"
assert_false "$([ -e "${RUNCACHE_DIR}/native" ]; echo $?)" "a native blob gets no runcache dir"
assert_not_contains "${SAY_LOG}" "PREFIX-RESET" "a native blob gets no reset"

echo "================ 7. uncache and reinstall forget the hash ======="
printf 'WINE WROTE THIS\n' > "${UP}/system.reg"
cmd_uncache "${G}" >/dev/null
assert_false "$([ -e "${RC}/lower-id" ]; echo $?)" "uncache removes lower-id"
SAY_LOG=""; mount_overlay "${G}" "${T}/cache/${G}.squashfs"
assert_false "$([ -e "${UP}/system.reg" ]; echo $?)" "the mount after uncache resets the upper"
assert_true "$([ -s "${RC}/lower-id" ]; echo $?)" "lower-id is back after the mount"
cmd_reinstall "${G}" >/dev/null
assert_eq "$(cat "${T}/install-saw" 2>/dev/null)" "gone" "reinstall removes lower-id before the install"

assert_summary "test-proton-runcache-reset" || exit 1
echo "test-proton-runcache-reset: ALL PASS"
