#!/usr/bin/env bash
# test-pacman-db-refresh.sh - hardware-free guard for the client pacman sync db refresh.
#
# A package added to the LAN mirror after a client booted must be installable with no
# manual step. This test asserts:
#   1. partyos-mirror-setup runs "pacman -Sy --noconfirm" at boot: no -u, no targets.
#   2. If the sync fails, partyos-mirror-setup logs PARTYOS-MIRROR-SETUP-SYNC-FAILED
#      and exits 0 (offline-safe).
#   3. partyos-mirror.service runs after network-online.target with a start timeout.
#   4. partyos-pkg-install runs pacman -Sy before each install and never -u.
#   5. The image and the mirror pin the same default SNAPSHOT, so -Sy without -u
#      cannot cause a partial upgrade.
# No VM, no network, no hardware.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

ROOTFS="${REPO_ROOT}/scripts/build/files/rootfs"
BIN="${ROOTFS}/usr/local/bin"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-dbrefresh-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# Rewrite only the file locations to stand-ins. The script logic is the real code.
echo "quiet report_url=https://srv.example:8443" > "${TMP}/cmdline"
mkdir -p "${TMP}/bin" "${TMP}/pacman.d"
printf '[options]\n\n[partyos]\nInclude = /etc/pacman.d/partyos-mirror\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n\n' \
    > "${TMP}/pacman.conf.orig"
printf '#!/bin/sh\necho "$@" >> "%s/logged"\n' "${TMP}" > "${TMP}/bin/logger"
# timeout stub: macOS has no coreutils timeout. Drop the duration, run the command.
printf '#!/bin/sh\nshift\nexec "$@"\n' > "${TMP}/bin/timeout"
sed -e "s#/proc/cmdline#${TMP}/cmdline#g" \
    -e "s#/etc/pacman.d#${TMP}/pacman.d#g" \
    -e "s#/etc/pacman.conf#${TMP}/pacman.conf#g" \
    "${BIN}/partyos-mirror-setup" > "${TMP}/partyos-mirror-setup"

# run_setup PACMAN_RC - run partyos-mirror-setup with a pacman stub that records its args.
run_setup() {
    printf '#!/bin/sh\necho "$@" >> "%s/pacman.args"\necho "error: failed retrieving file partyos.db"\nexit %s\n' \
        "${TMP}" "$1" > "${TMP}/bin/pacman"
    chmod +x "${TMP}/bin/"*
    rm -f "${TMP}/pacman.args" "${TMP}/logged"
    cp "${TMP}/pacman.conf.orig" "${TMP}/pacman.conf"
    OUT="$(env -i PATH="${TMP}/bin:/usr/bin:/bin" bash "${TMP}/partyos-mirror-setup" 2>&1)"; RC=$?
}

# --- 1. boot sync: a db refresh only ------------------------------------------
run_setup 0
assert_eq "${RC}" "0" "mirror-setup: exits 0 when the sync works"
assert_eq "$(cat "${TMP}/pacman.args" 2>/dev/null)" "-Sy --noconfirm" \
    "mirror-setup: runs pacman -Sy --noconfirm once, with no -u and no targets"
assert_eq "$(cat "${TMP}/pacman.d/partyos-mirror")" "Server = https://srv.example:8443/server/lanmirror" \
    "mirror-setup: writes the [partyos] Server= line"
assert_not_contains "${OUT}" "SYNC-FAILED" "mirror-setup: logs no sync failure when the sync works"

# --- 2. offline-safe: a failed sync is logged, not fatal ----------------------
run_setup 1
assert_eq "${RC}" "0" "mirror-setup: exits 0 when the sync fails"
assert_contains "${OUT}" "PARTYOS-MIRROR-SETUP-SYNC-FAILED" "mirror-setup: prints SYNC-FAILED on stderr"
assert_contains "${OUT}" "failed retrieving file partyos.db" "mirror-setup: the log line carries the pacman error"
assert_contains "$(cat "${TMP}/logged" 2>/dev/null)" "PARTYOS-MIRROR-SETUP-SYNC-FAILED" "mirror-setup: sends SYNC-FAILED to the journal"
assert_eq "$(cat "${TMP}/pacman.d/partyos-mirror")" "Server = https://srv.example:8443/server/lanmirror" \
    "mirror-setup: keeps the Server= line when the sync fails"

# --- 3. the boot unit ---------------------------------------------------------
UNIT="$(cat "${ROOTFS}/etc/systemd/system/partyos-mirror.service")"
assert_contains "${UNIT}" "After=network-online.target" "partyos-mirror.service runs after network-online.target"
assert_contains "${UNIT}" "TimeoutStartSec=" "partyos-mirror.service has a start timeout"
unit_to="$(sed -n 's/^TimeoutStartSec=\([0-9]*\)s*$/\1/p' <<<"${UNIT}")"
inner_to="$(sed -n 's/.*timeout \([0-9]*\) pacman -Sy.*/\1/p' "${BIN}/partyos-mirror-setup")"
assert_true "$([ -n "${inner_to}" ] && [ "${inner_to}" -lt "${unit_to:-0}" ]; echo $?)" \
    "mirror-setup: the sync timeout (${inner_to}s) is below TimeoutStartSec (${unit_to}s)"

# --- 4. the install path ------------------------------------------------------
PKG="$(grep -v '^[[:space:]]*#' "${BIN}/partyos-pkg-install")"
assert_contains "${PKG}" 'pacman -Sy --noconfirm --needed "${PKGS[@]}"' "partyos-pkg-install: runs pacman -Sy before each install"
for f in partyos-pkg-install partyos-mirror-setup; do
    code="$(grep -v '^[[:space:]]*#' "${BIN}/${f}")"
    assert_true "$(grep -qE 'pacman[^|;&]* -S[a-z]*u' <<<"${code}"; [ $? -ne 0 ]; echo $?)" "${f}: never runs pacman -Su"
done

# --- 5. the SNAPSHOT pin ------------------------------------------------------
snap() { sed -n 's/^SNAPSHOT="\${SNAPSHOT:-\([^}]*\)}"$/\1/p' "$1"; }
img_snap="$(snap "${REPO_ROOT}/scripts/build/build-custom-image.sh")"
mir_snap="$(snap "${REPO_ROOT}/scripts/build/mirror-pkgs.sh")"
assert_true "$([ -n "${img_snap}" ]; echo $?)" "build-custom-image.sh has a default SNAPSHOT (${img_snap})"
assert_eq "${mir_snap}" "${img_snap}" "mirror-pkgs.sh pins the same default SNAPSHOT as the image"

assert_summary test-pacman-db-refresh
