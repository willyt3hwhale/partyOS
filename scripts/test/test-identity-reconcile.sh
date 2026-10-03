#!/usr/bin/env bash
# test-identity-reconcile.sh - hardware-FREE unit test for the BAKED
# partyos-identity-setup account-reconcile logic (regression guard). The image bakes
# the script from scripts/build/files/rootfs/usr/local/bin/partyos-identity-setup.
# This test sed/awk-extracts the RECONCILE block (re-query uid 1000 after the rename and
# re-point downstream configs at the account that actually exists) and the final
# CONSISTENCY ASSERT block, runs them against a stubbed account state, and proves
# a failed/no-op rename still yields a self-consistent autologin. No VM, no
# network, no hardware - pure shell.
#
# The bug this guards: the uid-1000 rename (groupmod -n / usermod -l) was
# `2>/dev/null || true` - errors fully SWALLOWED. A failed usermod -l left the
# account as the OLD name (e.g. 'gamer') while sudoers / LightDM autologin-user /
# linger / home owner were all written for the INTENDED resolved name (e.g.
# 'alice'). LightDM then autologs into a user that does NOT exist -> blank screen,
# no error pointing at the cause. The fix re-queries who really owns uid 1000 and
# binds the rest of the script to THAT actual name, so a rename failure degrades
# to "logs in as the existing account" instead of "no desktop at all".
#
# Asserts:
#   * rename SUCCEEDS  -> USERNAME stays the resolved (new) name; autologin OK.
#   * rename FAILS/no-op (account stays 'gamer') -> USERNAME falls back to the
#     ACTUAL existing account, downstream autologin is self-consistent (not the
#     dangling intended name); the OK assertion holds.
#   * NO account owns uid 1000 -> the path fails LOUD (exit 1) instead of writing
#     configs for a user that does not exist.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

IDENT="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-identity-setup"
[ -f "${IDENT}" ] || { echo "FAIL: partyos-identity-setup baked file not found at ${IDENT}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-idtest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- the baked partyos-identity-setup is the body -----------------------------
IDENT_BODY="${IDENT}"
[ -s "${IDENT_BODY}" ] || { echo "FAIL: partyos-identity-setup baked file is empty (${IDENT_BODY})"; exit 1; }

# Carve the RECONCILE block (the marker comment -> the closing `fi` of the
# "if actual != USERNAME" stanza). It re-queries uid ${UIDGID} and re-points
# USERNAME/HOME_DIR. We replace its loud exit/report with test-visible hooks.
RECONCILE="${TMPDIR_T}/reconcile.sh"
awk '/^# RECONCILE the resolved name/{g=1}
     g{print}
     g&&/^    HOME_DIR="\/home\/\$\{USERNAME\}"$/{getline; print; exit}' \
    "${IDENT_BODY}" > "${RECONCILE}"
grep -q 'actual_user=' "${RECONCILE}" || { echo "FAIL: could not carve the RECONCILE block"; cat "${RECONCILE}"; exit 1; }
grep -q 'PARTYOS-IDENTITY-RENAME-FAILED' "${RECONCILE}" || { echo "FAIL: RENAME-FAILED marker missing from carve"; exit 1; }

# --- stub the account state ----------------------------------------------------
# PASSWD_LINE is the getent passwd ${UIDGID} stand-in; empty = no such account.
UIDGID=1000
PASSWD_LINE=""
getent() { [ -n "${PASSWD_LINE}" ] && printf '%s\n' "${PASSWD_LINE}"; }
# id NAME -> succeed iff NAME is the account that owns uid 1000 (PASSWD_LINE name).
id() {
    if [ "$1" = "-u" ]; then shift; fi
    local owner; owner="$(printf '%s' "${PASSWD_LINE}" | cut -d: -f1)"
    [ "$1" = "${owner}" ] && { [ "${1:-}" ] && echo 0; return 0; }
    return 1
}
log() { LOGS="${LOGS}
$*"; }
# capture the report calls + the loud exit instead of killing the test shell.
REPORTS=""
partyos_identity_report() { REPORTS="${REPORTS}
report:$1:$2:${3:-}"; return 0; }
EXIT_RC=""
exit() { EXIT_RC="$1"; return 0; }   # non-fatal stand-in for the carved `exit 1`

# run_reconcile RESOLVED ACTUAL  - set up state then execute the carved block.
#   RESOLVED = the intended USERNAME going in.
#   ACTUAL   = the name that actually owns uid 1000 (empty = no account).
run_reconcile() {
    USERNAME="$1"; HOME_DIR="/home/${USERNAME}"
    local actual="$2"
    LOGS=""; REPORTS=""; EXIT_RC=""
    if [ -n "${actual}" ]; then PASSWD_LINE="${actual}:x:${UIDGID}:${UIDGID}::/home/${actual}:/bin/bash"
    else PASSWD_LINE=""; fi
    # shellcheck disable=SC1090
    source "${RECONCILE}"
}

echo "================ (a) rename SUCCEEDS -> keeps resolved name ==="
run_reconcile "alice" "alice"
assert_eq "${USERNAME}" "alice" "rename-ok: USERNAME stays the resolved name 'alice'"
assert_eq "${HOME_DIR}" "/home/alice" "rename-ok: HOME_DIR tracks 'alice'"
assert_eq "${EXIT_RC}" "" "rename-ok: no loud exit"
assert_not_contains "${LOGS}" "PARTYOS-IDENTITY-RENAME-FAILED" "rename-ok: no RENAME-FAILED marker"

echo
echo "================ (b) rename FAILS -> falls back to actual ===="
# Intended 'alice' but uid 1000 still owned by 'gamer' (usermod -l silently failed).
run_reconcile "alice" "gamer"
assert_eq "${USERNAME}" "gamer" "rename-failed: USERNAME re-points to the ACTUAL account 'gamer'"
assert_eq "${HOME_DIR}" "/home/gamer" "rename-failed: HOME_DIR follows the actual account (self-consistent home)"
assert_eq "${EXIT_RC}" "" "rename-failed: degrades (no loud exit) - autologin still works against 'gamer'"
assert_contains "${LOGS}" "PARTYOS-IDENTITY-RENAME-FAILED" "rename-failed: loud RENAME-FAILED marker logged"
assert_contains "${REPORTS}" "report:rename-failed:gamer:" "rename-failed: boot report carries the actual user"

echo
echo "================ (c) NO account owns uid 1000 -> FAIL LOUD ====="
run_reconcile "alice" ""
assert_eq "${EXIT_RC}" "1" "no-account: fails LOUD (exit 1) - never writes configs for a non-existent user"
assert_contains "${LOGS}" "PARTYOS-IDENTITY-FAIL" "no-account: PARTYOS-IDENTITY-FAIL marker logged"
assert_contains "${REPORTS}" "report:fail:alice:" "no-account: boot report flags the failure"

assert_summary "test-identity-reconcile" || exit 1
echo "test-identity-reconcile: ALL PASS"
